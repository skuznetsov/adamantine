# Deterministic stdio LSP fixture for the real-terminal server-workspace
# Problems smoke. It reports one unopened file only when explicitly pulled.
require 'json'

STDIN.binmode
STDOUT.binmode
events = ARGV.fetch(0)
target_uri = ARGV.fetch(1)

def record(path, event)
  File.open(path, 'a') { |file| file.puts(JSON.generate(event)) }
end

def respond(id, result)
  body = JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result)
  STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  STDOUT.flush
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
    respond(message['id'], 'capabilities' => {
      'textDocumentSync' => 1,
      'diagnosticProvider' => {
        'identifier' => 'workspace-problems-smoke',
        'interFileDependencies' => true,
        'workspaceDiagnostics' => true,
      },
    })
  when 'workspace/diagnostic'
    respond(message['id'], 'items' => [{
      'uri' => target_uri,
      'version' => nil,
      'kind' => 'full',
      'resultId' => 'workspace-smoke-1',
      'items' => [{
        'range' => {
          'start' => {'line' => 0, 'character' => 2},
          'end' => {'line' => 0, 'character' => 2},
        },
        'severity' => 1,
        'source' => 'workspace-problems-smoke',
        'message' => 'unopened-workspace-diagnostic',
      }],
    }])
  when 'shutdown'
    respond(message['id'], nil)
  when 'exit'
    break
  else
    respond(message['id'], nil) if message.key?('id')
  end
end
