require "crystal_tui"
require "json"
require "../../../src/adamantine/app"

# This separately built entrypoint injects only a deterministic local fake at
# the chat transport boundary. It still runs the production App, renderer,
# input router, editor buffer and host-issued EditorTools session.
private class ChatSmokeHandle < Adamantine::Chat::Handle
  @cancelled = false
  @pending = {} of String => Symbol
  @guard_results = 0

  def initialize(@log_path : String,
                 @turn : Int32,
                 @on_event : Proc(Adamantine::Chat::Event, Nil))
  end

  def cancel : Nil
    return if @cancelled
    @cancelled = true
    chat_smoke_log(@log_path, {
      "type" => JSON::Any.new("cancel"),
      "turn" => JSON::Any.new(@turn.to_i64),
    } of String => JSON::Any)
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    stage = @pending.delete(call_id) || raise "fixture received an unknown tool result"
    result = JSON.parse(result_json)
    status = result.as_h["status"].as_s
    chat_smoke_log(@log_path, {
      "type"    => JSON::Any.new("tool_result"),
      "turn"    => JSON::Any.new(@turn.to_i64),
      "call_id" => JSON::Any.new(call_id),
      "status"  => JSON::Any.new(status),
      "result"  => result,
    } of String => JSON::Any)

    case stage
    when :list_buffers
      raise "fixture list_buffers failed: #{result_json}" unless status == "ok"
      buffers = result.as_h["data"].as_h["buffers"].as_a
      buffer = buffers.find { |item| item.as_h["path"].as_s == "main.cr" } ||
               raise "fixture could not find the open main.cr editor buffer"
      read_arguments = {
        "buffer_id"  => JSON::Any.new(buffer.as_h["buffer_id"].as_s),
        "revision"   => JSON::Any.new(buffer.as_h["revision"].as_s),
        "line_count" => JSON::Any.new(16_i64),
      } of String => JSON::Any
      request_tool("read-unsaved", "editor.read_buffer", read_arguments, :read_buffer)
    when :read_buffer
      raise "fixture read_buffer failed: #{result_json}" unless status == "ok"
      lines = result.as_h["data"].as_h["lines"].as_a
      text = lines.map { |line| line.as_h["text"].as_s }.join("\n")
      raise "App-owner ReadEditor did not observe the unsaved marker" unless text.includes?("CHAT_UNSAVED_READ_MARKER")

      request_tool("navigate-guard", "editor.open_file", {
        "path" => JSON::Any.new("main.cr"),
      } of String => JSON::Any, :navigate_guard)
      request_tool("evaluate-guard", "debug.evaluate", {} of String => JSON::Any, :evaluate_guard)
    when :navigate_guard
      raise "fixture navigation capability was not denied" unless status == "denied"
      finish_guard
    when :evaluate_guard
      raise "fixture target evaluation was unexpectedly admitted" unless status == "invalid_request"
      finish_guard
    else
      raise "fixture received an unsupported tool result stage"
    end
  end

  def request_list_buffers : Nil
    request_tool("list-buffers", "editor.list_buffers", {} of String => JSON::Any, :list_buffers)
  end

  private def request_tool(call_id : String, name : String,
                           arguments : Hash(String, JSON::Any), stage : Symbol) : Nil
    @pending[call_id] = stage
    request = {
      "id"        => JSON::Any.new(call_id),
      "name"      => JSON::Any.new(name),
      "arguments" => JSON::Any.new(arguments),
    } of String => JSON::Any
    chat_smoke_log(@log_path, {
      "type"    => JSON::Any.new("tool_request"),
      "turn"    => JSON::Any.new(@turn.to_i64),
      "call_id" => JSON::Any.new(call_id),
      "name"    => JSON::Any.new(name),
    } of String => JSON::Any)
    @on_event.call(Adamantine::Chat::Event.tool_request(call_id, request.to_json))
  end

  private def finish_guard : Nil
    @guard_results += 1
    return unless @guard_results == 2
    @on_event.call(Adamantine::Chat::Event.delta("FIXTURE_READ_UNSAVED_OK"))
  end
end

private class ChatSmokeTransport < Adamantine::Chat::Transport
  @turn = 0
  @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)

  def initialize(@log_path : String)
  end

  def available? : Bool
    true
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    @turn += 1
    handle = ChatSmokeHandle.new(@log_path, @turn, on_event)
    @callbacks << on_event
    chat_smoke_log(@log_path, {
      "type"    => JSON::Any.new("start"),
      "turn"    => JSON::Any.new(@turn.to_i64),
      "request" => JSON::Any.new(request.text),
    } of String => JSON::Any)

    case @turn
    when 1
      handle.request_list_buffers
    when 2
      if old_callback = @callbacks.first?
        chat_smoke_log(@log_path, {
          "type" => JSON::Any.new("emit"),
          "turn" => JSON::Any.new(1_i64),
          "text" => JSON::Any.new("STALE_GENERATION_MARKER"),
        } of String => JSON::Any)
        old_callback.call(Adamantine::Chat::Event.delta("STALE_GENERATION_MARKER"))
      end
      chat_smoke_log(@log_path, {
        "type" => JSON::Any.new("emit"),
        "turn" => JSON::Any.new(2_i64),
        "text" => JSON::Any.new("CURRENT_GENERATION_MARKER"),
      } of String => JSON::Any)
      on_event.call(Adamantine::Chat::Event.delta("CURRENT_GENERATION_MARKER"))
      on_event.call(Adamantine::Chat::Event.complete)
    else
      raise "chat smoke fixture only admits two turns"
    end
    handle
  end
end

private def chat_smoke_log(path : String, record : Hash(String, JSON::Any)) : Nil
  File.open(path, "a") { |file| file.puts(record.to_json) }
end

abort "usage: chat_smoke_app PROJECT_ROOT FIXTURE_LOG" unless ARGV.size == 2
project_root = Path.new(ARGV[0])
log_path = ARGV[1]
transport = ChatSmokeTransport.new(log_path)

Adamantine::App.new(
  project_root: project_root,
  lsp_command: "",
  session_enabled: false,
  recovery_root: project_root / "recovery",
  clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
  chat_transport: transport
).run
