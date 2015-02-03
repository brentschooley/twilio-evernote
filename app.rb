require 'sinatra'
require 'twilio-ruby'
require 'open-uri'
require 'openssl'
require 'certified'
require "evernote_oauth"
enable :sessions

# Connect to Sandbox server?
SANDBOX = true

def dev_token
  'S=s1:U=90484:E=1528ed06b55:C=14b371f3ca8:P=1cd:A=en-devtoken:V=2:H=2e311c0746d91e1cafdc0d573d3b7a48'
end

def client
  @client ||= EvernoteOAuth::Client.new(token: dev_token, sandbox: SANDBOX)
end

def note_store
  @note_store ||= client.note_store
end

def notebooks
  @notebooks ||= note_store.listNotebooks(dev_token)
end

def make_note(note_store, note_title, note_body, notebook_name, resource=nil)
  notebook_guid = ''

  if notebooks.any? {|notebook| notebook.name == notebook_name }
    # Notebook exists, get the notebook GUID
    twilio_notebook = notebooks.find { |nb| nb.name == notebook_name }
    notebook_guid = twilio_notebook.guid
  else
    # Create notebook and store GUID
    notebook = Evernote::EDAM::Type::Notebook.new()
    notebook.name = notebook_name
    new_notebook = note_store.createNotebook(dev_token, notebook)
    notebook_guid = new_notebook.guid
  end

  n_body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
  n_body += "<!DOCTYPE en-note SYSTEM \"http://xml.evernote.com/pub/enml2.dtd\">"
  n_body += "<en-note>#{note_body} "

  if resource
    n_body += "<en-media type='#{resource.mime}' hash='#{resource.data.bodyHash}'/>"
  end

  n_body += "</en-note>"

  ## Create note object
  new_note = Evernote::EDAM::Type::Note.new
  new_note.title = note_title
  new_note.content = n_body
  new_note.notebookGuid = notebook_guid
  new_note.resources = [resource] if resource

  ## Attempt to create note in Evernote account
  begin
    note = note_store.createNote(new_note)
  rescue Evernote::EDAM::Error::EDAMUserException => edue
    ## Something was wrong with the note data
    ## See EDAMErrorCode enumeration for error code explanation
    ## http://dev.evernote.com/documentation/reference/Errors.html#Enum_EDAMErrorCode
    pp "EDAMUserException: #{edue}"
    pp edue.errorCode
  rescue Evernote::EDAM::Error::EDAMNotFoundException => ednfe
    ## Parent Notebook GUID doesn't correspond to an actual notebook
    pp "EDAMNotFoundException: Invalid parent notebook GUID"
  end

  ## Return created note object
  note
end

def create_resource(binary, mime_type, filename)
  hashFunc = Digest::MD5.new
  hashHex = hashFunc.hexdigest(binary)

  data = Evernote::EDAM::Type::Data.new()
  data.bodyHash = hashHex
  data.body = binary;

  resource = Evernote::EDAM::Type::Resource.new()
  resource.mime = mime_type
  resource.data = data;
  resource.attributes = Evernote::EDAM::Type::ResourceAttributes.new()
  resource.attributes.fileName = filename

  return resource
end

post '/sms' do
  message = params[:Body]
  picture_url = params[:MediaUrl0]
  puts picture_url

  image = nil
  resource = nil

  if picture_url and picture_url.length > 0
    File.open('temp.jpg', 'wb') do |fo|
      fo.write open(picture_url).read
    end

    image = File.open('temp.jpg', "rb") { |io| io.read };

    resource = create_resource image, "image/jpeg", "from MMS"
  end

  make_note note_store, 'From SMS', message, "From Evernote-Twilio", resource
end

post '/voice' do
  Twilio::TwiML::Response.new do |r|
    r.Say 'Record a message to put in your default notebook.'
    r.Record :transcribeCallback => "http://brent.ngrok.com/transcription"
  end.text
end

post '/transcription' do
  transcribed_text =  params[:TranscriptionText]
  recording = params[:RecordingUrl]

  File.open('temp.mp3', 'wb') do |fo|
    fo.write open("#{recording}.mp3").read
  end

  sound = File.open('temp.mp3', "rb") { |io| io.read };

  resource = create_resource sound, "audio/mpeg", "from MMS"

  make_note note_store, 'From voice call', transcribed_text, "From Evernote-Twilio", resource
end
