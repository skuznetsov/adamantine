#!/usr/bin/env bash

set -euo pipefail

LSP_PATH="${1:-${ADAMANTINE_LSP:-}}"
ROOT_URI="${ADAMANTINE_LSP_ROOT_URI:-file:///tmp/adamantine-harness}"

if [[ -z "$LSP_PATH" || ! -x "$LSP_PATH" ]]; then
  echo "harness: LSP executable not found or not executable: $LSP_PATH"
  echo "Usage: scripts/harness.sh LSP_PATH [ROOT_URI] [-- LSP_ARG ...]"
  echo "   or: ADAMANTINE_LSP=/path/to/server make harness"
  exit 2
fi

shift || true
if [[ "${1:-}" == file://* ]]; then
  ROOT_URI="$1"
  shift
fi
if [[ "${1:-}" == "--" ]]; then
  shift
fi

ruby - "$ROOT_URI" "$LSP_PATH" "$@" <<'RUBY'
require "json"
require "open3"
require "timeout"

root_uri = ARGV.shift
command = ARGV
path = command.fetch(0)

MAX_FRAME_BYTES = 4 * 1024 * 1024
MAX_HEADERS = 50
MAX_NOISE_LINES = 100

initialize = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    processId: Process.pid,
    rootUri: root_uri,
    capabilities: {
      textDocument: {
        publishDiagnostics: { relatedInformation: true },
      },
    },
    clientInfo: {
      name: "adamantine_harness",
      version: "0.1.0",
    },
  },
}

def encode(message)
  payload = JSON.generate(message)
  "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}"
end

def read_exact(io, size)
  data = +""
  while data.bytesize < size
    chunk = io.read(size - data.bytesize)
    break unless chunk
    data << chunk
  end
  raise "LSP server closed stdout in message body" unless data.bytesize == size
  data
end

def send_message(io, message)
  io.write(encode(message))
  io.flush
end

def read_response(io, expected_id)
  noise_lines = 0
  loop do
    header = io.gets
    raise "LSP server closed stdout" unless header
    key, value = header.split(":", 2)
    unless key&.casecmp?("Content-Length")
      noise_lines += 1
      raise "LSP server sent too many non-header lines" if noise_lines > MAX_NOISE_LINES
      next
    end

    content_length = value.to_i
    raise "invalid Content-Length" unless content_length.positive?
    raise "LSP response too large" if content_length > MAX_FRAME_BYTES

    header_count = 0
    loop do
      separator = io.gets
      raise "LSP server closed stdout in headers" unless separator
      break if separator.strip.empty?
      header_count += 1
      raise "LSP server sent too many headers" if header_count > MAX_HEADERS
    end

    body = JSON.parse(read_exact(io, content_length))
    next unless body.fetch("id", nil) == expected_id
    return body
  end
end

stdin, stdout, wait_thr = Open3.popen2(*command)
begin
  Timeout.timeout(6) do
    send_message(stdin, initialize)
    initialize_response = read_response(stdout, 1)
    raise "initialize returned an error" unless initialize_response.key?("result")
    puts "response 1: result"

    send_message(stdin, { jsonrpc: "2.0", method: "initialized", params: {} })
    send_message(stdin, { jsonrpc: "2.0", id: 2, method: "shutdown", params: {} })
    shutdown_response = read_response(stdout, 2)
    raise "shutdown returned an error" unless shutdown_response.key?("result")
    puts "response 2: result"

    send_message(stdin, { jsonrpc: "2.0", method: "exit", params: {} })
  end

  puts "harness: lsp handshake success for #{command.join(" ")}"
rescue Timeout::Error
  warn "harness: timed out waiting for LSP handshake"
  exit 1
rescue StandardError => error
  warn "harness: #{error.message}"
  exit 1
ensure
  stdin.close unless stdin.closed?
  if wait_thr.alive?
    Process.kill("TERM", wait_thr.pid) rescue nil
    wait_thr.join(1)
    if wait_thr.alive?
      Process.kill("KILL", wait_thr.pid) rescue nil
      wait_thr.join
    end
  end
end
RUBY
