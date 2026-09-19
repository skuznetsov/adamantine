# Deterministic wire fixture: no filesystem or executeCommand authority.
require 'json'
STDIN.binmode
STDOUT.binmode
events = ARGV.fetch(0)

def edit(start_col, end_col, text)
  {'range' => {'start' => {'line' => 0, 'character' => start_col},
               'end' => {'line' => 0, 'character' => end_col}}, 'newText' => text}
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
  File.open(events, 'a') { |file| file.puts(JSON.generate(message)) }
  break if message['method'] == 'exit'
  next unless message.key?('id')
  params = message['params'] || {}
  result = case message['method']
           when 'initialize'
             {'capabilities' => {'textDocumentSync' => 1, 'renameProvider' => true,
                                  'codeActionProvider' => {'codeActionKinds' => ['quickfix']}}}
           when 'textDocument/rename'
             uri = params.fetch('textDocument').fetch('uri')
             name = params.fetch('newName')
             changes = {uri => [edit(0, 3, name), edit(6, 9, name)]}
             changes[uri + '.foreign'] = [edit(0, 0, 'forbidden')] if name == 'foreign'
             {'changes' => changes}
           when 'textDocument/codeAction'
             raise 'codeAction requires range, not position' if params.key?('position')
             raise 'missing range' unless params['range'] == {'start' => {'line' => 0, 'character' => 0},
                                                            'end' => {'line' => 0, 'character' => 0}}
             raise 'missing quickfix filter' unless params.dig('context', 'only') == ['quickfix']
             uri = params.fetch('textDocument').fetch('uri')
             [{'title' => 'Use safe name', 'kind' => 'quickfix',
               'edit' => {'documentChanges' => [{'textDocument' => {'uri' => uri, 'version' => nil},
                                                'edits' => [edit(0, 3, 'safe'), edit(6, 9, 'safe')]}]}}]
           when 'workspace/executeCommand'
             raise 'unexpected executeCommand'
           else
             nil
           end
  response = JSON.generate({'jsonrpc' => '2.0', 'id' => message['id'], 'result' => result})
  STDOUT.write("Content-Length: #{response.bytesize}\r\n\r\n#{response}")
  STDOUT.flush
end
