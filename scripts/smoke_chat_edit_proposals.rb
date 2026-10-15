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
selection_only = ARGV.delete("--selection-only")
binary = ARGV.fetch(0) do
  abort "usage: ruby scripts/smoke_chat_edit_proposals.rb [--selection-only] EDITOR_BIN [TIMEOUT_SECONDS]"
end
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
RIGHT = "\e[C".freeze
HOME = "\e[H".freeze
SHIFT_RIGHT = "\e[1;2C".freeze
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

def choose_context_mode(writer, state, index, label)
  palette_action(writer, state, "Chat context")
  await("#{label} context choice") do
    text = screen_text(state).downcase
    text.include?("buffer read tools") && text.include?("selection proposals") &&
      text.include?("whole-file proposals")
  end
  index.times { key(writer, DOWN) }
  key(writer, ENTER)
  await("#{label} context selected") { screen_text(state).downcase.include?(label.downcase) }
end

def choose_buffer_proposals(writer, state)
  # None, Selection, Active buffer, Buffer read tools, Selection proposals,
  # Whole-file proposals.
  choose_context_mode(writer, state, 5, "Whole-file proposals")
end

def choose_selection_proposals(writer, state)
  # Selection proposals is a distinct permission from whole-file proposals.
  choose_context_mode(writer, state, 4, "Selection proposals")
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
  scope_from_tool = lambda do |tool_name|
    tool = body.fetch("tools").find { |entry| entry.dig("function", "name") == tool_name } ||
      raise("request omitted the approved #{tool_name} schema")
    properties = tool.dig("function", "parameters", "properties") ||
      raise("approved #{tool_name} schema omitted its properties")
    buffer_description = properties.dig("buffer_id", "description").to_s
    revision_description = properties.dig("revision", "description").to_s
    buffer_id = buffer_description.match(/\AApproved buffer ID: ([^,\s]+)\z/)&.[](1) ||
      raise("approved #{tool_name} schema omitted its exact buffer ID")
    revision = revision_description.match(/\AApproved revision: ([^,\s]+)\z/)&.[](1) ||
      raise("approved #{tool_name} schema omitted its exact revision")
    [buffer_id, revision]
  end
  read_scope = scope_from_tool.call("editor_read_buffer")
  proposal_scope = scope_from_tool.call("editor_propose_edits")
  assert(read_scope == proposal_scope, "read and proposal schemas disagree on the approved turn scope")
  [read_scope[0], read_scope[1], content]
end

def current_turn_messages(body)
  messages = body.fetch("messages")
  user_index = messages.rindex { |message| message["role"] == "user" } ||
    raise("request omitted the current user prompt")
  messages.drop(user_index)
end

def latest_tool_name(body)
  current_turn_messages(body).reverse_each do |message|
    next unless message["role"] == "assistant" && message.key?("tool_calls")
    return message.fetch("tool_calls").last.dig("function", "name")
  end
  nil
end

def latest_tool_call(body)
  current_turn_messages(body).reverse_each do |message|
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

def latest_tool_result(body)
  current_turn_messages(body).reverse.find { |message| message["role"] == "tool" }
end

def selection_context(body)
  messages = body.fetch("messages")
  content = messages.reverse.find { |message| message["role"] == "user" }.fetch("content")
  selected_marker = "User-selected source data (Selection proposals (read + propose); selection-scoped proposal scope):\n"
  selected_text = content.split(selected_marker, 2).last&.split("\n\nSource location metadata (JSON):\n", 2)&.first
  metadata_text = content.split("Source location metadata (JSON):\n", 2).last ||
    raise("selection request omitted location metadata")
  metadata = JSON.parse(metadata_text)
  read_tool = body.fetch("tools").find { |tool| tool.dig("function", "name") == "editor_read_buffer" } ||
    raise("selection request omitted read tool")
  propose_tool = body.fetch("tools").find { |tool| tool.dig("function", "name") == "editor_propose_edits" } ||
    raise("selection request omitted proposal tool")
  id_from = ->(tool, field, label) do
    description = tool.dig("function", "parameters", "properties", field, "description")
    match = description.to_s.match(/#{Regexp.escape(label)}: ([^,\s]+)/) ||
      raise("selection #{field} schema omitted #{label}")
    match[1]
  end
  buffer_id = id_from.call(read_tool, "buffer_id", "Approved buffer ID")
  revision = id_from.call(read_tool, "revision", "Approved revision")
  assert(id_from.call(propose_tool, "buffer_id", "Approved buffer ID") == buffer_id,
         "selection tools disagreed on the approved buffer ID")
  assert(id_from.call(propose_tool, "revision", "Approved revision") == revision,
         "selection tools disagreed on the approved revision")
  [content, selected_text, metadata, buffer_id, revision]
end

def assert_selection_metadata!(metadata)
  expected = {
    "source_path" => "main.cr",
    "selection_range" => {
      "start_line" => 1, "start_column" => 7,
      "end_line" => 1, "end_column" => 13,
    },
    "line_base" => 1,
    "column_base" => 0,
    "column_unit" => "unicode_codepoint",
    "end_exclusive" => true,
    "edit_scope" => "selection",
  }
  assert(metadata == expected, "selection location metadata changed: #{metadata.inspect}")
end

def check_selection_request(request, marker)
  assert(request[:method] == "POST", "selection fixture did not use POST")
  assert(request[:path] == "/v1/chat/completions", "selection fixture changed the configured endpoint path")
  assert(request[:headers]["authorization"] == "Bearer #{CHAT_FIXTURE_KEY}",
         "selection fixture did not use only the synthetic Authorization key")
  body_text = request[:body].force_encoding(Encoding::UTF_8)
  assert(!body_text.include?(CHAT_FIXTURE_KEY), "synthetic credential leaked into selection request body")
  assert(!body_text.include?("PRIVATE_FILE_SENTINEL"), "selection request disclosed an unopened file")
  assert(!body_text.include?("prefix_") && !body_text.include?("_suffix"),
         "selection request disclosed text outside the frozen selection")
  assert(!body_text.include?("OUTSIDE_SENTINEL"), "selection request disclosed an outside source line")
  body = JSON.parse(body_text)
  content, selected_text, metadata, buffer_id, revision = selection_context(body)
  assert(content.include?(marker), "selection request omitted the current prompt marker")
  assert(selected_text == "target", "selection request did not contain only the keyboard-selected text")
  assert_selection_metadata!(metadata)
  assert(body.fetch("tools").map { |tool| tool.dig("function", "name") }.sort ==
         ["editor_propose_edits", "editor_read_buffer"],
         "selection proposal request exposed an unexpected tool grant")
  [body, buffer_id, revision]
end

def denied_tool_result(body, tool_name)
  tool_call = latest_tool_call(body)
  assert(tool_call && tool_call[:name] == tool_name, "selection continuation changed its tool call")
  message = latest_tool_result(body) || raise("selection continuation omitted its tool result")
  result = JSON.parse(message.fetch("content"))
  assert(result["status"] == "denied", "out-of-selection tool call was not denied: #{result.inspect}")
  assert(message.fetch("content").downcase.include?("selection"),
         "out-of-selection denial did not identify the selection boundary")
  assert(!message.fetch("content").include?("prefix_") &&
         !message.fetch("content").include?("_suffix") &&
         !message.fetch("content").include?("OUTSIDE_SENTINEL"),
         "out-of-selection tool result leaked outside text")
end

def selection_fake_payload(request, body)
  markers = %w[SELECTION_OUTSIDE_READ SELECTION_OUTSIDE_BATCH SELECTION_MANUAL_ACCEPT]
  current_user_content = body.fetch("messages").reverse.find do |message|
    message["role"] == "user"
  end&.fetch("content") || raise("selection fixture could not identify the current user prompt")
  marker = markers.find { |item| current_user_content.include?(item) } ||
    raise("selection fixture could not identify the current prompt")
  body, buffer_id, revision = check_selection_request(request, marker)
  tool_name = latest_tool_name(body)
  if tool_name.nil?
    assert(current_turn_messages(body).none? { |message| message["role"] == "tool" },
           "initial selection request already had a tool result")
    if marker == "SELECTION_OUTSIDE_READ"
      args = {
        "buffer_id" => buffer_id, "revision" => revision,
        "start_line" => 1, "line_count" => 1,
        "start_column" => 0, "max_columns" => 6,
      }
      sse_tool_response("editor_read_buffer", "selection-outside-read", args)
    else
      edits = if marker == "SELECTION_OUTSIDE_BATCH"
                [
                  {"start_line" => 1, "start_column" => 7, "end_line" => 1,
                   "end_column" => 13, "new_text" => "MUST_NOT_STAGE"},
                  {"start_line" => 2, "start_column" => 0, "end_line" => 2,
                   "end_column" => 6, "new_text" => "BLOCKED"},
                ]
              else
                [{"start_line" => 1, "start_column" => 7, "end_line" => 1,
                  "end_column" => 13, "new_text" => "TARGET"}]
              end
      sse_tool_response("editor_propose_edits", "#{marker.downcase}-proposal",
        {"buffer_id" => buffer_id, "revision" => revision, "edits" => edits})
    end
  elsif tool_name == "editor_read_buffer" && marker == "SELECTION_OUTSIDE_READ"
    read_calls = current_turn_messages(body).sum do |message|
      next 0 unless message["role"] == "assistant" && message.key?("tool_calls")
      message.fetch("tool_calls").count { |call| call.dig("function", "name") == "editor_read_buffer" }
    end
    if read_calls == 1
      denied_tool_result(body, tool_name)
      read_call = latest_tool_call(body)
      args = read_call.fetch(:arguments)
      assert(args.fetch("start_line") == 1 && args.fetch("start_column") == 0 &&
             args.fetch("max_columns") == 6,
             "first selection read did not target the disjoint prefix")
      sse_tool_response("editor_read_buffer", "selection-inside-read",
        {"buffer_id" => buffer_id, "revision" => revision,
         "start_line" => 1, "line_count" => 1,
         "start_column" => 7, "max_columns" => 6})
    elsif read_calls == 2
      read_call = latest_tool_call(body)
      args = read_call.fetch(:arguments)
      assert(args.fetch("start_line") == 1 && args.fetch("start_column") == 7 &&
             args.fetch("max_columns") == 6,
             "follow-up selection read widened outside the frozen selection")
      result = latest_tool_result(body) || raise("bounded selection read omitted its tool result")
      content = result.fetch("content")
      assert(content.include?("target"), "bounded selection read omitted selected text")
      assert(!content.include?("prefix_") && !content.include?("_suffix") &&
             !content.include?("OUTSIDE_SENTINEL"),
             "bounded selection read leaked text outside the frozen range")
      sse_complete_response(marker)
    else
      raise "selection read scenario exceeded its two bounded tool calls"
    end
  elsif tool_name == "editor_propose_edits" && marker == "SELECTION_OUTSIDE_BATCH"
    denied_tool_result(body, tool_name)
    sse_complete_response(marker)
  elsif tool_name == "editor_propose_edits" && marker == "SELECTION_MANUAL_ACCEPT"
    message = latest_tool_result(body) || raise("selection proposal continuation omitted its owner result")
    proposal_call = latest_tool_call(body)
    assert(proposal_call && proposal_call[:name] == "editor_propose_edits",
           "selection provider did not receive its proposal continuation")
    proposal_args = proposal_call.fetch(:arguments)
    assert(proposal_args.fetch("buffer_id") == buffer_id && proposal_args.fetch("revision") == revision,
           "selection proposal changed its exact buffer receipt")
    expected = [{"start_line" => 1, "start_column" => 7, "end_line" => 1,
                 "end_column" => 13, "new_text" => "TARGET"}]
    assert(proposal_args.fetch("edits") == expected,
           "selection proposal changed its exact bounded edit")
    assert_proposal_ack(message, buffer_id, revision)
    sse_complete_response(marker)
  else
    raise "selection fixture observed an unexpected tool continuation"
  end
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

def start_fake_provider(selection_only: false)
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
        if selection_only
          payload = selection_fake_payload(request, body)
        else
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
          assert(current_turn_messages(body).none? { |message| message["role"] == "tool" },
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
          read_result = current_turn_messages(body).reverse.find { |message| message["role"] == "tool" } ||
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
          result = current_turn_messages(body).reverse.find { |message| message["role"] == "tool" } ||
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
  assert(disclosure.include?("proposal scope: whole file; model may read bounded excerpts and propose edits"),
         "Send review omitted explicit whole-file read/proposal scope")
  assert(disclosure.include?("one proposal attempt") && disclosure.include?("32 edits"),
         "Send review omitted the bounded proposal capability")
  assert(disclosure.include?("manual review only") && disclosure.include?("never auto-") &&
         disclosure.include?("applied/saved"),
         "Send review did not distinguish proposals from automatic edits or saves")
  key(writer, "y")
end

def selection_preview_visible?(state)
  text = screen_text(state).downcase
  text.include?("chat proposed edits") && text.include?("main.cr") &&
    text.include?("target") && preview_controls_visible?(text)
end

def choose_and_send_selection(writer, state, prompt)
  palette_action(writer, state, "Focus Chat")
  type_text(writer, prompt)
  choose_selection_proposals(writer, state)
  key(writer, ENTER)
  await("selection Send review for #{prompt}") { send_review?(state) }
  disclosure = stable_screen_text(state).downcase.lines.map { |line| line.strip }.join(" ").gsub(/-\s+/, "-")
  assert(disclosure.include?("approved source: main.cr"),
         "selection Send review omitted the relative source path")
  assert(disclosure.include?("selection scope: selection: 1:7–1:13"),
         "selection Send review omitted the exact half-open codepoint range")
  assert(disclosure.include?("only within this frozen selection"),
         "selection Send review omitted the selection-only edit boundary")
  assert(disclosure.include?("manual review only") && disclosure.include?("never auto-") &&
         disclosure.include?("applied/saved"),
         "selection Send review implied automatic acceptance or saving")
  key(writer, "y")
end

def run_selection_only_smoke(writer, state, requests, fixture_errors, request_count,
                             source, private_source, original_digest, private_digest)
  # A selection-scoped permission must remain unavailable without a real
  # selection, and that refusal must not contact the configured provider.
  palette_action(writer, state, "Focus editor")
  key(writer, HOME)
  palette_action(writer, state, "Chat context")
  await("selection context menu without a selection") do
    text = screen_text(state).downcase
    text.include?("selection proposals") && text.include?("whole-file proposals")
  end
  4.times { key(writer, DOWN) }
  key(writer, ENTER)
  await("selection proposal refused without a selection") do
    screen_text(state).downcase.include?("no non-empty editor selection")
  end
  assert(requests.empty? && request_count[:mutex].synchronize { request_count[:value] }.zero?,
         "selection mode without a selection contacted the provider")
  key(writer, ESCAPE)
  palette_action(writer, state, "Focus editor")

  # Select exactly "target" from the source using editor navigation and Shift+Right.
  # The provider-side coordinate assertions below fail closed if these real
  # keyboard events select a different fragment or use the wrong coordinate base.
  key(writer, HOME)
  7.times { key(writer, RIGHT) }
  6.times { key(writer, SHIFT_RIGHT) }

  choose_and_send_selection(writer, state, "SELECTION_OUTSIDE_READ")
  read_requests = 3.times.map do |index|
    request = pop_request(requests, fixture_errors, "selection-boundary read round #{index + 1}")
    check_selection_request(request, "SELECTION_OUTSIDE_READ")
    request
  end
  denied_tool_result(JSON.parse(read_requests[1][:body]), "editor_read_buffer")
  inside_result = latest_tool_result(JSON.parse(read_requests[2][:body])) ||
    raise("inside-selection read continuation omitted its result")
  assert(inside_result.fetch("content").include?("target") &&
         !inside_result.fetch("content").include?("prefix_") &&
         !inside_result.fetch("content").include?("_suffix") &&
         !inside_result.fetch("content").include?("OUTSIDE_SENTINEL"),
         "inside-selection read returned text outside the selected fragment")
  await("selection read completion") { screen_text(state).include?("SELECTION_OUTSIDE_READ_COMPLETE_SENTINEL") }
  assert(!selection_preview_visible?(state), "read-only denial unexpectedly staged a proposal")
  assert(Digest::SHA256.file(source).hexdigest == original_digest,
         "selection read attempt changed source bytes")

  choose_and_send_selection(writer, state, "SELECTION_OUTSIDE_BATCH")
  batch_requests = 2.times.map do |index|
    request = pop_request(requests, fixture_errors, "selection outside-batch round #{index + 1}")
    check_selection_request(request, "SELECTION_OUTSIDE_BATCH")
    request
  end
  denied_tool_result(JSON.parse(batch_requests[1][:body]), "editor_propose_edits")
  await("outside-batch completion") { screen_text(state).include?("SELECTION_OUTSIDE_BATCH_COMPLETE_SENTINEL") }
  assert(!selection_preview_visible?(state), "mixed in/out-of-selection batch created a preview")
  assert(!screen_text(state).include?("MUST_NOT_STAGE"),
         "in-selection edit was partially staged after an outside edit denied the batch")
  assert(Digest::SHA256.file(source).hexdigest == original_digest,
         "mixed out-of-selection proposal changed source bytes")

  choose_and_send_selection(writer, state, "SELECTION_MANUAL_ACCEPT")
  proposal_requests = 2.times.map do |index|
    request = pop_request(requests, fixture_errors, "selection manual-accept round #{index + 1}")
    check_selection_request(request, "SELECTION_MANUAL_ACCEPT")
    request
  end
  proposal_body = JSON.parse(proposal_requests[1][:body])
  result = latest_tool_result(proposal_body) || raise("manual selection proposal omitted its owner result")
  call = latest_tool_call(proposal_body) || raise("manual selection proposal omitted its tool call")
  assert(call[:name] == "editor_propose_edits", "manual selection proposal changed its tool")
  assert_proposal_ack(result, call[:arguments].fetch("buffer_id"), call[:arguments].fetch("revision"))
  await("completed selection proposal preview") { selection_preview_visible?(state) }
  stable_preview = stable_screen_text(state)
  assert(stable_preview.downcase.include?("not saved"),
         "selection proposal preview omitted its not-saved disclosure")
  assert(stable_preview.include?("TARGET"), "selection proposal preview omitted the proposed replacement")
  assert(Digest::SHA256.file(source).hexdigest == original_digest,
         "pending selection proposal changed source bytes")

  # Only the explicit preview acceptance applies the change. It stays unsaved,
  # and the entire proposal is one editor Undo action.
  key(writer, ENTER)
  await("manual selection proposal acceptance") do
    screen_text(state).include?("prefix_TARGET_suffix") && !selection_preview_visible?(state)
  end
  assert(Digest::SHA256.file(source).hexdigest == original_digest,
         "manual selection acceptance saved editor changes automatically")
  key(writer, CTRL_Z)
  await("single Undo restores selected source") { screen_text(state).include?("prefix_target_suffix") }
  assert(Digest::SHA256.file(source).hexdigest == original_digest, "selection Undo changed disk bytes")
  key(writer, CTRL_Z)
  sleep 0.2
  assert(screen_text(state).include?("prefix_target_suffix"),
         "selection proposal created more than one Undo action")
  assert(Digest::SHA256.file(source).hexdigest == original_digest, "second selection Undo changed disk bytes")
  assert(Digest::SHA256.file(private_source).hexdigest == private_digest,
         "selection proposal changed an unopened file")
  assert(!screen_text(state).include?(CHAT_FIXTURE_KEY), "synthetic provider credential appeared on screen")
  assert(requests.empty?, "selection provider retried a completed turn")
  assert(fixture_errors.empty?, "selection fake provider fixture failed while serving requests")
  served_count = request_count[:mutex].synchronize { request_count[:value] }
  assert(served_count == 7, "expected exactly 7 selection HTTP rounds, observed #{served_count}")

  puts "PASS: selection proposals require a keyboard selection, disclose only its relative path/range/text, deny outside reads and mixed edit batches, and require manual acceptance; acceptance is one Undo and remains unsaved."
end

fake_server, fake_thread, requests, fixture_errors, releases, request_count, port =
  start_fake_provider(selection_only: !!selection_only)
temp_root = Dir.mktmpdir("adamantine-chat-edit-pty-")
root = File.realpath(temp_root)
project = File.join(root, "project")
state_home = File.join(root, "state")
FileUtils.mkdir_p(project, mode: 0o700)
Dir.mkdir(state_home, 0o700)
source = File.join(project, "main.cr")
private_source = File.join(project, "private.cr")
original_source = selection_only ? "prefix_target_suffix\r\nOUTSIDE_SENTINEL=1\r\n" : "alpha=1\r\nbeta=2\r\n"
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
            rescue PtyScreen::UnsupportedSequence => error
              # Preserve the parser's bounded diagnostic instead of turning a
              # terminal-output incompatibility into the unhelpful value true.
              state[:screen_error] ||= "#{error.class}: #{error.message}"
            end
          end
        end
      rescue EOFError, Errno::EIO
      rescue StandardError => error
        state[:mutex].synchronize do
          state[:screen_error] ||= "#{error.class}: #{error.message}"
        end
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
    opened_text = selection_only ? "prefix_target_suffix" : "alpha=1"
    await("selected source opened") { screen_has?(state, opened_text) }
    assert(Digest::SHA256.file(source).hexdigest == original_digest, "opening source changed disk bytes")

    if selection_only
      run_selection_only_smoke(reader, state, requests, fixture_errors, request_count,
        source, private_source, original_digest, private_digest)
    else
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

    puts "PASS: no-LSP production App exposes only Whole-file proposals read/propose; proposals stay pending until Complete and manual inline acceptance; Escape/revocation do not mutate, Enter creates one Undo, and source files remain unsaved."
    end
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
