require "spec"
require "json"
require "../src/adamantine/chat_frontend"

private class ChatFrontendSpecHandle < Adamantine::Chat::Handle
  getter cancelled : Bool
  getter tool_results : Array({String, String})

  def initialize
    @cancelled = false
    @tool_results = [] of {String, String}
  end

  def cancel : Nil
    @cancelled = true
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    @tool_results << {call_id, result_json}
  end
end

private class ChatFrontendSpecTransport < Adamantine::Chat::Transport
  getter requests : Array(Adamantine::Chat::Request)
  getter handles : Array(ChatFrontendSpecHandle)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  property available : Bool
  property on_start : Proc(Adamantine::Chat::Request, Proc(Adamantine::Chat::Event, Nil), Nil)?

  def initialize(@available : Bool = true)
    @requests = [] of Adamantine::Chat::Request
    @handles = [] of ChatFrontendSpecHandle
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
  end

  def available? : Bool
    @available
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    @requests << request
    @callbacks << on_event
    @on_start.try(&.call(request, on_event))
    handle = ChatFrontendSpecHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class ChatFrontendExternalSpecTransport < ChatFrontendSpecTransport
  def external? : Bool
    true
  end
end

private class ChatFrontendSpecBackend < Adamantine::EditorTools::Backend
  getter calls : Array(Adamantine::EditorTools::Request)

  def initialize
    @calls = [] of Adamantine::EditorTools::Request
  end

  def context : Adamantine::EditorTools::Context
    Adamantine::EditorTools::Context.new("/project", "chat-spec")
  end

  def execute(request : Adamantine::EditorTools::Request,
              permit : Adamantine::EditorTools::ExecutionPermit) : JSON::Any
    @calls << request
    JSON.parse({"observed" => request.class.name}.to_json)
  end
end

private def chat_tool_call(id : String, name : String, arguments : Hash(String, JSON::Any) = {} of String => JSON::Any) : String
  {"id" => id, "name" => name, "arguments" => arguments}.to_json
end

describe Adamantine::Chat::Frontend do
  it "keeps a draft and does not create a synthetic assistant reply when no transport is connected" do
    transport = ChatFrontendSpecTransport.new(false)
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("inspect this function")

    frontend.submit.should be_false
    frontend.draft.should eq("inspect this function")
    frontend.messages.should be_empty
    frontend.status.should eq("No model connected; draft retained.")
    transport.requests.should be_empty
  end

  it "preserves the transcript and draft when an available transport cannot start" do
    transport = ChatFrontendSpecTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("already accepted")
    frontend.submit.should be_true
    transport.emit(0, Adamantine::Chat::Event.complete)
    frontend.drain.should be_true
    prior_history = frontend.messages.map(&.text)
    prior_history.should eq(["already accepted"])

    transport.on_start = ->(_request : Adamantine::Chat::Request, _emit : Proc(Adamantine::Chat::Event, Nil)) {
      raise "preflight failed"
    }
    frontend.set_draft("first")
    frontend.submit.should be_false
    frontend.messages.map(&.text).should eq(prior_history)
    frontend.draft.should eq("first")
  end

  it "queues synchronous stream callbacks until the owner drains them" do
    transport = ChatFrontendSpecTransport.new
    transport.on_start = ->(_request : Adamantine::Chat::Request, emit : Proc(Adamantine::Chat::Event, Nil)) {
      emit.call(Adamantine::Chat::Event.delta("hello "))
      emit.call(Adamantine::Chat::Event.delta("world"))
      emit.call(Adamantine::Chat::Event.complete)
    }
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("say hello")

    frontend.submit.should be_true
    frontend.messages.map(&.text).should eq(["say hello"])
    frontend.drain

    frontend.messages.map(&.text).should eq(["say hello", "hello world"])
    frontend.state.should eq(Adamantine::Chat::TurnState::Complete)
  end

  it "cancels a handle returned after synchronous reentrant cancellation" do
    transport = ChatFrontendSpecTransport.new
    frontend : Adamantine::Chat::Frontend? = nil
    transport.on_start = ->(_request : Adamantine::Chat::Request, emit : Proc(Adamantine::Chat::Event, Nil)) {
      emit.call(Adamantine::Chat::Event.delta("must not publish"))
      frontend.not_nil!.cancel
    }
    active = Adamantine::Chat::Frontend.new(transport)
    frontend = active
    active.set_draft("first")

    active.submit.should be_true
    transport.handles.first.cancelled.should be_true
    active.drain
    active.messages.map(&.text).should eq(["first"])
    active.state.should eq(Adamantine::Chat::TurnState::Cancelled)
  end

  it "fences callbacks from a cancelled turn after a new turn starts" do
    transport = ChatFrontendSpecTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("old")
    frontend.submit.should be_true
    frontend.cancel.should be_true
    frontend.set_draft("new")
    frontend.submit.should be_true

    transport.emit(0, Adamantine::Chat::Event.delta("stale"))
    transport.emit(1, Adamantine::Chat::Event.delta("current"))
    transport.emit(1, Adamantine::Chat::Event.complete)
    frontend.drain

    frontend.messages.map(&.text).should eq(["old", "new", "current"])
    transport.handles.first.cancelled.should be_true
    frontend.state.should eq(Adamantine::Chat::TurnState::Complete)
  end

  it "rejects an oversized draft without replacing the previous draft" do
    frontend = Adamantine::Chat::Frontend.new
    frontend.set_draft("kept")

    frontend.set_draft("x" * (Adamantine::Chat::MAX_DRAFT_BYTES + 1)).should be_false
    frontend.draft.should eq("kept")
  end

  it "explains the export-history ceiling with an actionable new-conversation hint" do
    transport = ChatFrontendExternalSpecTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    9.times do |index|
      frontend.set_draft("question #{index}")
      frontend.submit.should be_true
      transport.emit(index, Adamantine::Chat::Event.delta("answer #{index}"))
      transport.emit(index, Adamantine::Chat::Event.complete)
      frontend.drain
    end

    frontend.messages.size.should eq(18)
    frontend.set_draft("next prompt").should be_true
    frontend.draft.should eq("next prompt")
    frontend.review_unavailable_reason
      .should eq("Visible history exceeds 16 messages or 64 KiB; start a new conversation.")
    frontend.review_request.should be_nil
  end

  it "makes callback queue overflow visible and cancels rather than silently dropping events" do
    transport = ChatFrontendSpecTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("bounded")
    frontend.submit.should be_true

    (Adamantine::Chat::MAX_PENDING_EVENTS + 1).times do |index|
      transport.emit(0, Adamantine::Chat::Event.delta(index.to_s))
    end
    frontend.drain

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should contain("queue limit")
    transport.handles.first.cancelled.should be_true
  end

  it "dispatches tool requests through the owned capability session on owner drain" do
    transport = ChatFrontendSpecTransport.new
    backend = ChatFrontendSpecBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    session_factory = -> : Adamantine::EditorTools::Session {
      host.open_session(
        Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor]
      )
    }
    frontend = Adamantine::Chat::Frontend.new(transport, session_factory)
    frontend.set_draft("read only")
    frontend.submit.should be_true

    transport.emit(0, Adamantine::Chat::Event.tool_request("allowed", chat_tool_call("allowed", "editor.list_buffers")))
    denied_arguments = {"path" => JSON::Any.new("denied.cr")} of String => JSON::Any
    transport.emit(0, Adamantine::Chat::Event.tool_request("denied", chat_tool_call("denied", "editor.open_file", denied_arguments)))
    frontend.drain

    backend.calls.size.should eq(1)
    results = transport.handles.first.tool_results.map { |entry| JSON.parse(entry[1]) }
    results.map { |result| result["status"].as_s }.should eq(["ok", "denied"])
  end

  it "ends a turn on the exact sealed tool-session quota result and ignores later callbacks" do
    transport = ChatFrontendSpecTransport.new
    backend = ChatFrontendSpecBackend.new
    host = Adamantine::EditorTools::Host.new(backend, Adamantine::EditorTools::Limits.new(max_calls: 1))
    session_factory = -> : Adamantine::EditorTools::Session {
      host.open_session(
        Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor]
      )
    }
    frontend = Adamantine::Chat::Frontend.new(transport, session_factory)
    frontend.set_draft("stay within quota")
    frontend.submit.should be_true

    transport.emit(0, Adamantine::Chat::Event.tool_request("first", chat_tool_call("first", "editor.list_buffers")))
    transport.emit(0, Adamantine::Chat::Event.tool_request("terminal", chat_tool_call("terminal", "editor.list_buffers")))
    transport.emit(0, Adamantine::Chat::Event.delta("must not publish after terminal quota"))
    frontend.drain

    results = transport.handles.first.tool_results.map { |entry| JSON.parse(entry[1]) }
    results.map { |result| result["status"].as_s }.should eq(["ok", "limit_exceeded"])
    results.last["message"].as_s.should eq("session response budget exhausted")
    backend.calls.size.should eq(1)
    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should contain("budget exhausted")
    transport.handles.first.cancelled.should be_true
    frontend.messages.map(&.text).should eq(["stay within quota"])
  end
end
