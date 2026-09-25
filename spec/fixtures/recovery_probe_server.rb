# A real stdio peer for recovery integration tests. It never touches project
# files: the parent supplies an event log and an explicit crash-control file.
require "json"

def receive_message
  length = nil
  loop do
    line = STDIN.gets
    return nil unless line
    break if line.strip.empty?
    length = line.split(":", 2)[1].to_i if line.downcase.start_with?("content-length:")
  end
  return nil unless length && length > 0
  body = STDIN.read(length)
  return nil unless body && body.bytesize == length
  JSON.parse(body)
end

def respond(id, result)
  body = JSON.generate("jsonrpc" => "2.0", "id" => id, "result" => result)
  STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  STDOUT.flush
end

events, control = ARGV
loop do
  crash = File.exist?(control) ? File.read(control).strip : ""
  exit!(9) if crash == Process.pid.to_s
  next unless IO.select([STDIN], nil, nil, 0.01)
  message = receive_message
  break unless message
  File.open(events, "a") do |log|
    log.puts(JSON.generate("pid" => Process.pid, "message" => message))
  end
  case message["method"]
  when "initialize"
    while File.exist?(control) && File.read(control).strip == "hold-initialize"
      sleep 0.005
    end
    respond(message["id"], "capabilities" => {"textDocumentSync" => 2})
  when "textDocument/didOpen"
    exit!(9) if File.exist?(control) && File.read(control).strip == "crash-on-open"
  when "shutdown"
    respond(message["id"], nil)
  when "exit"
    break
  else
    respond(message["id"], nil) if message.key?("id")
  end
end
