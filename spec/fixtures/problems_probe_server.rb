# Deterministic stdio LSP fixture for the real-terminal Problems smoke.
require 'json'

STDIN.binmode
STDOUT.binmode
events = ARGV.fetch(0)

def record(path, event)
  File.open(path, 'a') do |file|
    file.puts(JSON.generate(event))
  end
end

def respond(id, result)
  body = JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result)
  STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  STDOUT.flush
end

def publish_diagnostics(path, uri, version, message)
  params = {
    'uri' => uri,
    'version' => version,
    'diagnostics' => [
      {
        'range' => {
          'start' => {'line' => 0, 'character' => 0},
          'end' => {'line' => 0, 'character' => 1},
        },
        'severity' => 1,
        'source' => 'problems-smoke',
        'message' => message,
      },
    ],
  }
  body = JSON.generate('jsonrpc' => '2.0', 'method' => 'textDocument/publishDiagnostics', 'params' => params)
  STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  STDOUT.flush
  record(path, 'event' => 'publishedDiagnostics', 'uri' => uri, 'version' => version)
end

loop do
  headers = {}
  while (line = STDIN.gets)
    break if line == "\r\n" || line == "\n"
    key, value = line.split(':', 2)
    headers[key.downcase] = value.strip if value
  end
  break unless line

  message = JSON.parse(STDIN.read(Integer(headers.fetch('content-length'))))
  record(events, message)

  case message['method']
  when 'initialize'
    respond(message['id'], 'capabilities' => {'textDocumentSync' => 1})
  when 'textDocument/didOpen'
    document = message.fetch('params').fetch('textDocument')
    uri = document.fetch('uri')
    version = document['version']
    message_text = uri.include?('/one/') ? 'first-file-diagnostic' : 'second-file-diagnostic'
    publish_diagnostics(events, uri, version, message_text)
  when 'shutdown'
    respond(message['id'], nil)
  when 'exit'
    break
  else
    respond(message['id'], nil) if message.key?('id')
  end
end
