#!/usr/bin/env bash

set -euo pipefail

LSP_PATH="${1:-${ADAMANTINE_LSP:-}}"
ROOT_URI="${2:-file:///tmp/adamantine-harness}"

if [[ -z "$LSP_PATH" || ! -x "$LSP_PATH" ]]; then
  echo "harness: LSP executable not found or not executable: $LSP_PATH"
  echo "Usage: scripts/harness.sh LSP_PATH [ROOT_URI]"
  echo "   or: ADAMANTINE_LSP=/path/to/server make harness"
  exit 2
fi

ruby - "$LSP_PATH" "$ROOT_URI" <<'RUBY'
require "json"
require "open3"

path = ARGV[0]
root_uri = ARGV[1]

messages = [
  {
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
  },
  { jsonrpc: "2.0", method: "initialized", params: {} },
  { jsonrpc: "2.0", id: 2, method: "shutdown", params: {} },
  { jsonrpc: "2.0", method: "exit", params: {} },
]

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
  data
end

stdin, stdout, wait_thr = Open3.popen2(path)
begin
  messages.each do |message|
    encoded = encode(message)
    stdin.write(encoded)
    stdin.flush
  end

  received = {}
  deadline = Time.now + 6

  while received.keys.size < 2 && Time.now < deadline
    header = stdout.gets
    break unless header
    next unless header.start_with?("Content-Length:")

    content_length = header[15..].to_i
    separator = stdout.gets
    break unless separator

    payload = read_exact(stdout, content_length)
    body = JSON.parse(payload)
    id = body["id"]
    next unless id

    received[id] = body
    if body.key?("result")
      puts "response #{id}: result"
    else
      puts "response #{id}: error"
    end
  end

  unless received.key?(1)
    warn "harness: missing initialize response (id=1)"
    exit 1
  end

  unless received.key?(2)
    warn "harness: missing shutdown response (id=2)"
    exit 1
  end

  puts "harness: lsp handshake success for #{path}"
ensure
  stdin.close
  if wait_thr.alive?
    Process.kill("TERM", wait_thr.pid)
    wait_thr.join(1)
  end
end
RUBY
