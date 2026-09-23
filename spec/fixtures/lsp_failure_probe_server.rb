# Deterministic LSP peer for the bounded terminal recovery smoke.
require "json"

events = ARGV.fetch(0)
ready_file = ARGV.fetch(1)
STDIN.binmode
STDOUT.binmode

def read_message
  length = nil
  while (line = STDIN.gets)
    break if line == "\r\n" || line == "\n"
    key, value = line.split(":", 2)
    length = value.to_i if key&.downcase == "content-length"
  end
  return nil unless line && length && length > 0
  JSON.parse(STDIN.read(length))
end

def respond(id, result)
  body = JSON.generate("jsonrpc" => "2.0", "id" => id, "result" => result)
  STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  STDOUT.flush
end

while message = read_message
  File.open(events, "a") do |log|
    log.puts(JSON.generate("method" => message["method"]))
  end

  case message["method"]
  when "initialize"
    unless File.exist?(ready_file)
      File.write(ready_file, "initial peer failed")
      exit! 9
    end
    respond(message["id"], "capabilities" => {"textDocumentSync" => 2})
  when "shutdown"
    respond(message["id"], nil)
  when "exit"
    break
  else
    respond(message["id"], nil) if message.key?("id")
  end
end
