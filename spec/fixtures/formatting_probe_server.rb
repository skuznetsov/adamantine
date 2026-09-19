# Minimal deterministic LSP fixture for a real-terminal formatting smoke.
require 'json'
STDIN.binmode
STDOUT.binmode
events = ARGV.fetch(0)
loop do
  headers = {}
  while (line = STDIN.gets)
    break if line == "\r\n" || line == "\n"
    key, value = line.split(':', 2)
    headers[key.downcase] = value.strip if value
  end
  break unless line
  message = JSON.parse(STDIN.read(Integer(headers.fetch('content-length'))))
  File.open(events, 'a') { |file| file.puts(JSON.generate(message)) }
  break if message['method'] == 'exit'
  next unless message.key?('id')
  result = case message['method']
           when 'initialize'
             {'capabilities' => {'textDocumentSync' => 1, 'documentFormattingProvider' => true}}
           when 'textDocument/formatting'
             [{'range' => {'start' => {'line' => 0, 'character' => 0},
                           'end' => {'line' => 0, 'character' => 9}}, 'newText' => 'puts(1)'}]
           else
             nil
           end
  response = JSON.generate({'jsonrpc' => '2.0', 'id' => message['id'], 'result' => result})
  STDOUT.write("Content-Length: #{response.bytesize}\r\n\r\n#{response}")
  STDOUT.flush
end
