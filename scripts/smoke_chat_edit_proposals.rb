#!/usr/bin/env ruby
require "digest"
require "fileutils"
require "json"
require "io/console"
require "pty"
require "socket"
require "tmpdir"
require "timeout"
require_relative "lib/pty_screen"

# Production App acceptance/rejection smoke using only a literal-loopback fake
# provider and a synthetic key. It never contacts a model service.
binary = ARGV.fetch(0) { abort "usage: ruby scripts/smoke_chat_edit_proposals.rb EDITOR_BIN [TIMEOUT_SECONDS]" }
binary = File.realpath(binary)
abort "editor binary is not executable" unless File.file?(binary) && File.executable?(binary)
timeout_seconds = Float(ARGV[1] || "45")
abort "timeout must be between 10 and 120 seconds" unless timeout_seconds.between?(10.0, 120.0)

WIDTH = 112
HEIGHT = 30
F1 = "\eOP".freeze
ENTER = "\e[13u".freeze
ESCAPE = "\e[27u".freeze
DOWN = "\e[B".freeze
CTRL_Z = "\e[122;5u".freeze
CHAT_FIXTURE_KEY = "synthetic-chat-edit-fixture-key-not-a-credential".freeze
KEY_ENV = "ADAMANTINE_CHAT_EDIT_FIXTURE_KEY".freeze
PENDING_COMPLETION = Object.new.freeze

def assert(condition, message)
  raise message unless condition
end

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def type_text(writer, text)
  text.each_codepoint { |codepoint| key(writer, "\e[#{codepoint}u") }
end

def rows(state)
  state[:mutex].synchronize do
    raise "PTY output drain failed: #{state[:screen_error]}" if state[:screen_error]
    state[:screen].rows
  end
end

def screen_text(state)
  rows(state).join("\n")
end

def screen_has?(state, text)
  rows(state).any? { |row| row.include?(text) }
end

def stable_screen_text(state, quiet_seconds: 0.20, wait_seconds: 2.0)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
  prior = nil
  stable_since = nil
  loop do
    snapshot = state[:mutex].synchronize do
      [state[:screen].revision, state[:screen].rows.join("\n")]
    end
    if snapshot == prior
      stable_since ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return snapshot.last if Process.clock_gettime(Process::CLOCK_MONOTONIC) - stable_since >= quiet_seconds
    else
      prior = snapshot
      stable_since = nil
    end
    raise "timeout waiting for stable PTY screen" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
end

def await(label, seconds: 8.0)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  until yield
    raise "timeout waiting for #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
end

def palette_action(writer, state, label)
  key(writer, F1)
  type_text(writer, label)
  await("F1 action #{label}") { screen_text(state).include?(label) }
  key(writer, ENTER)
end

def choose_buffer_proposals(writer, state)
  palette_action(writer, state, "Chat context")
  await("Buffer proposals context choice") do
    text = screen_text(state).downcase
    text.include?("buffer read tools") && text.include?("buffer proposals")
  end
  4.times { key(writer, DOWN) }
  key(writer, ENTER)
  await("Buffer proposals context selected") { screen_text(state).downcase.include?("buffer proposals") }
end

def send_review?(state)
  text = screen_text(state).downcase
  text.include?("review chat send") || (text.include?("send this prompt") && text.include?("visible history"))
end

def preview_visible?(state)
  text = screen_text(state).downcase
  text.include?("chat proposed edits") && text.include?("selected 1/") &&
    text.include?("group 1/") && text.include?("main.cr") && text.include?("alpha=42") &&
    text.include?("apply selected") && text.include?("esc reject")
end

def preview_controls_visible?(text)
  text = text.downcase
  text.include?("apply") && (text.include?("esc reject") || text.include?("esc=reject") || text.include?("esc-"))
end

def read_exact(socket, count)
  output = +""
  while output.bytesize < count
    part = socket.read(count - output.bytesize)
    raise "truncated loopback request body" unless part
    output << part
  end
  output
end

def read_chunked(socket)
  output = +""
  loop do
    size_line = socket.gets("\r\n") || raise("truncated chunked request")
    size = size_line.split(";", 2).first.to_i(16)
    break if size.zero?
    output << read_exact(socket, size)
    raise "invalid chunk terminator" unless socket.read(2) == "\r\n"
  end
  output
end

def receive_http(socket)
  request_line = socket.gets("\r\n") || raise("empty loopback request")
  headers = {}
  while (line = socket.gets("\r\n")) && line != "\r\n"
    name, value = line.split(":", 2)
    headers[name.downcase] = value.to_s.strip
  end
  body = if headers["transfer-encoding"]&.downcase == "chunked"
           read_chunked(socket)
         else
           read_exact(socket, headers.fetch("content-length", "0").to_i)
         end
  method, path, = request_line.split(" ", 3)
  {method: method, path: path, headers: headers, body: body}
end

def sse_chunk(delta, finish_reason)
  value = {
    "id" => "chatcmpl-local-fixture",
    "object" => "chat.completion.chunk",
    "created" => 0,
    "model" => "fixture-model",
    "choices" => [{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}],
  }
  "data: #{JSON.generate(value)}\n\n"
end

def sse_tool_response(name, call_id, arguments)
  payload = sse_chunk({"tool_calls" => [{
    "index" => 0,
    "id" => call_id,
    "type" => "function",
    "function" => {"name" => name, "arguments" => JSON.generate(arguments)},
  }]}, nil)
  payload + sse_chunk({}, "tool_calls") + "data: [DONE]\n\n"
end

def sse_complete_response(prompt_marker)
  sse_chunk({"content" => "#{prompt_marker}_COMPLETE_SENTINEL"}, nil) +
    sse_chunk({}, "stop") + "data: [DONE]\n\n"
end

def write_sse(socket, payload)
  socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
               "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
end

def body_scope(body)
  messages = body.fetch("messages")
  content = messages.reverse.find { |message| message["role"] == "user" }.fetch("content")
  match = content.match(/buffer ID ([^,\s]+), revision ([^\s]+)/) ||
    raise("request omitted the exact approved buffer ID/revision")
  [match[1], match[2], content]
end

def latest_tool_name(body)
  body.fetch("messages").reverse_each do |message|
    next unless message["role"] == "assistant" && message.key?("tool_calls")
    return message.fetch("tool_calls").last.dig("function", "name")
  end
  nil
end

def latest_tool_call(body)
  body.fetch("messages").reverse_each do |message|
    next unless message["role"] == "assistant" && message.key?("tool_calls")
    call = message.fetch("tool_calls").last
    function = call.fetch("function")
    arguments = function.fetch("arguments")
    arguments = JSON.parse(arguments) if arguments.is_a?(String)
    return {name: function.fetch("name"), arguments: arguments,
            id: call.fetch("id")}
  end
  nil
end

def assert_proposal_ack(tool_message, buffer_id, revision)
  result = JSON.parse(tool_message.fetch("content"))
  assert(result.fetch("status") == "ok", "proposal owner result was not status=ok")
  data = result.fetch("data")
  pending = data["pending_review"] == true || data["status"] == "pending_review"
  assert(pending, "proposal owner result did not mean pending manual review")
  assert(data["applied"] == false, "proposal owner result claimed edits were applied")
  assert(data["buffer_id"] == buffer_id, "proposal owner result changed the target buffer ID")
  assert(data["revision"] == revision, "proposal owner result changed the target revision")
end

def start_fake_provider
  listener = TCPServer.new("127.0.0.1", 0)
  requests = Queue.new
  errors = Queue.new
  releases = Queue.new
  request_count = {mutex: Mutex.new, value: 0}
  thread = Thread.new do
    loop do
      socket = listener.accept
      begin
        request = receive_http(socket)
        body = JSON.parse(request[:body])
        requests << request
        request_count[:mutex].synchronize { request_count[:value] += 1 }
        tools = body.fetch("tools")
        declared = tools.map { |tool| tool.dig("function", "name") }
        unless declared.sort == ["editor_propose_edits", "editor_read_buffer"]
          raise "BufferProposals request did not expose exactly read + propose tools"
        end
        buffer_id, revision, user_content = body_scope(body)
        marker = %w[LATE_CANCEL ESCAPE_REJECT MANUAL_ACCEPT].find { |item| user_content.include?(item) } ||
          raise("fixture could not identify the current prompt")
        read_name = latest_tool_name(body)
        if read_name.nil?
          assert(body.fetch("messages").none? { |message| message["role"] == "tool" },
                 "initial request already had a tool result")
          assert(!request[:body].include?("alpha=1"),
                 "initial proposal request uploaded source before a read-tool call")
          assert(!request[:body].include?("beta=2"),
                 "initial proposal request uploaded unrequested source lines")
          args = {
            "buffer_id" => buffer_id, "revision" => revision,
            "start_line" => 1, "line_count" => 1,
            "start_column" => 0, "max_columns" => 128,
          }
          payload = sse_tool_response("editor_read_buffer", "#{marker.downcase}-read", args)
        elsif read_name == "editor_read_buffer"
          read_result = body.fetch("messages").reverse.find { |message| message["role"] == "tool" } ||
            raise("read continuation omitted its tool result")
          read_content = read_result.fetch("content")
          raise("read continuation omitted selected source line") unless read_content.include?("alpha=1")
          raise("read continuation included an unrequested source line") if read_content.include?("beta=2")
          raise("read continuation included another file") if read_content.include?("PRIVATE_FILE_SENTINEL")
          read_call = latest_tool_call(body)
          raise("provider did not request the exact read tool") unless read_call && read_call[:name] == "editor_read_buffer"
          read_args = read_call.fetch(:arguments)
          raise("read tool changed exact selected buffer ID") unless read_args.fetch("buffer_id") == buffer_id
          raise("read tool changed exact selected revision") unless read_args.fetch("revision") == revision
          raise("read tool widened the selected source range") unless read_args.fetch("start_line") == 1 && read_args.fetch("line_count") == 1
          args = {
            "buffer_id" => buffer_id, "revision" => revision,
            "edits" => [{
              "start_line" => 1, "start_column" => 6,
              "end_line" => 1, "end_column" => 7, "new_text" => "42",
            }],
          }
          payload = sse_tool_response("editor_propose_edits", "#{marker.downcase}-proposal", args)
        elsif read_name == "editor_propose_edits"
          result = body.fetch("messages").reverse.find { |message| message["role"] == "tool" } ||
            raise("proposal continuation omitted its owner result")
          proposal_call = latest_tool_call(body)
          raise("provider did not request the exact proposal tool") unless proposal_call && proposal_call[:name] == "editor_propose_edits"
          proposal_args = proposal_call.fetch(:arguments)
          raise("proposal tool changed exact selected buffer ID") unless proposal_args.fetch("buffer_id") == buffer_id
          raise("proposal tool changed exact selected revision") unless proposal_args.fetch("revision") == revision
          edits = proposal_args.fetch("edits")
          raise("proposal tool did not request exactly one bounded edit") unless edits.size == 1
          edit = edits.first
          expected_edit = {"start_line" => 1, "start_column" => 6,
                           "end_line" => 1, "end_column" => 7,
                           "new_text" => "42"}
          raise("proposal tool changed the exact expected edit") unless edit == expected_edit
          assert_proposal_ack(result, buffer_id, revision)
          payload = if marker == "LATE_CANCEL"
                      PENDING_COMPLETION
                    else
                      sse_complete_response(marker)
                    end
        else
          raise "fixture observed an unrecognized tool continuation"
        end

        if payload.equal?(PENDING_COMPLETION)
          releases.pop
          payload = sse_complete_response(marker)
        end
        write_sse(socket, payload)
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET
        # Cancellation is expected to close the held final response socket.
      rescue StandardError => error
        errors << error.class.name
      ensure
        socket.close rescue nil
      end
    end
  rescue IOError, Errno::EBADF
    # The listener is closed by the bounded fixture's ensure path.
  end
  [listener, thread, requests, errors, releases, request_count, listener.addr[1]]
end

def pop_request(queue, errors, label, seconds: 10.0)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    return queue.pop(true) unless queue.empty?
    raise "fake provider failed while serving #{label}" unless errors.empty?
    raise "timeout waiting for fake-provider #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
end

def check_provider_request(request, marker, source_sentinel)
  assert(request[:method] == "POST", "provider did not use POST")
  assert(request[:path] == "/v1/chat/completions", "provider changed the configured endpoint path")
  assert(request[:headers]["authorization"] == "Bearer #{CHAT_FIXTURE_KEY}",
         "provider did not use only the synthetic Authorization key")
  body_text = request[:body].force_encoding(Encoding::UTF_8)
  assert(body_text.include?(marker), "approved request omitted the exact current prompt")
  assert(!body_text.include?(CHAT_FIXTURE_KEY), "credential leaked into provider request body")
  assert(!body_text.include?("PRIVATE_FILE_SENTINEL"), "provider received an unselected on-disk file")
  body = JSON.parse(body_text)
  tool_messages = body.fetch("messages").select { |message| message["role"] == "tool" }
  if tool_messages.empty?
    assert(!body_text.include?(source_sentinel), "source text was uploaded before a selected-buffer read")
  else
    assert(body_text.include?(source_sentinel), "bounded selected-buffer read result was omitted from continuation")
  end
  assert(!body_text.include?("beta=2"), "provider request contained an unrequested source line")
  tools = body.fetch("tools").map { |tool| tool.dig("function", "name") }
  assert(tools.sort == ["editor_propose_edits", "editor_read_buffer"], "provider tool grant widened")
  body
end

def choose_and_send(writer, state, prompt)
  palette_action(writer, state, "Focus Chat")
  type_text(writer, prompt)
  choose_buffer_proposals(writer, state)
  key(writer, ENTER)
  await("Send review for #{prompt}") { send_review?(state) }
  disclosure = stable_screen_text(state).downcase.lines.map { |line| line.strip }.join(" ").gsub(/-\s+/, "-")
  assert(disclosure.include?("model may read and send bounded excerpts"),
         "Send review omitted bounded selected-buffer read scope")
  assert(disclosure.include?("one proposal attempt") && disclosure.include?("32 edits"),
         "Send review omitted the bounded proposal capability")
  assert(disclosure.include?("manual review only") && disclosure.include?("never auto-") &&
         disclosure.include?("applied/saved"),
         "Send review did not distinguish proposals from automatic edits or saves")
  key(writer, "y")
end

fake_server, fake_thread, requests, fixture_errors, releases, request_count, port = start_fake_provider
temp_root = Dir.mktmpdir("adamantine-chat-edit-pty-")
root = File.realpath(temp_root)
project = File.join(root, "project")
state_home = File.join(root, "state")
FileUtils.mkdir_p(project, mode: 0o700)
Dir.mkdir(state_home, 0o700)
source = File.join(project, "main.cr")
private_source = File.join(project, "private.cr")
original_source = "alpha=1\r\nbeta=2\r\n"
File.binwrite(source, original_source)
File.write(private_source, "PRIVATE_FILE_SENTINEL\n")
config = File.join(root, "config.json")
File.write(config, JSON.generate({
  "chat" => {
    "enabled" => true,
    "endpoint" => "http://127.0.0.1:#{port}/v1/chat/completions",
    "model" => "fixture-model",
    "key_env" => KEY_ENV,
    "max_completion_tokens" => 64,
  },
}))

env = {
  "TERM" => "xterm-256color",
  "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
  "LANG" => ENV.fetch("LANG", "C.UTF-8"),
  "HOME" => state_home,
  "XDG_CONFIG_HOME" => File.join(state_home, "config"),
  "XDG_CACHE_HOME" => File.join(state_home, "cache"),
  "XDG_STATE_HOME" => state_home,
  "ADAMANTINE_STATE_HOME" => state_home,
  "ADAMANTINE_SESSION" => "0",
  "ADAMANTINE_RECOVERY" => "0",
  KEY_ENV => CHAT_FIXTURE_KEY,
}

reader = slave = child_pid = drain = nil
state = {mutex: Mutex.new, screen: PtyScreen.new(WIDTH, HEIGHT), screen_error: nil}
original_digest = Digest::SHA256.file(source).hexdigest
private_digest = Digest::SHA256.file(private_source).hexdigest

begin
  Timeout.timeout(timeout_seconds) do
    reader, slave = PTY.open
    reader.winsize = [HEIGHT, WIDTH]
    child_pid = Process.spawn(env, binary, project, "--config", config, "--no-lsp",
                              in: slave, out: slave, err: slave, unsetenv_others: true)
    drain = Thread.new do
      begin
        loop do
          chunk = reader.readpartial(65_536)
          state[:mutex].synchronize do
            begin
              state[:screen].feed(chunk)
            rescue PtyScreen::UnsupportedSequence
              state[:screen_error] = true
            end
          end
        end
      rescue EOFError, Errno::EIO
      rescue StandardError => error
        state[:mutex].synchronize { state[:screen_error] = error.class.name }
      end
    end
    slave.close
    slave = nil

    await("production App readiness") do
      state[:mutex].synchronize do
        state[:screen].revision.positive? && state[:screen].alternate_screen? &&
          state[:screen].kitty_keyboard_enabled? && state[:screen].include?("Adamantine")
      end
    end
    sleep 0.25
    assert(requests.empty?, "startup contacted the configured provider")
    assert(!screen_text(state).include?(CHAT_FIXTURE_KEY), "synthetic credential appeared on screen")

    palette_action(reader, state, "open file path")
    type_text(reader, source)
    key(reader, ENTER)
    await("selected source opened") { screen_has?(state, "alpha=1") }
    assert(Digest::SHA256.file(source).hexdigest == original_digest, "opening source changed disk bytes")

    # Cancel after both tools have returned but before successful completion.
    choose_and_send(reader, state, "LATE_CANCEL_SENTINEL")
    first = pop_request(requests, fixture_errors, "late-cancel read round")
    check_provider_request(first, "LATE_CANCEL_SENTINEL", "alpha=1")
    second = pop_request(requests, fixture_errors, "late-cancel proposal round")
    check_provider_request(second, "LATE_CANCEL_SENTINEL", "alpha=1")
    third = pop_request(requests, fixture_errors, "held late-cancel completion")
    check_provider_request(third, "LATE_CANCEL_SENTINEL", "alpha=1")
    sleep 0.2
    assert(!preview_visible?(state), "proposal preview appeared before successful turn completion")
    assert(!screen_text(state).include?("alpha=42"), "model proposal changed the editor before completion/acceptance")
    assert(Digest::SHA256.file(source).hexdigest == original_digest, "unaccepted proposal changed disk bytes")
    key(reader, ESCAPE)
    sleep 0.2
    releases << true
    sleep 0.35
    assert(!preview_visible?(state), "late completion resurrected a canceled proposal preview")
    assert(!screen_text(state).include?("alpha=42"), "late completion changed editor text without acceptance")

    # A completed proposal can be rejected through the existing inline preview.
    choose_and_send(reader, state, "ESCAPE_REJECT_SENTINEL")
    %w[read proposal completion].each do |round|
      request = pop_request(requests, fixture_errors, "escape-reject #{round} round")
      check_provider_request(request, "ESCAPE_REJECT_SENTINEL", "alpha=1")
    end
    begin
      await("completed proposal preview") { preview_visible?(state) }
    rescue RuntimeError => error
      tail = screen_text(state).lines.map { |line| line.strip }
        .select { |line| line.match?(/chat|propos|alpha=|main\.cr|saved|warning|error|apply|esc|enter|resize/i) }
        .last(16).join(" | ")
      failures = fixture_errors.empty? ? "none" : fixture_errors.pop(true)
      raise "#{error.message}; fixture_error=#{failures}; visible_tail=#{tail}"
    end
    stable_preview = stable_screen_text(state)
    STDERR.puts(stable_preview) if ENV["CHAT_EDIT_CAPTURE_SCREEN"] == "1"
    assert(stable_preview.downcase.include?("not saved"),
           "stable proposal preview omitted its not-saved scope")
    assert(preview_controls_visible?(stable_preview),
           "stable proposal preview omitted manual accept/reject controls: #{stable_preview.lines.last(14).map { |line| line.strip }.join(" | ")}")
    assert(stable_preview.include?("alpha=42"), "completed preview omitted the candidate edit")
    key(reader, ESCAPE)
    await("proposal rejection") { !preview_visible?(state) }
    assert(screen_text(state).include?("alpha=1"), "Escape rejection changed the selected buffer")
    assert(!screen_text(state).include?("alpha=42"), "Escape rejection left candidate text visible")
    assert(Digest::SHA256.file(source).hexdigest == original_digest, "Escape rejection wrote to disk")

    # A fresh turn stages the same candidate; only Enter accepts it. The edit
    # is one buffer Undo and remains unsaved on disk.
    choose_and_send(reader, state, "MANUAL_ACCEPT_SENTINEL")
    %w[read proposal completion].each do |round|
      request = pop_request(requests, fixture_errors, "manual-accept #{round} round")
      check_provider_request(request, "MANUAL_ACCEPT_SENTINEL", "alpha=1")
    end
    await("fresh completed proposal preview") { preview_visible?(state) }
    assert(screen_text(state).include?("alpha=42"), "fresh preview omitted the candidate text")
    key(reader, ENTER)
    await("manual proposal acceptance") { screen_text(state).include?("alpha=42") && !preview_visible?(state) }
    assert(Digest::SHA256.file(source).hexdigest == original_digest, "manual acceptance saved editor changes automatically")
    key(reader, CTRL_Z)
    begin
      await("single Undo restores original source") { screen_text(state).include?("alpha=1") }
    rescue RuntimeError => error
      tail = screen_text(state).lines.map { |line| line.strip }
        .select { |line| line.match?(/chat|propos|alpha=|main\.cr|undo|focus|warning|error/i) }
        .last(14).join(" | ")
      raise "#{error.message}; visible_tail=#{tail}"
    end
    assert(Digest::SHA256.file(source).hexdigest == original_digest, "Undo changed disk bytes")
    key(reader, CTRL_Z)
    sleep 0.2
    assert(screen_text(state).include?("alpha=1"), "proposal created more than one Undo step")
    assert(Digest::SHA256.file(source).hexdigest == original_digest, "second Undo changed disk bytes")
    assert(Digest::SHA256.file(private_source).hexdigest == private_digest, "proposal flow changed an unopened file")
    assert(!screen_text(state).include?(CHAT_FIXTURE_KEY), "synthetic provider credential appeared on screen")
    assert(requests.empty?, "provider retried a completed proposal turn")
    assert(fixture_errors.empty?, "fake provider fixture failed while serving requests")
    served_count = request_count[:mutex].synchronize { request_count[:value] }
    assert(served_count == 9, "expected exactly 9 approved HTTP rounds, observed #{served_count}")
    assert(fake_thread.alive?, "fake provider fixture stopped before the smoke completed")

    puts "PASS: no-LSP production App exposes only selected-buffer read/propose; proposals stay pending until Complete and manual inline acceptance; Escape/revocation do not mutate, Enter creates one Undo, and source files remain unsaved."
  end
ensure
  releases << true rescue nil
  if child_pid
    begin
      Process.kill("TERM", child_pid)
      Process.wait(child_pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end
  end
  slave&.close rescue nil
  reader&.close rescue nil
  drain&.kill
  drain&.join(1)
  fake_server.close rescue nil
  fake_thread.kill
  fake_thread.join(1)
  FileUtils.remove_entry(root) if root && File.directory?(root)
end
