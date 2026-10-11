#!/usr/bin/env ruby
require "json"

STDOUT.sync = true
MODE = ARGV.fetch(0, "basic")
LOG_PATH = ARGV[1]
TRACE_PATH = MODE == "fragmented" ? ARGV[2] : nil
DELAY = (MODE == "late" && ARGV[2] ? ARGV[2] : "0.12").to_f
SIZE = (%w[flood output_flood oversize_response].include?(MODE) && ARGV[2] ? ARGV[2] : "1024").to_i
TRACE_MAX_EVENTS = 16
TRACE_STARTED = Process.clock_gettime(Process::CLOCK_MONOTONIC)
TRACE_FILE = if TRACE_PATH && !TRACE_PATH.empty?
               File.open(TRACE_PATH, "w").tap { |file| file.sync = true }
             end
$fragment_trace_events = 0

at_exit { TRACE_FILE.close if TRACE_FILE && !TRACE_FILE.closed? }

$adapter_seq = 0

def log_message(message)
  return unless LOG_PATH && !LOG_PATH.empty?
  File.open(LOG_PATH, "a") { |file| file.puts(JSON.generate(message)) }
end

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

def write_message(message)
  $adapter_seq += 1
  message["seq"] = $adapter_seq
  payload = JSON.generate(message)
  STDOUT.write("Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
  STDOUT.flush
  message
end

def log_fragment_write(phase, chunk, offset)
  return unless TRACE_FILE
  return if $fragment_trace_events >= TRACE_MAX_EVENTS

  elapsed_ns = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - TRACE_STARTED) * 1_000_000_000).round
  TRACE_FILE.puts(JSON.generate({
    "adapter_seq" => $adapter_seq,
    "phase" => phase,
    "offset" => offset,
    "bytes" => chunk.bytesize,
    "elapsed_ns" => elapsed_ns,
  }))
  $fragment_trace_events += 1
end

def write_fragmented_message(message)
  $adapter_seq += 1
  message["seq"] = $adapter_seq
  payload = JSON.generate(message)
  frame = "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}"
  offset = 0
  chunk_index = 0
  [1, 7, 19, 2, 11].each do |length|
    chunk = frame.byteslice(offset, length)
    break unless chunk
    STDOUT.write(chunk)
    STDOUT.flush
    offset += chunk.bytesize
    chunk_index += 1
    phase = if offset == frame.bytesize
              "last"
            elsif chunk_index == 1
              "first"
            else
              "chunk"
            end
    log_fragment_write(phase, chunk, offset)
    sleep 0.015 if offset < frame.bytesize
  end
  if offset < frame.bytesize
    chunk = frame.byteslice(offset, frame.bytesize - offset)
    STDOUT.write(chunk)
    STDOUT.flush
    log_fragment_write("last", chunk, frame.bytesize)
  end
  message
end

def write_response(request, success: true, body: {}, message: nil, command: request["command"])
  response = {
    "type" => "response",
    "request_seq" => request.fetch("seq"),
    "command" => command,
    "success" => success,
  }
  response["body"] = body if body
  response["message"] = message if message
  MODE == "fragmented" ? write_fragmented_message(response) : write_message(response)
end

def write_event(name, body = {})
  write_message({"type" => "event", "event" => name, "body" => body})
end

def initialize_request(request)
  write_response(request, body: {"supportsConfigurationDoneRequest" => true})
end

def record_request(request)
  log_message(request)
  request
end

held = []
pending_launch = nil

loop do
  request = read_message
  break unless request
  record_request(request)
  next unless request["type"] == "request"

  command = request["command"]
  case command
  when "initialize"
    if MODE == "partial_header"
      STDOUT.write("Content-Len")
      STDOUT.flush
      sleep 3600
    elsif MODE == "partial_body"
      STDOUT.write("Content-Length: 100\r\n\r\n{}")
      STDOUT.flush
      sleep 3600
    elsif MODE == "close_stdin"
      STDIN.close
      File.write("#{LOG_PATH}.stdin-closed", "closed\n") if LOG_PATH
      initialize_request(request)
      sleep 3600
    elsif MODE == "init_reject"
      write_response(request, success: false, message: "fixture initialize rejection")
    else
      initialize_request(request)
    end
    sleep 3600 if MODE == "idle"
    if MODE == "no_read"
      sleep 3600
    end
  when "launch"
    if MODE == "init_launch"
      write_event("initialized")
      pending_launch = request
    else
      write_response(request, body: {})
    end
  when "configurationDone"
    write_response(request, body: {})
    write_response(pending_launch, body: {}) if pending_launch
    pending_launch = nil
  when "probe"
    case MODE
    when "reorder"
      held << request
      if held.size >= 2
        held.reverse_each do |item|
          write_response(item, body: {"label" => item.dig("arguments", "label")})
        end
        held.clear
      end
    when "reverse"
      write_message({
        "type" => "request",
        "command" => "runInTerminal",
        "arguments" => {"args" => ["do-not-run"]},
      })
      reverse_response = read_message
      record_request(reverse_response) if reverse_response
      write_response(request, body: {"reverse_response" => reverse_response})
    when "late"
      sleep DELAY if held.empty?
      held << request
      write_response(request, body: {"label" => request.dig("arguments", "label")})
      held.clear
    when "wrong_command"
      write_response(request, body: {}, command: "differentCommand")
    when "wrong_command_hang"
      write_response(request, body: {}, command: "differentCommand")
      sleep 3600
    when "concurrent_reverse"
      unless $reverse_request_sent
        $reverse_request_sent = true
        write_message({
          "type" => "request",
          "command" => "runInTerminal",
          "arguments" => {"args" => ["must-not-run"]},
        })
      end
      write_response(request, body: {"label" => request.dig("arguments", "label")})
    when "unknown_response"
      response = {
        "type" => "response",
        "request_seq" => request.fetch("seq") + 100,
        "command" => request.fetch("command"),
        "success" => true,
        "body" => {},
      }
      write_message(response)
    when "flood"
      SIZE.times { |index| write_event("stopped", {"threadId" => index + 1, "reason" => "pause"}) }
      write_response(request, body: {})
    when "output_flood"
      SIZE.times { |index| write_event("output", {"category" => "console", "output" => "x" * 256, "index" => index}) }
      write_response(request, body: {})
    when "oversize_response"
      write_response(request, body: {"payload" => "x" * SIZE})
    when "eof"
      STDOUT.close
      exit!
    when "hold"
      held << request
    else
      write_response(request, body: {"label" => request.dig("arguments", "label")})
    end
  when "hold"
    held << request
  when "disconnect"
    write_response(request, body: {})
    break
  else
    write_response(request, body: {})
  end

  sleep 3600 if MODE == "blackhole"
end
