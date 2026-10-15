#!/usr/bin/env ruby
require "digest"
require "fileutils"
require "io/console"
require "json"
require "open3"
require "optparse"
require "pathname"
require "pty"
require "socket"
require "tmpdir"
require "timeout"
require_relative "lib/pty_screen"

# Real production-App coverage for the one-shot Chat-to-named-Lua boundary.
# The only provider is a literal-loopback fixture and every Lua run uses the
# explicitly supplied private Lua 5.4 library and this exact editor binary.
options = {editor_bin: nil, library_path: nil, timeout: 180.0}
if __FILE__ == $PROGRAM_NAME
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/smoke_chat_lua.rb --editor-bin PATH --library-path PATH [--timeout SECONDS]"
    parser.on("--editor-bin PATH", "Privately built production editor executable") { |path| options[:editor_bin] = path }
    parser.on("--library-path PATH", "Absolute path to a private compatible Lua 5.4 shared library") { |path| options[:library_path] = path }
    parser.on("--timeout SECONDS", Float, "Overall smoke deadline (default: 180)") { |seconds| options[:timeout] = seconds }
    parser.on("-h", "--help") { puts parser; exit 0 }
  end.parse!

  abort "--editor-bin and --library-path are required" unless options[:editor_bin] && options[:library_path]
  abort "--timeout must be between 30 and 300 seconds" unless options[:timeout].between?(30.0, 300.0)
end

WIDTH = 112
HEIGHT = 32
F1 = "\eOP".freeze
ENTER = "\e[13u".freeze
ESCAPE = "\e[27u".freeze
CURSOR_UP = "\e[A".freeze
CURSOR_DOWN = "\e[B".freeze
CTRL_Z = "\e[122;5u".freeze
CHAT_FIXTURE_KEY = "synthetic-chat-lua-fixture-key-not-a-credential".freeze
KEY_ENV = "ADAMANTINE_CHAT_LUA_FIXTURE_KEY".freeze
RUN_TOOL = "run_approved_lua_script".freeze
PROMPTS = {
  "CHAT_LUA_SUCCESS_TURN" => :hold_success,
  "CHAT_LUA_STICKY_TURN" => :complete,
  "CHAT_LUA_PROVIDER_FAILURE_TURN" => :fail_after_child,
  "CHAT_LUA_LATE_CANCEL_TURN" => :hold_success,
  "CHAT_LUA_HANG_TURN" => :hang,
}.freeze

def assert(condition, message)
  raise message unless condition
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def key(writer, sequence)
  if $pty_state
    $pty_state[:mutex].synchronize do
      $pty_state[:recent_inputs] << {
        at: monotonic,
        stage: $pty_state[:stage],
        bytes: sequence.b,
      }
      $pty_state[:recent_inputs].shift while $pty_state[:recent_inputs].length > 64
    end
  end
  writer.write(sequence)
  writer.flush
end

def set_stage(state, stage)
  state[:mutex].synchronize { state[:stage] = stage }
end

def terminal_failure_context(state, screen, error, bytes)
  raw = state[:raw_tail].b
  chunk = bytes.b
  sequence = case error.message
             when /\Aunhandled CSI sequence (.*)\z/m then "\e[#{Regexp.last_match(1)}".b
             when /\Aunhandled ESC sequence 0x([0-9a-f]+)\z/i
               "\e".b + [Regexp.last_match(1).to_i(16)].pack("C")
             else
               error.message.b
             end
  raw_location = raw.rindex(sequence)
  location = raw_location || chunk.rindex(sequence)
  snippet = if location
              source = raw_location ? raw : chunk
              left = [location - 32, 0].max
              source.byteslice(left, [sequence.bytesize + 64, source.bytesize - left].min)
            else
              bytes.byteslice(-160, 160) || bytes
            end
  input_echoes = state[:recent_inputs].select do |input|
    echoed_bytes = input[:bytes].gsub("\e".b, "^[".b)
    !echoed_bytes.empty? && snippet.include?(echoed_bytes)
  end.map do |input|
    {stage: input[:stage], age_ms: ((monotonic - input[:at]) * 1000).round,
     input_hex: input[:bytes].unpack1("H*")}
  end
  parser_state = %i[@state @csi @x @y @utf8_expected].to_h do |name|
    [name, screen.instance_variable_get(name)]
  end
  {
    message: error.message,
    stage: state[:stage],
    parser_state: parser_state,
    pty_bytes_read: state[:bytes_read],
    error_chunk_bytes: bytes.bytesize,
    sequence_hex: sequence.unpack1("H*"),
    raw_window_hex: snippet.unpack1("H*"),
    raw_window: snippet.inspect,
    recent_input_echo_matches: input_echoes,
    app_ready: state[:app_ready],
    terminal_mode: state[:terminal_mode],
  }
end

def await_terminal_raw_mode(terminal, state, seconds: 5.0)
  set_stage(state, "waiting for PTY raw mode (echo and canonical input disabled)")
  deadline = monotonic + seconds
  last_output = ""
  loop do
    last_output = IO.popen(["/bin/stty", "-a"], "r", in: terminal, err: File::NULL, &:read).strip
    status = $?
    raise "could not inspect PTY terminal mode (exit #{status.exitstatus}): #{last_output}" unless status.success?
    state[:mutex].synchronize { state[:terminal_mode] = last_output }
    return if last_output.match?(/(?:\A|[;\s])-echo(?:[;\s]|\z)/) &&
      last_output.match?(/(?:\A|[;\s])-icanon(?:[;\s]|\z)/)
    raise "timed out waiting for App PTY raw mode; stty -a: #{last_output}" if monotonic >= deadline
    sleep 0.02
  end
end

def type_text(writer, text)
  text.each_codepoint { |codepoint| key(writer, "\e[#{codepoint}u") }
end

def current_screen(state)
  state[:mutex].synchronize do
    raise "PTY screen tracker failed closed: #{state[:screen_error]}" if state[:screen_error]
    {revision: state[:screen].revision, rows: state[:screen].rows}
  end
end

def screen_text(state)
  current_screen(state)[:rows].join("\n")
end

def screen_has?(state, fragment)
  current_screen(state)[:rows].any? { |row| row.include?(fragment) }
end

def await(label, seconds: 8.0)
  deadline = monotonic + seconds
  until yield
    raise "timeout waiting for #{label}\n#{screen_text($pty_state)}" if monotonic >= deadline
    sleep 0.02
  end
end

def pop_queue(queue, label, seconds: 12.0)
  deadline = monotonic + seconds
  loop do
    begin
      return queue.pop(true)
    rescue ThreadError
      if monotonic >= deadline
        errors = $pty_state && $pty_state[:provider_errors]
        error_count = errors ? errors.size : 0
        raise "timeout waiting for #{label}; queued-provider-errors=#{error_count}; " \
              "screen=#{screen_text($pty_state).inspect}"
      end
      sleep 0.02
    end
  end
end

def palette_action(writer, state, label, child)
  key(writer, F1)
  type_text(writer, label)
  await("F1 action #{label}", seconds: 8.0) do
    screen_text(state).include?(label) && child_alive?(child)
  end
  key(writer, ENTER)
end

def choose_buffer_proposals(writer, state, child)
  palette_action(writer, state, "Chat context", child)
  await("Chat context picker", seconds: 8.0) do
    text = screen_text(state).downcase
    text.include?("buffer read tools") && text.include?("selection proposals") &&
      text.include?("whole-file proposals")
  end
  # Keep the existing whole-file Lua scenario on its separately approved
  # permission; Selection proposals now occupies index 4.
  5.times { key(writer, CURSOR_DOWN) }
  key(writer, ENTER)
  await("Whole-file proposals context", seconds: 5.0) do
    screen_text(state).downcase.include?("whole-file proposals")
  end
end

def choose_chat_script(writer, state, child, name)
  palette_action(writer, state, "Choose Lua script for next Chat turn", child)
  await("Chat Lua picker entry #{name.inspect}", seconds: 8.0) do
    screen_text(state).include?(name)
  end
  type_text(writer, name)
  await("filtered Chat Lua picker entry #{name.inspect}", seconds: 5.0) do
    screen_text(state).include?(name)
  end
  key(writer, ENTER)
  # Selection is shown by the later Send review; let the palette close before
  # focusing the composer so one key cannot be consumed by two surfaces.
  await("Chat Lua picker closed", seconds: 5.0) do
    !screen_text(state).include?("Choose Lua script for next Chat turn")
  end
end

def open_send_review(writer, state, child, prompt)
  palette_action(writer, state, "Focus Chat", child)
  type_text(writer, prompt)
  key(writer, ENTER)
  await("Send review for #{prompt}", seconds: 8.0) do
    text = screen_text(state).downcase
    text.include?("review chat send") || (text.include?("send this prompt") && text.include?("visible history"))
  end
end

def review_panel_text(rows)
  title_row = rows.index { |row| row.include?("Review Chat send") }
  return unless title_row

  title = rows[title_row]
  left = title.index("┌Review Chat send")
  return unless left
  right = title.index("┐", left)
  return unless right

  footer_row = rows.index.with_index do |row, index|
    index > title_row && row.include?("Up/Down scroll")
  end
  return unless footer_row

  bottom_row = rows.index.with_index do |row, index|
    index > footer_row && row[left] == "└" && row[right] == "┘"
  end
  return unless bottom_row
  return unless title[left] == "┌" && title[right] == "┐"
  return unless rows[footer_row][left] == "│" && rows[footer_row][right] == "│"

  width = right - left + 1
  rows[title_row..bottom_row].map { |row| row[left, width].to_s }.join("\n")
end

def review_scrolled_panel?(previous_panel, candidate_panel)
  previous_rows = previous_panel.split("\n", -1)
  candidate_rows = candidate_panel.split("\n", -1)
  return false unless previous_rows.size == candidate_rows.size

  footer_row = previous_rows.index { |row| row.include?("Up/Down scroll") }
  return false unless footer_row && candidate_rows[footer_row]&.include?("Up/Down scroll")

  # The lowest visible body row has no prior cell beyond the viewport to
  # compare against after a one-row scroll; strict source checks validate it
  # once it moves into the overlapping rows on a later scroll.
  body_rows = footer_row - 3
  return false unless body_rows.positive?
  return false unless previous_rows[0] == candidate_rows[0]
  return false unless previous_rows[footer_row..] == candidate_rows[footer_row..]

  candidate_rows[1, body_rows] == previous_rows[2, body_rows]
end

def stable_review_snapshot(state, previous_panel:, seconds: 0.5)
  deadline = monotonic + seconds
  candidate_panel = nil
  stable_observations = 0
  loop do
    snapshot = current_screen(state)
    panel = review_panel_text(snapshot[:rows])
    scrolled = panel && previous_panel && review_scrolled_panel?(previous_panel, panel)
    if panel && (previous_panel.nil? || scrolled)
      if panel == candidate_panel
        stable_observations += 1
      else
        candidate_panel = panel
        stable_observations = 1
      end
      return {panel: panel} if stable_observations >= 3
    else
      candidate_panel = nil
      stable_observations = 0
    end
    return unless monotonic < deadline
    sleep 0.01
  end
end

def collect_review_screens(writer, state)
  first = stable_review_snapshot(state, previous_panel: nil)
  raise "Send review did not produce a stable modal frame" unless first

  snapshots = [first[:panel]]
  prior_panel = first[:panel]
  unchanged = 0
  240.times do
    key(writer, CURSOR_DOWN)
    frame = stable_review_snapshot(state, previous_panel: prior_panel)
    if frame
      snapshots << frame[:panel]
      prior_panel = frame[:panel]
      unchanged = 0
    else
      unchanged += 1
      break if unchanged >= 3
    end
  end
  snapshots.join("\n")
end

def child_alive?(child)
  return false unless child && !child[:reaped]
  waited = Process.waitpid(child[:pid], Process::WNOHANG)
  if waited
    child[:reaped] = true
    child[:status] = $?
    false
  else
    true
  end
rescue Errno::ECHILD
  child[:reaped] = true
  false
end

def process_rows
  output, status = Open3.capture2("/bin/ps", "-ww", "-axo", "pid=,ppid=,stat=,command=")
  raise "could not inspect the App-owned Lua worker process list" unless status.success?
  output.lines.each_with_object([]) do |line, rows|
    fields = line.strip.split(/\s+/, 4)
    next unless fields.length == 4
    pid, ppid, state, command = fields
    rows << {pid: pid.to_i, ppid: ppid.to_i, state: state, command: command}
  end
end

def app_workers(parent_pid, binary)
  worker_path = File.realpath(binary)
  process_rows.select do |row|
    row[:ppid] == parent_pid && row[:command].include?(worker_path) &&
      row[:command].match?(/(?:\A|\s)--internal-lua-worker(?:\s|\z)/)
  end
end

def wait_for_worker(parent_pid, binary, child, seconds: 5.0)
  deadline = monotonic + seconds
  loop do
    workers = app_workers(parent_pid, binary)
    unless workers.empty?
      assert(workers.size == 1, "App started more than one Lua worker for a single approved call: #{workers.inspect}")
      return workers
    end
    raise "editor exited before its real Lua worker appeared" unless child_alive?(child)
    if monotonic >= deadline
      children = process_rows.select { |row| row[:ppid] == parent_pid }
      provider_queues = if $pty_state[:provider_events]
                          {events: $pty_state[:provider_events].size, errors: $pty_state[:provider_errors].size}
                        else
                          nil
                        end
      raise "timed out waiting for the real Lua worker (App pid #{parent_pid}); children=#{children.inspect}; provider_queues=#{provider_queues.inspect}\n#{screen_text($pty_state)}"
    end
    sleep 0.02
  end
end

def wait_for_no_workers(parent_pid, binary, child, seconds: 8.0)
  deadline = monotonic + seconds
  loop do
    workers = app_workers(parent_pid, binary)
    return if workers.empty?
    raise "Lua child was not reaped: #{workers.inspect}" if monotonic >= deadline
    raise "editor exited while its Lua child remained active" unless child_alive?(child)
    sleep 0.03
  end
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
    "id" => "chatcmpl-chat-lua-fixture",
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

def sse_complete_response(marker)
  sse_chunk({"content" => "#{marker}_COMPLETE_SENTINEL"}, nil) +
    sse_chunk({}, "stop") + "data: [DONE]\n\n"
end

def write_sse(socket, payload)
  socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
               "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
end

def prompt_marker(body)
  user = body.fetch("messages").reverse.find { |message| message["role"] == "user" } ||
    raise("provider request omitted its user prompt")
  content = user.fetch("content")
  PROMPTS.keys.find { |marker| content.include?(marker) } ||
    raise("provider request did not carry a recognized smoke prompt")
end

def latest_prompt_index(body, marker)
  messages = body.fetch("messages")
  index = messages.each_index.to_a.reverse.find do |position|
    message = messages[position]
    message["role"] == "user" && message["content"].to_s.include?(marker)
  end
  index || raise("provider request omitted current user prompt #{marker.inspect}")
end

def latest_tool_call(body, after_index: -1)
  messages = body.fetch("messages")
  (messages.size - 1).downto(after_index + 1) do |position|
    message = messages[position]
    next unless message["role"] == "assistant" && message.key?("tool_calls")
    call = message.fetch("tool_calls").last
    function = call.fetch("function")
    arguments = function.fetch("arguments")
    arguments = JSON.parse(arguments) if arguments.is_a?(String)
    return {id: call.fetch("id"), name: function.fetch("name"), arguments: arguments}
  end
  nil
end

def run_tool_definition(body)
  tools = body.fetch("tools")
  matches = tools.select { |tool| tool.dig("function", "name") == RUN_TOOL }
  assert(matches.size == 1, "provider request did not expose exactly one approved Lua function")
  definition = matches.first.fetch("function")
  parameters = definition.fetch("parameters")
  assert(parameters["type"] == "object", "Lua tool arguments are not an object")
  assert(parameters.fetch("properties") == {}, "Lua tool schema permits model-selected properties")
  assert(parameters.fetch("required") == [], "Lua tool schema requires model-selected fields")
  assert(parameters["additionalProperties"] == false, "Lua tool schema permits extra model-selected fields")
  definition
end

def check_provider_metadata!(request, fixture, marker)
  body = JSON.parse(request.fetch(:body))
  user_index = latest_prompt_index(body, marker)
  assert(latest_tool_call(body, after_index: user_index).nil?,
         "initial provider request already contained a model-selected Lua call")
  assert(request.fetch(:headers)["authorization"] == "Bearer #{CHAT_FIXTURE_KEY}",
         "loopback provider did not receive the synthetic authorization key")
  assert(!request.fetch(:body).include?(CHAT_FIXTURE_KEY), "synthetic credential leaked into provider request body")
  run_tool_definition(body)
  raw = request.fetch(:body)
  if marker == "CHAT_LUA_SUCCESS_TURN"
    # This is the first turn and has no prior approved read result in history.
    %w[alpha=1 beta=2].each do |selected_content|
      assert(!raw.include?(selected_content), "provider received selected-buffer bytes before the Lua read")
    end
  end
  [fixture[:project], fixture[:lua_root], *fixture[:lua_file_names]].each do |private_path|
    next if private_path.empty?
    assert(!raw.include?(private_path), "provider request exposed local path material #{private_path.inspect}")
  end
  fixture[:source_only_markers].each do |source_marker|
    assert(!raw.include?(source_marker), "provider request exposed frozen Lua source bytes #{source_marker.inspect}")
  end
  metadata = fixture[:metadata].fetch(marker)
  assert(raw.include?(metadata.fetch(:id)), "provider request omitted approved script ID metadata")
  assert(raw.include?(metadata.fetch(:name)), "provider request omitted approved script name metadata")
  assert(raw.include?(metadata.fetch(:digest)), "provider request omitted approved frozen source digest metadata")
  caps = metadata.fetch(:capabilities)
  caps.each do |capability|
    name = capability.downcase
    assert(raw.downcase.include?(name) || raw.downcase.include?(name.gsub("_", " ")) ||
           raw.downcase.include?(name.delete("_")),
           "provider request omitted effective capability #{capability.inspect}")
  end
  body
end

def find_tool_result(body, call_id)
  message = body.fetch("messages").reverse.find do |item|
    item["role"] == "tool" && item["tool_call_id"] == call_id
  end
  message || raise("provider continuation omitted the approved Lua tool result")
end

def check_continuation!(request, fixture, marker)
  body = JSON.parse(request.fetch(:body))
  user_index = latest_prompt_index(body, marker)
  call = latest_tool_call(body, after_index: user_index)
  assert(call && call[:name] == RUN_TOOL, "provider continuation lost the named Lua call")
  assert(call[:arguments] == {}, "provider continuation included model-selected Lua arguments")
  result = find_tool_result(body, call.fetch(:id)).fetch("content")
  assert(!result.empty?, "named Lua tool result was empty")
  expected_output = case marker
                    when "CHAT_LUA_SUCCESS_TURN" then "CHAT_LUA_POSITIVE_OUTPUT"
                    when "CHAT_LUA_PROVIDER_FAILURE_TURN" then "CHAT_LUA_FAILURE_OUTPUT"
                    when "CHAT_LUA_LATE_CANCEL_TURN" then "CHAT_LUA_CANCEL_OUTPUT"
                    end
  if expected_output
    assert(result.include?(expected_output), "real Lua output #{expected_output.inspect} was not returned to the provider")
  end
  if marker == "CHAT_LUA_SUCCESS_TURN"
    assert(result.include?("CHAT_LUA_READ_RECEIPT=alpha=1"),
           "provider continuation omitted the selected-buffer text explicitly read by the Lua script")
  end
  fixture[:source_only_markers].each do |source_marker|
    assert(!request.fetch(:body).include?(source_marker), "Lua source appeared in a provider continuation")
  end
  [fixture[:project], fixture[:lua_root], *fixture[:lua_file_names]].each do |private_path|
    assert(!request.fetch(:body).include?(private_path), "local path appeared in a provider continuation")
  end
  {body: body, result: result}
end

def start_provider(fixture)
  listener = TCPServer.new("127.0.0.1", 0)
  events = Queue.new
  errors = Queue.new
  releases = Queue.new
  thread = Thread.new do
    loop do
      socket = listener.accept
      begin
        request = receive_http(socket)
        raise "provider fixture expected POST" unless request[:method] == "POST"
        raise "provider fixture received a non-Chat-Completions path" unless request[:path] == "/v1/chat/completions"
        body = JSON.parse(request[:body])
        marker = prompt_marker(body)
        user_index = latest_prompt_index(body, marker)
        role_tools = !latest_tool_call(body, after_index: user_index).nil?
        unless role_tools
          events << {kind: :initial, marker: marker, request: request, at: monotonic}
          check_provider_metadata!(request, fixture, marker)
          write_sse(socket, sse_tool_response(RUN_TOOL, "#{marker.downcase}-lua", {}))
        else
          details = check_continuation!(request, fixture, marker)
          events << {kind: :continuation, marker: marker, request: request, details: details, at: monotonic}
          case PROMPTS.fetch(marker)
          when :hold_success
            events << {kind: :held, marker: marker}
            outcome = releases.pop
            if outcome == :failure
              socket.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            else
              events << {kind: :released, marker: marker}
              write_sse(socket, sse_complete_response(marker))
            end
          when :complete
            write_sse(socket, sse_complete_response(marker))
          when :fail_after_child
            socket.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            events << {kind: :failed, marker: marker}
          else
            raise "unknown provider fixture behavior for #{marker}"
          end
        end
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET
        # Cancellation may close the provider socket while a late response is
        # intentionally being released by the test thread.
      rescue StandardError => error
        errors << "at=#{monotonic}: #{error.class}: #{error.message}"
        begin
          socket.write("HTTP/1.1 500 Fixture Failure\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        rescue StandardError
        end
      ensure
        socket.close rescue nil
      end
    end
  rescue IOError, Errno::EBADF
  end
  [listener, thread, events, errors, releases, listener.addr[1]]
end

def open_fixture_source(writer, state, child, path)
  palette_action(writer, state, "open file path", child)
  type_text(writer, path)
  key(writer, ENTER)
  await("selected source file", seconds: 8.0) { screen_has?(state, "alpha=1") }
end

def start_chat_turn(writer, state, child, name, prompt)
  # Chat context is reset after each provider turn. Re-select the scoped
  # capability mode for every independently reviewed Send.
  choose_buffer_proposals(writer, state, child)
  choose_chat_script(writer, state, child, name)
  open_send_review(writer, state, child, prompt)
end

def accept_send(writer, state, fixture, marker, script_key, mutate_script_after_review: false)
  review = collect_review_screens(writer, state)
  normalized = review.gsub(/\s+/, " ")
  metadata = fixture[:metadata].fetch(marker)
  digest_row = /SHA-256:\s*#{Regexp.escape(metadata.fetch(:digest))}/i
  assert(review.match?(digest_row), "Send review omitted the full frozen source SHA-256")
  assert(normalized.include?(marker), "Send review omitted the current prompt #{marker.inspect}")
  source_lines = fixture[:sources].fetch(script_key).lines.map { |line| line.strip.gsub(/\s+/, " ") }.reject(&:empty?)
  source_heading = "Script source (frozen locally; not sent to provider)"
  cursor = normalized.index(source_heading)
  assert(cursor, "Send review omitted the local-source/provider disclosure")
  cursor += source_heading.length
  source_lines.each_with_index do |source_line, index|
    location = normalized.index(source_line, cursor)
    if location.nil?
      visible_rows = review.lines.select do |line|
        line.include?("Script source") || line.include?("CHAT_LUA_") || line.include?("local source_only")
      end.uniq.first(24)
      excerpt = normalized[cursor, 700]
      raise "Send review omitted Lua source line #{index + 1}: #{source_line}; " \
            "after-heading=#{excerpt.inspect}; visible-source-rows=#{visible_rows.inspect}"
    end
    cursor = location + source_line.length
  end
  assert(normalized.include?(metadata.fetch(:name)), "Send review omitted the selected named script")
  unless normalized.include?("main.cr") && normalized.match?(/revision\s+\S+/i)
    receipt_rows = review.lines.select do |line|
      line.match?(/editor source|exact buffer|revision|main\.cr/i)
    end.uniq
    raise "Send review omitted the selected-buffer path/revision receipt: #{receipt_rows.inspect}"
  end
  metadata.fetch(:capabilities).each do |capability|
    display = capability.downcase.gsub("_", " ")
    compact = capability.downcase.delete("_")
    assert(normalized.downcase.include?(capability.downcase) || normalized.downcase.include?(display) ||
           normalized.downcase.include?(compact),
           "Send review omitted requested/effective capability #{capability.inspect}")
  end
  disclosure = normalized.downcase
  assert(disclosure.include?("requested") && disclosure.include?("effective") && disclosure.include?("excluded"),
         "Send review omitted requested/effective/excluded capability disclosure")
  assert(normalized.downcase.include?("source") && normalized.downcase.include?("provider"),
         "Send review omitted local-source/provider-output disclosure")
  if mutate_script_after_review
    path = File.join(fixture[:lua_scripts], "success.lua")
    File.binwrite(path, "print('CHAT_LUA_MUTATED_AFTER_REVIEW')\n")
  end
  key(writer, "y")
end

def preview_visible?(state)
  text = screen_text(state).downcase
  text.include?("chat proposed edits") && text.include?("selected 1/") &&
    text.include?("group 1/") && text.include?("main.cr") &&
    text.include?("apply") && (text.include?("esc reject") || text.include?("esc: reject"))
end

def assert_no_preview_or_edit!(state, source, original_digest, private_source, private_digest, label)
  assert(!preview_visible?(state), "#{label}: a Chat Lua proposal preview became visible")
  %w[alpha=42 alpha=66 alpha=77 alpha=88].each do |candidate|
    assert(!screen_text(state).include?(candidate), "#{label}: candidate text #{candidate.inspect} appeared before acceptance")
  end
  assert(Digest::SHA256.file(source).hexdigest == original_digest, "#{label}: selected source bytes changed on disk")
  assert(Digest::SHA256.file(private_source).hexdigest == private_digest, "#{label}: unopened file bytes changed")
end

def send_cancel(writer, state, child)
  key(writer, ESCAPE)
  sleep 0.15
  raise "editor exited during Chat cancellation" unless child_alive?(child)
end

def write_fixture(root)
  project = File.join(root, "project")
  home = File.join(root, "home")
  state_home = File.join(root, "state")
  lua_root = File.join(home, ".config", "adamantine", "lua")
  lua_scripts = File.join(lua_root, "scripts")
  [project, state_home, lua_scripts].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
  [root, home, state_home].each { |path| File.chmod(0o700, path) }

  source = File.join(project, "main.cr")
  private_source = File.join(project, "private.cr")
  original_source = "alpha=1\nbeta=2\n"
  File.binwrite(source, original_source)
  File.write(private_source, "CHAT_LUA_PRIVATE_FILE_SENTINEL\n")

  success_source = <<~LUA
    local source_only = "CHAT_LUA_POSITIVE_SOURCE_ONLY"
    local selected = editor.context.selected_buffer
    assert(selected)
    local read = editor.call("editor.read_buffer", {
      buffer_id=selected.buffer_id, revision=selected.revision,
      start_line=1, line_count=1, start_column=0, max_columns=64
    })
    assert(read.status == "ok" and read.data.lines[1].text == "alpha=1")
    print("CHAT_LUA_READ_RECEIPT=" .. read.data.lines[1].text)
    local proposal = editor.call("editor.propose_edits", {
      buffer_id=selected.buffer_id, revision=selected.revision,
      edits={{start_line=1,start_column=6,end_line=1,end_column=7,new_text="42"}}
    })
    assert(proposal.status == "ok")
    print("CHAT_LUA_POSITIVE_OUTPUT")
  LUA
  sticky_source = <<~LUA
    local source_only = "CHAT_LUA_STICKY_SOURCE_ONLY"
    local selected = editor.context.selected_buffer
    assert(selected)
    local proposal = editor.call("editor.propose_edits", {
      buffer_id=selected.buffer_id, revision=selected.revision,
      edits={{start_line=1,start_column=6,end_line=1,end_column=7,new_text="77"}}
    })
    assert(proposal.status == "ok")
    local ok, denied = pcall(function()
      return editor.call("editor.read_buffer", {
        buffer_id="not-the-reviewed-buffer", revision=selected.revision,
        start_line=1, line_count=1, start_column=0, max_columns=64
      })
    end)
    print("CHAT_LUA_IGNORED_DENIAL=" .. (ok and denied.status or "caught"))
  LUA
  failure_source = <<~LUA
    local source_only = "CHAT_LUA_FAILURE_SOURCE_ONLY"
    local selected = editor.context.selected_buffer
    local proposal = editor.call("editor.propose_edits", {
      buffer_id=selected.buffer_id, revision=selected.revision,
      edits={{start_line=1,start_column=6,end_line=1,end_column=7,new_text="66"}}
    })
    assert(proposal.status == "ok")
    print("CHAT_LUA_FAILURE_OUTPUT")
  LUA
  cancel_source = <<~LUA
    local source_only = "CHAT_LUA_CANCEL_SOURCE_ONLY"
    local selected = editor.context.selected_buffer
    local proposal = editor.call("editor.propose_edits", {
      buffer_id=selected.buffer_id, revision=selected.revision,
      edits={{start_line=1,start_column=6,end_line=1,end_column=7,new_text="88"}}
    })
    assert(proposal.status == "ok")
    print("CHAT_LUA_CANCEL_OUTPUT")
  LUA
  hang_source = <<~LUA
    local source_only = "CHAT_LUA_HANG_SOURCE_ONLY"
    print("CHAT_LUA_WORKER_ACTIVE_SENTINEL")
    while true do end
  LUA

  entries = [
    {id: "chat-success", name: "Chat Lua success fixture", file: "success.lua", capabilities: %w[read_editor propose_edits], source: success_source},
    {id: "chat-sticky", name: "Chat Lua sticky-denial fixture", file: "sticky.lua", capabilities: %w[read_editor propose_edits], source: sticky_source},
    {id: "chat-provider-failure", name: "Chat Lua provider-failure fixture", file: "provider-failure.lua", capabilities: %w[read_editor propose_edits], source: failure_source},
    {id: "chat-cancel", name: "Chat Lua late-cancel fixture", file: "cancel.lua", capabilities: %w[read_editor propose_edits], source: cancel_source},
    {id: "chat-hang", name: "Chat Lua cancellation fixture", file: "hang.lua", capabilities: [], source: hang_source},
  ]
  entries.each { |entry| File.binwrite(File.join(lua_scripts, entry[:file]), entry[:source]) }
  File.write(File.join(lua_root, "manifest.json"), JSON.generate(
    version: 1,
    scripts: entries.map { |entry| entry.slice(:id, :name, :file, :capabilities) }
  ))

  prompt_by_id = {
    "chat-success" => "CHAT_LUA_SUCCESS_TURN",
    "chat-sticky" => "CHAT_LUA_STICKY_TURN",
    "chat-provider-failure" => "CHAT_LUA_PROVIDER_FAILURE_TURN",
    "chat-cancel" => "CHAT_LUA_LATE_CANCEL_TURN",
    "chat-hang" => "CHAT_LUA_HANG_TURN",
  }
  metadata = entries.to_h do |entry|
    [prompt_by_id.fetch(entry[:id]), {
      id: entry[:id],
      name: entry[:name],
      digest: Digest::SHA256.hexdigest(entry[:source]),
      capabilities: entry[:capabilities],
    }]
  end

  {
    project: project,
    home: home,
    state_home: state_home,
    source: source,
    private_source: private_source,
    original_source: original_source,
    lua_root: lua_root,
    lua_scripts: lua_scripts,
    lua_file_names: entries.map { |entry| entry[:file] },
    source_only_markers: %w[CHAT_LUA_POSITIVE_SOURCE_ONLY CHAT_LUA_STICKY_SOURCE_ONLY CHAT_LUA_FAILURE_SOURCE_ONLY CHAT_LUA_CANCEL_SOURCE_ONLY CHAT_LUA_HANG_SOURCE_ONLY CHAT_LUA_MUTATED_AFTER_REVIEW],
    sources: {success: success_source, sticky: sticky_source, failure: failure_source, cancel: cancel_source, hang: hang_source},
    metadata: metadata,
    entries: entries,
  }
end

def run_smoke(binary, library_path, timeout_seconds:)
  binary = File.realpath(binary)
  library_path = File.realpath(library_path)
  assert(File.file?(binary) && File.executable?(binary), "editor binary is not executable")
  assert(Pathname.new(library_path).absolute? && File.file?(library_path), "Lua library path must be an existing absolute file")

  temp_root = Dir.mktmpdir("adamantine-chat-lua-pty-")
  root = File.realpath(temp_root)
  fixture = write_fixture(root)
  fake_config = File.join(root, "chat-config.json")
  listener, fake_thread, events, fixture_errors, releases, port = start_provider(fixture)
  File.write(fake_config, JSON.generate({
    "chat" => {
      "enabled" => true,
      "endpoint" => "http://127.0.0.1:#{port}/v1/chat/completions",
      "model" => "fixture-model",
      "key_env" => KEY_ENV,
      "max_completion_tokens" => 128,
    },
  }))

  env = {
    "TERM" => "xterm-256color",
    "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
    "LANG" => "C.UTF-8",
    "HOME" => fixture[:home],
    "XDG_CONFIG_HOME" => File.join(fixture[:home], ".config"),
    "XDG_CACHE_HOME" => File.join(fixture[:state_home], "cache"),
    "XDG_STATE_HOME" => fixture[:state_home],
    "ADAMANTINE_STATE_HOME" => fixture[:state_home],
    "ADAMANTINE_SESSION" => "0",
    "ADAMANTINE_RECOVERY" => "0",
    "ADAMANTINE_LUA_WORKER" => binary,
    "ADAMANTINE_LUA_LIBRARY" => library_path,
    KEY_ENV => CHAT_FIXTURE_KEY,
  }
  reader = slave = terminal_probe = drain = nil
  child = nil
  state = {mutex: Mutex.new, screen: PtyScreen.new(WIDTH, HEIGHT), screen_error: nil}
  state[:raw_tail] = +"".b
  state[:bytes_read] = 0
  state[:recent_inputs] = []
  state[:stage] = "spawned; waiting for production App readiness"
  state[:app_ready] = false
  state[:provider_events] = events
  state[:provider_errors] = fixture_errors
  $pty_state = state
  original_digest = Digest::SHA256.file(fixture[:source]).hexdigest
  private_digest = Digest::SHA256.file(fixture[:private_source]).hexdigest
  begin
    Timeout.timeout(timeout_seconds) do
      reader, slave = PTY.open
      reader.winsize = [HEIGHT, WIDTH]
      terminal_probe = slave.dup
      pid = Process.spawn(env, binary, fixture[:project], "--config", fake_config, "--no-lsp",
                          in: slave, out: slave, err: slave, unsetenv_others: true)
      child = {pid: pid, reaped: false, status: nil}
      drain = Thread.new do
        begin
          loop do
            bytes = reader.readpartial(65_536)
            state[:mutex].synchronize do
              state[:bytes_read] += bytes.bytesize
              state[:raw_tail] << bytes
              state[:raw_tail] = state[:raw_tail].byteslice(-8_192, 8_192) if state[:raw_tail].bytesize > 8_192
              begin
                state[:screen].feed(bytes)
              rescue PtyScreen::UnsupportedSequence => error
                state[:screen_error] = terminal_failure_context(state, state[:screen], error, bytes).inspect
              end
            end
          end
        rescue EOFError, Errno::EIO
          state[:mutex].synchronize do
            begin
              state[:screen].finish!
            rescue PtyScreen::UnsupportedSequence => error
              state[:screen_error] ||= error.message
            end
          end
        rescue StandardError => error
          state[:mutex].synchronize { state[:screen_error] ||= "#{error.class}: #{error.message}" }
        end
      end
      slave.close
      slave = nil

      await("production App readiness", seconds: 15.0) do
        state[:mutex].synchronize do
          state[:screen].revision.positive? && state[:screen].alternate_screen? &&
            state[:screen].kitty_keyboard_enabled? && state[:screen].include?("Adamantine")
        end
      end
      await_terminal_raw_mode(terminal_probe, state)
      set_stage(state, "App ready; opening selected source buffer")
      state[:mutex].synchronize { state[:app_ready] = true }
      assert(!screen_text(state).include?(CHAT_FIXTURE_KEY), "synthetic provider credential appeared on screen")
      open_fixture_source(reader, state, child, fixture[:source])
      assert(Digest::SHA256.file(fixture[:source]).hexdigest == original_digest, "opening selected source changed disk bytes")
      assert(screen_has?(state, "beta=2"), "second source line was not present in the local fixture")

      # Success: source, digest and grants are locally reviewed, only metadata
      # reaches the provider, and a real child proposal stays hidden until the
      # whole provider turn returns Complete.
      set_stage(state, "opening first Chat-Lua Send review")
      start_chat_turn(reader, state, child, "Chat Lua success fixture", "CHAT_LUA_SUCCESS_TURN")
      accept_send(reader, state, fixture, "CHAT_LUA_SUCCESS_TURN", :success,
                  mutate_script_after_review: true)
      initial = pop_queue(events, "success provider request")
      assert(initial[:kind] == :initial && initial[:marker] == "CHAT_LUA_SUCCESS_TURN", "success turn sent an unexpected provider request")
      assert(initial[:request][:headers]["authorization"] == "Bearer #{CHAT_FIXTURE_KEY}", "provider fixture did not receive its synthetic credential")
      assert(!initial[:request][:body].include?(CHAT_FIXTURE_KEY), "synthetic credential leaked into provider request body")
      continuation = pop_queue(events, "success Lua result continuation")
      assert(continuation[:kind] == :continuation && continuation[:marker] == "CHAT_LUA_SUCCESS_TURN", "success turn did not return the Lua result to the provider")
      assert(continuation[:details][:result].include?("CHAT_LUA_POSITIVE_OUTPUT"), "provider did not receive real script output")
      assert(!continuation[:details][:result].include?("CHAT_LUA_MUTATED_AFTER_REVIEW"),
             "Chat Lua run re-read mutable catalog bytes instead of executing the reviewed frozen source")
      assert(continuation[:details][:result].include?("CHAT_LUA_READ_RECEIPT=alpha=1"),
             "provider did not receive text read from the exact selected buffer")
      wait_for_no_workers(child[:pid], binary, child, seconds: 8.0)
      held = pop_queue(events, "held provider Complete for success")
      assert(held == {kind: :held, marker: "CHAT_LUA_SUCCESS_TURN"}, "success provider did not hold its final Complete")
      sleep 0.25
      assert_no_preview_or_edit!(state, fixture[:source], original_digest, fixture[:private_source], private_digest,
                                "after Lua reap and before provider Complete")
      releases << :success
      success_release = pop_queue(events, "provider release after success")
      assert(success_release == {kind: :released, marker: "CHAT_LUA_SUCCESS_TURN"},
             "synthetic provider did not release the held success after the explicit gate")
      await("completed Chat Lua proposal preview", seconds: 12.0) { preview_visible?(state) }
      assert(screen_text(state).include?("alpha=42"), "completed Lua candidate was missing from manual review")
      key(reader, ENTER)
      await("manual Chat Lua proposal acceptance", seconds: 8.0) do
        screen_text(state).include?("alpha=42") && !preview_visible?(state)
      end
      assert(Digest::SHA256.file(fixture[:source]).hexdigest == original_digest,
             "manual Chat Lua proposal acceptance saved source bytes automatically")
      key(reader, CTRL_Z)
      await("one Undo restores Chat Lua source", seconds: 8.0) { screen_text(state).include?("alpha=1") }
      assert(Digest::SHA256.file(fixture[:source]).hexdigest == original_digest, "Undo wrote Chat Lua changes to disk")
      key(reader, CTRL_Z)
      sleep 0.15
      assert(screen_text(state).include?("alpha=1"), "Chat Lua proposal created more than one Undo step")
      assert(Digest::SHA256.file(fixture[:private_source]).hexdigest == private_digest,
             "Chat Lua proposal changed an unopened file")

      # A provider-approved child stages an edit, catches and ignores an
      # out-of-scope read refusal, and then returns normally. The refusal must
      # poison the child result so neither its candidate nor a later Complete
      # can turn into a manual proposal.
      start_chat_turn(reader, state, child, "Chat Lua sticky-denial fixture", "CHAT_LUA_STICKY_TURN")
      accept_send(reader, state, fixture, "CHAT_LUA_STICKY_TURN", :sticky)
      sticky_initial = pop_queue(events, "sticky-denial provider request")
      assert(sticky_initial[:kind] == :initial && sticky_initial[:marker] == "CHAT_LUA_STICKY_TURN",
             "sticky-denial turn sent an unexpected request: #{sticky_initial.inspect}; " \
             "fixture-error-count=#{fixture_errors.size}; screen=#{screen_text(state).inspect}")
      sticky_continuation = pop_queue(events, "sticky-denial provider continuation")
      assert(sticky_continuation[:kind] == :continuation, "provider did not observe the failed child result")
      assert(sticky_continuation[:details][:result].downcase.match?(/denied|refus|fail|error/),
             "ignored out-of-scope RPC was not reported as child failure to the provider")
      wait_for_no_workers(child[:pid], binary, child)
      sleep 0.25
      assert_no_preview_or_edit!(state, fixture[:source], original_digest, fixture[:private_source], private_digest,
                                "after ignored child refusal and provider Complete")

      # A successful child may stage a proposal, but a later provider failure
      # must still discard it before it becomes an editor preview.
      start_chat_turn(reader, state, child, "Chat Lua provider-failure fixture", "CHAT_LUA_PROVIDER_FAILURE_TURN")
      accept_send(reader, state, fixture, "CHAT_LUA_PROVIDER_FAILURE_TURN", :failure)
      failure_initial = pop_queue(events, "provider-failure fixture request")
      assert(failure_initial[:kind] == :initial && failure_initial[:marker] == "CHAT_LUA_PROVIDER_FAILURE_TURN",
             "provider-failure fixture sent an unexpected request")
      failure_continuation = pop_queue(events, "provider-failure Lua result continuation")
      assert(failure_continuation[:kind] == :continuation &&
             failure_continuation[:details][:result].include?("CHAT_LUA_FAILURE_OUTPUT"),
             "provider did not receive the successful child's staged-proposal result before failure")
      wait_for_no_workers(child[:pid], binary, child)
      provider_failure = pop_queue(events, "provider failure after successful Lua child")
      assert(provider_failure == {kind: :failed, marker: "CHAT_LUA_PROVIDER_FAILURE_TURN"},
             "synthetic provider did not fail after receiving the successful Lua result")
      sleep 0.35
      assert_no_preview_or_edit!(state, fixture[:source], original_digest, fixture[:private_source], private_digest,
                                "after provider failure following successful Lua child")

      # Cancellation after a successful child reap but while the provider owns
      # the final response must revoke the staged proposal permanently.
      start_chat_turn(reader, state, child, "Chat Lua late-cancel fixture", "CHAT_LUA_LATE_CANCEL_TURN")
      accept_send(reader, state, fixture, "CHAT_LUA_LATE_CANCEL_TURN", :cancel)
      cancel_initial = pop_queue(events, "late-cancel provider request")
      assert(cancel_initial[:kind] == :initial, "late-cancel turn sent an unexpected request")
      cancel_continuation = pop_queue(events, "late-cancel Lua result continuation")
      assert(cancel_continuation[:kind] == :continuation, "late-cancel provider did not receive its Lua result")
      assert(cancel_continuation[:details][:result].include?("CHAT_LUA_CANCEL_OUTPUT"),
             "late-cancel provider did not receive the successful real-script result")
      wait_for_no_workers(child[:pid], binary, child)
      held_cancel = pop_queue(events, "held provider Complete for cancelled turn")
      assert(held_cancel == {kind: :held, marker: "CHAT_LUA_LATE_CANCEL_TURN"}, "late-cancel provider did not hold Complete")
      sleep 0.2
      assert_no_preview_or_edit!(state, fixture[:source], original_digest, fixture[:private_source], private_digest,
                                "before cancellation of a completed Lua child")
      send_cancel(reader, state, child)
      releases << :success
      late_release = pop_queue(events, "late Complete attempt after cancellation")
      assert(late_release == {kind: :released, marker: "CHAT_LUA_LATE_CANCEL_TURN"},
             "synthetic provider did not attempt its late success after cancellation")
      sleep 0.35
      assert_no_preview_or_edit!(state, fixture[:source], original_digest, fixture[:private_source], private_digest,
                                "after late provider Complete following cancellation")

      # A non-cooperative Lua loop must not block the App owner. Escape cancels
      # the parent, terminates and reaps the one real worker, and leaves no
      # delayed tool result or proposal behind.
      start_chat_turn(reader, state, child, "Chat Lua cancellation fixture", "CHAT_LUA_HANG_TURN")
      accept_send(reader, state, fixture, "CHAT_LUA_HANG_TURN", :hang)
      hang_initial = pop_queue(events, "active-worker provider request")
      hang_observed_at = monotonic
      assert(hang_initial[:kind] == :initial && hang_initial[:marker] == "CHAT_LUA_HANG_TURN", "active-worker turn sent an unexpected request")
      hang_workers = wait_for_worker(child[:pid], binary, child)
      worker_observed_at = monotonic
      assert(!hang_workers.empty?, "active-worker turn did not start a real child")
      sleep 0.2
      active_workers = app_workers(child[:pid], binary)
      assert(active_workers.size == 1, "non-cooperative Lua child did not remain active after startup: #{active_workers.inspect}")
      assert(events.empty?, "provider received a tool-result continuation while the Lua child was still active; queued events=#{events.size}")
      assert(fixture_errors.empty?, "provider fixture failed while the Lua child was active: #{fixture_errors.pop(true) rescue "unknown fixture error"}; " \
        "initial_to_observation=#{(hang_observed_at - hang_initial[:at]).round(3)}s; " \
        "worker_wait=#{(worker_observed_at - hang_observed_at).round(3)}s; elapsed_from_initial=#{(monotonic - hang_initial[:at]).round(3)}s")
      assert(!screen_text(state).include?("CHAT_LUA_WORKER_ACTIVE_SENTINEL"),
             "incomplete Chat Lua child output was exposed before its terminal result")
      assert_no_preview_or_edit!(state, fixture[:source], original_digest, fixture[:private_source], private_digest,
                                "while the non-cooperative Lua child is active")
      # Opening F1 proves the input owner still services user actions while the
      # child remains active; selecting anything is unnecessary for this check.
      key(reader, F1)
      type_text(reader, "Focus Chat")
      await("responsive F1 palette while Lua child runs", seconds: 2.0) { screen_has?(state, "Focus Chat") }
      active_workers = app_workers(child[:pid], binary)
      assert(active_workers.size == 1, "App lost or duplicated the single Lua worker before cancellation: #{active_workers.inspect}")
      assert(events.empty?, "provider received a tool-result continuation before cancellation; queued events=#{events.size}")
      key(reader, ESCAPE)
      await("close the F1 palette before cancelling the Chat turn", seconds: 2.0) do
        !screen_has?(state, "Focus Chat")
      end
      key(reader, ESCAPE)
      wait_for_no_workers(child[:pid], binary, child, seconds: 8.0)
      sleep 0.35
      assert(events.empty?, "provider received a delayed result from the cancelled non-cooperative child; queued events=#{events.size}")
      assert(fixture_errors.empty?, "provider fixture failed after cancelling the non-cooperative child: #{fixture_errors.pop(true) rescue "unknown fixture error"}")
      assert(!preview_visible?(state), "cancelled active child produced a Chat proposal preview")
      assert(Digest::SHA256.file(fixture[:source]).hexdigest == original_digest,
             "cancelled active child changed selected source bytes")
      assert(fixture_errors.empty?, "loopback provider fixture failed: #{fixture_errors.pop(true) rescue "unknown fixture error"}")
      assert(fake_thread.alive?, "synthetic provider stopped before the PTY smoke completed")
      assert(child_alive?(child), "production editor exited before the smoke completed")
      puts "PASS: reviewed metadata-only Chat Lua runs use real Lua 5.4 child processes; direct selected-buffer reads reach the provider, proposals wait for child reap and provider Complete, refusal/provider-failure/cancel fail closed, manual edits are one-Undo and unsaved, and the App remains responsive."
    end
  ensure
    releases << :success rescue nil
    if child && child_alive?(child)
      app_workers(child[:pid], binary).each do |worker|
        Process.kill("TERM", worker[:pid])
      rescue Errno::ESRCH
      end
      begin
        Process.kill("TERM", child[:pid])
        Process.wait(child[:pid])
        child[:reaped] = true
      rescue Errno::ESRCH, Errno::ECHILD
      end
    end
    slave&.close rescue nil
    terminal_probe&.close rescue nil
    reader&.close rescue nil
    drain&.kill
    drain&.join(1)
    listener.close rescue nil
    fake_thread.kill
    fake_thread.join(1)
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end
end

if __FILE__ == $PROGRAM_NAME
  binary = options[:editor_bin]
  library_path = options[:library_path]
  run_smoke(binary, library_path, timeout_seconds: options[:timeout])
end
