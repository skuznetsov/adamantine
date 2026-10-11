#!/usr/bin/env ruby
require "fileutils"
require "digest"
require "io/console"
require "json"
require "pty"
require "socket"
require "tmpdir"
require "timeout"
require_relative "lib/pty_screen"

# Production App privacy/consent smoke against a literal-loopback fake provider.
# This never contacts a model service and only uses a synthetic fixture key.
binary = ARGV.fetch(0) { abort "usage: ruby scripts/smoke_chat_provider_adversary.rb EDITOR_BIN [TIMEOUT_SECONDS]" }
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
CHAT_FIXTURE_KEY = "synthetic-chat-provider-fixture-key-not-a-credential".freeze
KEY_ENV = "ADAMANTINE_CHAT_PROVIDER_FIXTURE_KEY".freeze

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
    raise "PTY screen tracker failed closed" if state[:screen_error]
    state[:screen].rows
  end
end

def screen_has?(state, text)
  rows(state).any? { |row| row.include?(text) }
end

def screen_text(state)
  rows(state).join("\n")
end

def stable_screen_text(state, quiet_seconds: 0.20, timeout_seconds: 2.0)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
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
    raise "timeout waiting for a stable PTY screen" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
end

def send_review?(state)
  text = screen_text(state).downcase
  text.include?("send this prompt") && text.include?("visible history")
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
  await("F1 action #{label}") { screen_has?(state, label) }
  key(writer, ENTER)
end

def choose_context(writer, state, choice_index)
  palette_action(writer, state, "Chat context")
  await("context choice list") do
    text = screen_text(state).downcase
    text.include?("none") && text.include?("selection") &&
      text.include?("active buffer") && text.include?("buffer read tools")
  end
  choice_index.times { key(writer, DOWN) }
  key(writer, ENTER)
  label = ["None", "Selection", "Active buffer", "Buffer read tools"].fetch(choice_index)
  await("#{label} context shown") { screen_text(state).downcase.include?(label.downcase) }
end

def choose_active_buffer_context(writer, state)
  choose_context(writer, state, 2)
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

def start_fake_provider
  listener = TCPServer.new("127.0.0.1", 0)
  requests = Queue.new
  thread = Thread.new do
    loop do
      client = listener.accept
      begin
        request = receive_http(client)
        requests << request
        body = JSON.parse(request[:body])
        messages = body.fetch("messages")
        tool_result = messages.any? { |message| message["role"] == "tool" }
        user_content = messages.reverse.find { |message| message["role"] == "user" }.fetch("content")
        if body.key?("tools") && !tool_result
          scope = user_content.match(/buffer ID ([^,\s]+), revision ([^\s]+)/) ||
            raise("tool request omitted the exact approved buffer scope")
          arguments = JSON.generate({
            "buffer_id" => scope[1],
            "revision" => scope[2],
            "start_line" => 1,
            "line_count" => 1,
            "start_column" => 0,
            "max_columns" => 1024,
          })
          tool_delta = {"id" => "chatcmpl-fixture", "object" => "chat.completion.chunk", "created" => 0,
                        "model" => "fixture-model", "choices" => [{"index" => 0,
                          "delta" => {"tool_calls" => [{"index" => 0, "id" => "call_fixture_read",
                            "type" => "function", "function" => {"name" => "editor_read_buffer",
                              "arguments" => arguments}}]}, "finish_reason" => nil}]}
          finish = {"id" => "chatcmpl-fixture", "object" => "chat.completion.chunk", "created" => 0,
                    "model" => "fixture-model", "choices" => [{"index" => 0,
                      "delta" => {}, "finish_reason" => "tool_calls"}]}
          payload = "data: #{JSON.generate(tool_delta)}\n\n" \
                    "data: #{JSON.generate(finish)}\n\n" \
                    "data: [DONE]\n\n"
        else
          reply = if tool_result
                    "TOOL_RESULT_FIXTURE_REPLY"
                  elsif user_content.include?("SECOND_PROMPT_SENTINEL")
                    "SECOND_PROVIDER_FIXTURE_REPLY"
                  else
                    "PROVIDER_FIXTURE_REPLY"
                  end
          delta = {"id" => "chatcmpl-fixture", "object" => "chat.completion.chunk", "created" => 0,
                   "model" => "fixture-model", "choices" => [{"index" => 0,
                     "delta" => {"content" => reply}, "finish_reason" => nil}]}
          finish = {"id" => "chatcmpl-fixture", "object" => "chat.completion.chunk", "created" => 0,
                    "model" => "fixture-model", "choices" => [{"index" => 0,
                      "delta" => {}, "finish_reason" => "stop"}]}
          payload = "data: #{JSON.generate(delta)}\n\n" \
                    "data: #{JSON.generate(finish)}\n\n" \
                    "data: [DONE]\n\n"
        end
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                     "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      ensure
        client.close
      end
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # The listener is closed by the bounded fixture's ensure path.
  end
  [listener, thread, requests, listener.addr[1]]
end

fake_server, fake_thread, requests, port = start_fake_provider
temp_root = Dir.mktmpdir("adamantine-chat-provider-pty-")
root = File.realpath(temp_root)
project = File.join(root, "project")
state_home = File.join(root, "state")
FileUtils.mkdir_p(project, mode: 0o700)
Dir.mkdir(state_home, 0o700)
source = File.join(project, "main.cr")
private_source = File.join(project, "private.cr")
File.write(source, "SELECTED_BUFFER_SENTINEL\n")
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
state = {
  mutex: Mutex.new,
  screen: PtyScreen.new(WIDTH, HEIGHT),
  screen_error: nil,
}

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
    assert(!screen_text(state).include?(CHAT_FIXTURE_KEY), "fixture credential appeared on screen")

    palette_action(reader, state, "Chat settings")
    await("Chat settings modal") { screen_text(state).include?("Chat Provider Settings") }
    assert(!screen_text(state).include?(CHAT_FIXTURE_KEY), "Chat settings disclosed the resolved credential")
    assert(requests.empty?, "opening provider settings caused an HTTP request")
    source_digest = Digest::SHA256.file(source).hexdigest
    private_digest = Digest::SHA256.file(private_source).hexdigest
    key(reader, "\e[115;5u") # Explicitly saving settings must remain network- and key-resolution-silent.
    await("Chat settings save closes") { !screen_text(state).include?("Chat Provider Settings") }
    assert(requests.empty?, "saving provider settings caused an HTTP request")
    assert(Digest::SHA256.file(source).hexdigest == source_digest, "settings save changed the editor source")
    persisted_config = JSON.parse(File.read(config))
    assert(persisted_config.dig("chat", "enabled") == true, "settings save disabled the configured provider")
    assert(persisted_config.dig("chat", "model") == "fixture-model", "settings save changed the explicit model")
    assert(!File.read(config).include?(CHAT_FIXTURE_KEY), "settings save persisted the resolved credential")

    palette_action(reader, state, "open file path")
    type_text(reader, source)
    key(reader, ENTER)
    await("selected file opened") { screen_has?(state, "SELECTED_BUFFER_SENTINEL") }
    palette_action(reader, state, "Focus Chat")
    type_text(reader, "PROMPT_SENTINEL explain the selected buffer")
    key(reader, ENTER)
    await("Send disclosure review") { send_review?(state) }
    assert(stable_screen_text(state).downcase.include?("none"), "default Send review did not disclose None context")
    assert(requests.empty?, "opening the Send review contacted the provider before approval")
    key(reader, ENTER)
    await("Enter-default review closes") { !send_review?(state) }
    assert(screen_has?(state, "PROMPT_SENTINEL"), "cancelled Send review discarded the draft")
    sleep 0.25
    assert(requests.empty?, "Enter-default cancellation contacted the provider")

    choose_active_buffer_context(reader, state)
    assert(requests.empty?, "choosing context caused an HTTP request")
    key(reader, ENTER)
    await("second Send disclosure review") { send_review?(state) }
    assert(stable_screen_text(state).downcase.include?("active buffer"), "review omitted selected-context disclosure")
    assert(requests.empty?, "second review opened an HTTP request before approval")
    key(reader, ESCAPE)
    await("selected-context review cancels") { !send_review?(state) }
    assert(screen_has?(state, "PROMPT_SENTINEL"), "selected-context cancellation discarded the draft")
    sleep 0.25
    assert(requests.empty?, "cancelling selected-context review contacted the provider")

    # Context is one-shot: explicitly select again for the next Send.
    choose_active_buffer_context(reader, state)
    assert(requests.empty?, "reselecting context caused an HTTP request")
    key(reader, ENTER)
    await("approved-turn review") { send_review?(state) }
    assert(stable_screen_text(state).downcase.include?("active buffer"),
           "approved review lost selected context; visible screen: #{screen_text(state)}")
    type_text(reader, "y")

    await("approved request reaches only loopback fake") { !requests.empty? }
    request = requests.pop
    assert(request[:method] == "POST", "provider did not use POST")
    assert(request[:path] == "/v1/chat/completions", "provider changed the configured endpoint path")
    assert(request[:headers]["authorization"] == "Bearer #{CHAT_FIXTURE_KEY}",
           "provider did not resolve the configured fixture key at request time")
    assert(!File.read(config).include?(CHAT_FIXTURE_KEY), "resolved key was persisted to settings")
    body_text = request[:body].force_encoding(Encoding::UTF_8)
    body = JSON.parse(body_text)
    assert(body_text.include?("PROMPT_SENTINEL"), "approved request omitted the exact composer prompt")
    assert(body_text.include?("SELECTED_BUFFER_SENTINEL"), "approved request omitted explicitly selected context")
    assert(!body_text.include?("PRIVATE_FILE_SENTINEL"), "provider received an unselected on-disk file")
    assert(!body_text.include?(CHAT_FIXTURE_KEY), "provider credential leaked into the request body")
    assert(body["model"] == "fixture-model", "provider request did not use the explicit model")
    await("fixture assistant reply") { screen_has?(state, "PROVIDER_FIXTURE_REPLY") }
    assert(!screen_text(state).include?(CHAT_FIXTURE_KEY), "provider credential appeared in the rendered transcript")
    assert(requests.empty?, "provider retried the completed turn")

    # The selected context is one-shot. A later approved None turn may include
    # visible conversation history, but must not silently replay editor text.
    palette_action(reader, state, "Focus Chat")
    type_text(reader, "SECOND_PROMPT_SENTINEL answer without source context")
    key(reader, ENTER)
    await("second-turn disclosure review") { send_review?(state) }
    assert(stable_screen_text(state).downcase.include?("none"), "second Send reused one-shot editor context")
    assert(requests.empty?, "second Send review contacted the provider before approval")
    type_text(reader, "y")
    await("second approved turn reaches loopback fake") { !requests.empty? }
    second_request = requests.pop
    second_body_text = second_request[:body].force_encoding(Encoding::UTF_8)
    second_body = JSON.parse(second_body_text)
    assert(second_request[:method] == "POST", "second provider turn did not use POST")
    assert(second_request[:headers]["authorization"] == "Bearer #{CHAT_FIXTURE_KEY}",
           "second provider turn did not use only the fixture Authorization credential")
    assert(second_body_text.include?("SECOND_PROMPT_SENTINEL"), "second request omitted its prompt")
    assert(!second_body_text.include?("SELECTED_BUFFER_SENTINEL"), "one-shot editor context leaked into later None turn")
    assert(!second_body_text.include?("PRIVATE_FILE_SENTINEL"), "None turn uploaded an unselected on-disk file")
    assert(!second_body_text.include?(CHAT_FIXTURE_KEY), "provider credential leaked into second request body")
    assert(second_body["model"] == "fixture-model", "second request changed the explicit model")
    await("second fixture assistant reply") { screen_has?(state, "SECOND_PROVIDER_FIXTURE_REPLY") }
    assert(requests.empty?, "provider retried the second completed turn")

    # BufferTools authorizes one typed read from this exact selected buffer
    # revision, not discovery or arbitrary editor/filesystem access.
    palette_action(reader, state, "Focus Chat")
    type_text(reader, "THIRD_PROMPT_SENTINEL read the selected line")
    choose_context(reader, state, 3)
    key(reader, ENTER)
    await("BufferTools disclosure review") { send_review?(state) }
    buffer_tools_review = stable_screen_text(state).downcase
    # Keep the real approval key gated on seeing the selected source and its
    # bounded read/send scope. A long prompt or history can put that disclosure
    # below the initial viewport, so exercise the user-visible scroll path.
    disclosure_terms = ["model may read and send bounded excerpts", "main.cr", "revision",
                        "64 kib/result", "16 calls"]
    disclosure_required_scroll = !disclosure_terms.all? { |term| buffer_tools_review.include?(term) }
    if disclosure_required_scroll
      24.times do
        key(reader, DOWN)
        sleep 0.04
        buffer_tools_review = stable_screen_text(state, quiet_seconds: 0.08).downcase
        break if disclosure_terms.all? { |term| buffer_tools_review.include?(term) }
      end
    end
    assert(buffer_tools_review.include?("model may read and send bounded excerpts"),
           "BufferTools review omitted the read-and-send capability disclosure; visible screen: #{screen_text(state)}")
    assert(buffer_tools_review.include?("main.cr") && buffer_tools_review.include?("revision"),
           "BufferTools review omitted the selected source path or revision")
    assert(buffer_tools_review.include?("64 kib/result") && buffer_tools_review.include?("16 calls"),
           "BufferTools review omitted its bounded read limits")
    assert(requests.empty?, "BufferTools review contacted the provider before approval")
    type_text(reader, "y")

    await("approved BufferTools request reaches only loopback fake") { !requests.empty? }
    tool_request = requests.pop
    assert(tool_request[:method] == "POST", "BufferTools request did not use POST")
    assert(tool_request[:headers]["authorization"] == "Bearer #{CHAT_FIXTURE_KEY}",
           "BufferTools request did not use only the fixture Authorization credential")
    tool_body_text = tool_request[:body].force_encoding(Encoding::UTF_8)
    tool_body = JSON.parse(tool_body_text)
    assert(tool_body_text.include?("THIRD_PROMPT_SENTINEL"), "BufferTools request omitted its prompt")
    assert(!tool_body_text.include?("SELECTED_BUFFER_SENTINEL"),
           "BufferTools request uploaded source bytes before an exact read")
    assert(!tool_body_text.include?("PRIVATE_FILE_SENTINEL"), "BufferTools request exposed an unopened file")
    assert(!tool_body_text.include?(CHAT_FIXTURE_KEY), "BufferTools credential leaked into the body")
    declared_tools = tool_body.fetch("tools")
    assert(declared_tools.length == 1, "BufferTools request exposed more than one tool")
    assert(declared_tools.first.dig("function", "name") == "editor_read_buffer",
           "BufferTools request exposed a tool other than editor_read_buffer")
    user_scope = tool_body.fetch("messages").reverse.find { |message| message["role"] == "user" }.fetch("content")
    scope = user_scope.match(/approved read scope\): buffer ID ([^,\s]+), revision ([^\s]+)/) ||
      raise("approved BufferTools request omitted selected ID/revision")
    await("BufferTools continuation reaches loopback fake") { !requests.empty? }
    continuation = requests.pop
    assert(continuation[:method] == "POST", "BufferTools continuation did not use POST")
    assert(continuation[:headers]["authorization"] == "Bearer #{CHAT_FIXTURE_KEY}",
           "BufferTools continuation changed the Authorization credential")
    continuation_text = continuation[:body].force_encoding(Encoding::UTF_8)
    continuation_body = JSON.parse(continuation_text)
    assert(!continuation_text.include?(CHAT_FIXTURE_KEY), "credential leaked into tool continuation body")
    assert(!continuation_text.include?("PRIVATE_FILE_SENTINEL"), "tool continuation exposed an unopened file")
    assistant_tool_message = continuation_body.fetch("messages").find do |message|
      message["role"] == "assistant" && message.key?("tool_calls")
    end || raise("tool continuation omitted the assistant call record")
    call = assistant_tool_message.fetch("tool_calls").fetch(0)
    assert(call.dig("function", "name") == "editor_read_buffer", "continuation changed the approved tool name")
    arguments = JSON.parse(call.dig("function", "arguments"))
    assert(arguments["buffer_id"] == scope[1], "tool call changed the selected buffer ID")
    assert(arguments["revision"] == scope[2], "tool call changed the selected revision")
    result = continuation_body.fetch("messages").find { |message| message["role"] == "tool" } ||
      raise("tool continuation omitted the owner result")
    assert(result.fetch("content").include?("SELECTED_BUFFER_SENTINEL"),
           "owner result did not contain the exact selected line")
    assert(!result.fetch("content").include?("PRIVATE_FILE_SENTINEL"),
           "owner result contained an unopened-file sentinel")
    assert(requests.empty?, "provider exceeded the bounded one-tool continuation")
    await("tool-result assistant reply") { screen_has?(state, "TOOL_RESULT_FIXTURE_REPLY") }
    assert(!screen_text(state).include?(CHAT_FIXTURE_KEY), "credential appeared in BufferTools transcript")
    sleep 0.2
    assert(requests.empty?, "provider exceeded the four-POST maximum for three approved turns")
    assert(Digest::SHA256.file(source).hexdigest == source_digest,
           "chat provider flow changed the selected editor file")
    assert(Digest::SHA256.file(private_source).hexdigest == private_digest,
           "chat provider flow changed the unopened private file")

    disclosure_position = disclosure_required_scroll ? "after review scrolling" : "in the initial review viewport"
    puts "PASS: production App is startup/settings/context-selection silent; Cancel sends nothing;" \
         " explicit approval uploads only selected data, one-shot context does not replay, and BufferTools" \
         " disclosure is visible #{disclosure_position} before Y approval; one exact-buffer read" \
         " is followed by its bounded owner result."
  end
ensure
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
