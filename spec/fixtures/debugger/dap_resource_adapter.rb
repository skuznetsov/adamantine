#!/usr/bin/env ruby
require "json"

STDOUT.sync = true
MODE = ARGV.fetch(0, "basic")
FRAME_BYTES = (ARGV[1] || "1024").to_i
NULL_ITEMS = (ARGV[1] || "247500").to_i
$adapter_seq = 0

def read_message
  headers = {}
  loop do
    line = STDIN.gets
    return nil unless line
    line = line.sub(/\r?\n\z/, "")
    break if line.empty?
    key, value = line.split(":", 2)
    return nil unless key && value
    headers[key.downcase] = value.strip
  end

  length = Integer(headers.fetch("content-length"), 10) rescue nil
  return nil unless length && length.positive? && length <= 64 * 1024 * 1024
  payload = STDIN.read(length)
  return nil unless payload && payload.bytesize == length
  JSON.parse(payload)
rescue JSON::ParserError
  nil
end

def write_json(payload)
  json = JSON.generate(payload)
  STDOUT.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
  STDOUT.flush
end

def write_message(message)
  $adapter_seq += 1
  message["seq"] = $adapter_seq
  write_json(message)
end

def write_raw_message
  $adapter_seq += 1
  json = yield($adapter_seq)
  STDOUT.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
  STDOUT.flush
end

def write_response(request, body: {}, success: true, message: nil)
  response = {
    "type" => "response",
    "request_seq" => request.fetch("seq"),
    "command" => request.fetch("command"),
    "success" => success,
  }
  response["body"] = body if body
  response["message"] = message if message
  write_message(response)
end

def write_event(name, body = {})
  write_message({"type" => "event", "event" => name, "body" => body})
end

def record_request(request)
  request
end

def high_token_event(item_count)
  values = "null," * (item_count - 1) + "null"
  write_raw_message do |sequence|
    %({"seq":#{sequence},"type":"event","event":"resourceProbe","body":{"items":[#{values}]}})
  end
end

loop do
  request = read_message
  break unless request
  record_request(request)
  next unless request["type"] == "request"

  command = request["command"]
  case command
  when "initialize"
    write_response(request, body: {})
    sleep 3600 if MODE == "no_read"
  when "probe"
    case MODE
    when "wire_burst"
      count = request.dig("arguments", "count").to_i
      payload = "x" * FRAME_BYTES
      count.times do |index|
        write_event("resourceProbe", {"index" => index, "payload" => payload})
      end
      write_response(request, body: {"sent" => count})
    when "decoded_burst"
      batch = request.dig("arguments", "batch")
      count = batch == "first" ? 16 : 1
      count.times { high_token_event(NULL_ITEMS) }
      write_response(request, body: {"sent" => count})
    when "item_burst"
      count = request.dig("arguments", "count").to_i
      count.times do |index|
        write_event("stopped", {"threadId" => index + 1, "reason" => "pause"})
      end
      if request.dig("arguments", "hold") == true
        continuation = read_message
        break unless continuation
        record_request(continuation)
        write_event("stopped", {"threadId" => 9999, "reason" => "pause"})
        write_response(continuation, body: {})
      else
        write_response(request, body: {"sent" => count})
      end
    when "partial"
      event_sequence = $adapter_seq + 1
      payload = JSON.generate({
        "seq" => event_sequence,
        "type" => "event",
        "event" => "resourceProbe",
        "body" => {"phase" => "fragmented"},
      })
      frame = "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}"
      split = frame.bytesize / 2
      STDOUT.write(frame.byteslice(0, split))
      STDOUT.flush
      continuation = read_message
      break unless continuation
      record_request(continuation)
      $adapter_seq = event_sequence
      STDOUT.write(frame.byteslice(split, frame.bytesize - split))
      STDOUT.flush
      write_response(continuation, body: {})
    else
      write_response(request, body: {})
    end
  else
    write_response(request, body: {})
  end
end
