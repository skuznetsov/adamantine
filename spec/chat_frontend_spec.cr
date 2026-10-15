require "spec"
require "json"
require "../src/adamantine/chat_frontend"

private class ChatFrontendSpecHandle < Adamantine::Chat::Handle
  getter cancelled : Bool
  getter tool_results : Array({String, String})
  property fail_delivery : Bool

  def initialize
    @cancelled = false
    @tool_results = [] of {String, String}
    @fail_delivery = false
  end

  def cancel : Nil
    @cancelled = true
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    raise "fixture delivery failure" if @fail_delivery
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
  it "opens editor tools only for the explicitly granted selection-proposal mode" do
    range = Adamantine::Chat::SourceRange.new(1, 1, 1, 4)
    selection = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::Selection,
      "Selection · src/main.cr",
      "ell",
      "buf-1",
      "rev-1",
      source_path: "src/main.cr",
      source_range: range
    )
    selection_proposals = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::SelectionProposals,
      "Selection proposals · src/main.cr",
      "ell",
      "buf-1",
      "rev-1",
      source_path: "src/main.cr",
      source_range: range
    )

    readonly_transport = ChatFrontendExternalSpecTransport.new
    readonly_factory_calls = 0
    readonly_factory : Adamantine::Chat::Frontend::ContextSessionFactory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      readonly_factory_calls += 1
      Adamantine::EditorTools::Host.new(ChatFrontendSpecBackend.new).open_session(
        Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor]
      )
    }
    readonly_frontend = Adamantine::Chat::Frontend.new(readonly_transport,
      context_session_factory: readonly_factory)
    readonly_frontend.set_draft("explain the selection")
    readonly_frontend.submit(selection).should be_true
    readonly_factory_calls.should eq(0)
    readonly_frontend.cancel.should be_true

    proposal_transport = ChatFrontendExternalSpecTransport.new
    proposal_factory_calls = 0
    proposal_factory : Adamantine::Chat::Frontend::ContextSessionFactory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      proposal_factory_calls += 1
      Adamantine::EditorTools::Host.new(ChatFrontendSpecBackend.new).open_session(
        Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor, Adamantine::EditorTools::Capability::ProposeEdits]
      )
    }
    proposal_frontend = Adamantine::Chat::Frontend.new(proposal_transport,
      context_session_factory: proposal_factory)
    proposal_frontend.set_draft("rewrite just the selection")
    proposal_frontend.submit(selection_proposals).should be_true
    proposal_factory_calls.should eq(1)
    proposal_transport.requests.first.context.source_path.should eq("src/main.cr")
    proposal_transport.requests.first.context.source_range.should eq(range)
  end

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

  it "exposes context-session construction only for the matching synchronous factory call" do
    transport = ChatFrontendExternalSpecTransport.new
    backend = ChatFrontendSpecBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools, "Selected buffer", "", "buf-1", "rev-1",
      source_path: "src/main.cr"
    )
    other_context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools, "Other buffer", "", "other-buffer", "rev-2",
      source_path: "src/other.cr"
    )
    frontend = nil.as(Adamantine::Chat::Frontend?)
    observations = [] of Bool
    session_factory = ->(factory_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      owner = frontend.not_nil!
      observations << owner.constructing_context_session?(factory_context)
      observations << owner.constructing_context_session?(other_context)
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor])
    }
    frontend = Adamantine::Chat::Frontend.new(transport,
      context_session_factory: session_factory)
    frontend.not_nil!.set_draft("inspect selected buffer")

    frontend.not_nil!.submit(context).should be_true
    observations.should eq([true, false])
    frontend.not_nil!.constructing_context_session?(context).should be_false
    frontend.not_nil!.active?.should be_true
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

  it "fails and retires an unfinished deferred tool before accepting provider Complete" do
    transport = ChatFrontendExternalSpecTransport.new
    backend = ChatFrontendSpecBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    session_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::RunScript, Adamantine::EditorTools::Capability::ReadEditor])
    }
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools, "Selected buffer", "", "buf-1", "rev-1",
      Adamantine::Chat::LuaScriptGrant.new("script-1", "Reviewed script", "a" * 64,
        [Adamantine::EditorTools::Capability::ReadEditor]),
      source_path: "src/main.cr"
    )
    frontend = Adamantine::Chat::Frontend.new(transport,
      context_session_factory: session_factory)
    retired = [] of Adamantine::EditorTools::DeferredCall
    captured = nil.as(Adamantine::EditorTools::DeferredCall?)
    frontend.deferred_tool_handler = ->(ticket : Adamantine::EditorTools::DeferredCall, _context : Adamantine::Chat::SubmissionContext) { captured = ticket; nil }
    frontend.deferred_tool_retirement = ->(ticket : Adamantine::EditorTools::DeferredCall) { retired << ticket; nil }
    frontend.set_draft("run the reviewed script")
    frontend.submit(context).should be_true

    transport.emit(0, Adamantine::Chat::Event.tool_request("outer-1",
      chat_tool_call("outer-1", "lua.run_script", {"script_id" => JSON::Any.new("script-1")})))
    frontend.drain
    frontend.active?.should be_true
    retired.should be_empty

    transport.emit(0, Adamantine::Chat::Event.complete)
    frontend.drain

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should contain("deferred tool was still running")
    transport.handles.first.cancelled.should be_true
    retired.size.should eq(1)
    retired.first.active?.should be_false
    backend.calls.should be_empty
  end

  it "cancels only the active generation owning a stale deferred ticket" do
    transport = ChatFrontendExternalSpecTransport.new
    host = Adamantine::EditorTools::Host.new(ChatFrontendSpecBackend.new)
    session_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::RunScript, Adamantine::EditorTools::Capability::ReadEditor])
    }
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools, "Selected buffer", "", "buf-1", "rev-1",
      Adamantine::Chat::LuaScriptGrant.new("script-1", "Reviewed script", "a" * 64,
        [Adamantine::EditorTools::Capability::ReadEditor]),
      source_path: "src/main.cr"
    )
    frontend = Adamantine::Chat::Frontend.new(transport,
      context_session_factory: session_factory)
    captured = nil.as(Adamantine::EditorTools::DeferredCall?)
    frontend.deferred_tool_handler = ->(ticket : Adamantine::EditorTools::DeferredCall, _context : Adamantine::Chat::SubmissionContext) { captured = ticket; nil }
    frontend.set_draft("run the reviewed script")
    frontend.submit(context).should be_true
    transport.emit(0, Adamantine::Chat::Event.tool_request("outer-1",
      chat_tool_call("outer-1", "lua.run_script", {"script_id" => JSON::Any.new("script-1")})))
    frontend.drain

    ticket = captured
    ticket.should_not be_nil
    child = ticket.not_nil!.child_session([Adamantine::EditorTools::Capability::ReadEditor])
    ticket.not_nil!.revoke # Simulate the host revoking root authority on stale context.
    child.closed?.should be_true
    frontend.cancel_deferred_turn(ticket.not_nil!).should be_true
    frontend.active?.should be_false
    transport.handles.first.cancelled.should be_true

    frontend.set_draft("new turn")
    frontend.submit(context).should be_true
    frontend.active?.should be_true
    frontend.cancel_deferred_turn(ticket.not_nil!).should be_false
    frontend.active?.should be_true
    transport.handles.last.cancelled.should be_false
    frontend.cancel.should be_true
  end

  it "rejects deferred buffer guards from a retired ticket without spending the current proposal attempt" do
    transport = ChatFrontendExternalSpecTransport.new
    backend = ChatFrontendSpecBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    session_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat, [
        Adamantine::EditorTools::Capability::RunScript,
        Adamantine::EditorTools::Capability::ReadEditor,
        Adamantine::EditorTools::Capability::ProposeEdits,
      ])
    }
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::SelectionProposals,
      "Selection proposals · src/main.cr",
      "abcd",
      "buf-1",
      "rev-1",
      Adamantine::Chat::LuaScriptGrant.new("script-1", "Reviewed script", "a" * 64, [
        Adamantine::EditorTools::Capability::ReadEditor,
        Adamantine::EditorTools::Capability::ProposeEdits,
      ]),
      source_path: "src/main.cr",
      source_range: Adamantine::Chat::SourceRange.new(1, 0, 1, 4)
    )
    frontend = Adamantine::Chat::Frontend.new(transport,
      context_session_factory: session_factory)
    tickets = [] of Adamantine::EditorTools::DeferredCall
    frontend.deferred_tool_handler = ->(ticket : Adamantine::EditorTools::DeferredCall, _context : Adamantine::Chat::SubmissionContext) {
      tickets << ticket
      nil
    }
    frontend.set_draft("first turn")
    frontend.submit(context).should be_true
    old_request = chat_tool_call("outer-reused", "lua.run_script",
      {"script_id" => JSON::Any.new("script-1")})
    transport.emit(0, Adamantine::Chat::Event.tool_request("outer-reused", old_request))
    frontend.drain
    tickets.size.should eq(1)
    retired_ticket = tickets.first

    frontend.cancel.should be_true
    retired_ticket.active?.should be_false

    frontend.set_draft("second turn")
    frontend.submit(context).should be_true
    current_request = chat_tool_call("outer-reused", "lua.run_script",
      {"script_id" => JSON::Any.new("script-1")})
    transport.emit(1, Adamantine::Chat::Event.tool_request("outer-reused", current_request))
    frontend.drain
    tickets.size.should eq(2)
    current_ticket = tickets.last
    current_ticket.active?.should be_true

    proposal = Adamantine::EditorTools::ProposeEditsRequest.new("buf-1", "rev-1", [
      Adamantine::EditorTools::ProposeEdit.new(1, 1, 1, 2, "X"),
    ])
    stale = expect_raises(Adamantine::EditorTools::Failure) do
      frontend.guard_deferred_buffer_request!(retired_ticket, proposal)
    end
    stale.status.should eq(Adamantine::EditorTools::Status::Stale)

    # A rejected old ticket must not consume the new generation's one proposal.
    frontend.guard_deferred_buffer_request!(current_ticket, proposal)
    duplicate = expect_raises(Adamantine::EditorTools::Failure) do
      frontend.guard_deferred_buffer_request!(current_ticket, proposal)
    end
    duplicate.status.should eq(Adamantine::EditorTools::Status::Denied)
    duplicate.message.should eq("only one proposal is allowed per turn")

    direct_arguments = {
      "buffer_id" => JSON::Any.new("buf-1"),
      "revision"  => JSON::Any.new("rev-1"),
      "edits"     => JSON.parse(%([{"start_line":1,"start_column":1,"end_line":1,"end_column":2,"new_text":"Y"}])),
    } of String => JSON::Any
    direct_call = chat_tool_call("direct-after-child-guard", "editor.propose_edits", direct_arguments)
    transport.emit(1, Adamantine::Chat::Event.tool_request("direct-after-child-guard", direct_call))
    frontend.drain
    direct_result = JSON.parse(transport.handles.last.tool_results.last[1])
    direct_result["status"].as_s.should eq("denied")
    direct_result["message"].as_s.should eq("only one proposal is allowed per turn")
    backend.calls.should be_empty
    frontend.active?.should be_true
    frontend.cancel.should be_true
  end

  it "retires a ticket and closes the generation if deferred startup throws" do
    transport = ChatFrontendExternalSpecTransport.new
    host = Adamantine::EditorTools::Host.new(ChatFrontendSpecBackend.new)
    session_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::RunScript, Adamantine::EditorTools::Capability::ReadEditor])
    }
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools, "Selected buffer", "", "buf-1", "rev-1",
      Adamantine::Chat::LuaScriptGrant.new("script-1", "Reviewed script", "a" * 64,
        [Adamantine::EditorTools::Capability::ReadEditor]),
      source_path: "src/main.cr"
    )
    frontend = Adamantine::Chat::Frontend.new(transport,
      context_session_factory: session_factory)
    retired = [] of Adamantine::EditorTools::DeferredCall
    frontend.deferred_tool_handler = ->(_ticket : Adamantine::EditorTools::DeferredCall, _context : Adamantine::Chat::SubmissionContext) {
      raise "runner startup failed"
    }
    frontend.deferred_tool_retirement = ->(ticket : Adamantine::EditorTools::DeferredCall) { retired << ticket; nil }
    frontend.set_draft("run the reviewed script")
    frontend.submit(context).should be_true

    transport.emit(0, Adamantine::Chat::Event.tool_request("outer-1",
      chat_tool_call("outer-1", "lua.run_script", {"script_id" => JSON::Any.new("script-1")})))
    frontend.drain

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.active?.should be_false
    transport.handles.first.cancelled.should be_true
    retired.size.should eq(1)
    retired.first.active?.should be_false
  end

  it "fails and retires when deferred tool-result delivery raises" do
    transport = ChatFrontendExternalSpecTransport.new
    host = Adamantine::EditorTools::Host.new(ChatFrontendSpecBackend.new)
    session_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::RunScript, Adamantine::EditorTools::Capability::ReadEditor])
    }
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools, "Selected buffer", "", "buf-1", "rev-1",
      Adamantine::Chat::LuaScriptGrant.new("script-1", "Reviewed script", "a" * 64,
        [Adamantine::EditorTools::Capability::ReadEditor]),
      source_path: "src/main.cr"
    )
    frontend = Adamantine::Chat::Frontend.new(transport,
      context_session_factory: session_factory)
    retired = [] of Adamantine::EditorTools::DeferredCall
    captured = nil.as(Adamantine::EditorTools::DeferredCall?)
    frontend.deferred_tool_handler = ->(_ticket : Adamantine::EditorTools::DeferredCall, _context : Adamantine::Chat::SubmissionContext) { captured = _ticket; nil }
    frontend.deferred_tool_retirement = ->(ticket : Adamantine::EditorTools::DeferredCall) { retired << ticket; nil }
    frontend.set_draft("run the reviewed script")
    frontend.submit(context).should be_true
    transport.emit(0, Adamantine::Chat::Event.tool_request("outer-1",
      chat_tool_call("outer-1", "lua.run_script", {"script_id" => JSON::Any.new("script-1")})))
    frontend.drain
    ticket = retired.first? # no retirement before completion
    ticket.should be_nil

    transport.handles.first.fail_delivery = true
    pending = captured
    pending.should_not be_nil
    accepted = frontend.complete_deferred_tool(pending.not_nil!, JSON.parse({"stdout" => "result"}.to_json))

    accepted.should be_true
    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.active?.should be_false
    transport.handles.first.cancelled.should be_true
    retired.size.should eq(1)
    retired.first.same?(pending.not_nil!).should be_true
  end

  it "returns the deferred outer result status separately from ticket acceptance" do
    transport = ChatFrontendExternalSpecTransport.new
    host = Adamantine::EditorTools::Host.new(ChatFrontendSpecBackend.new)
    session_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::RunScript, Adamantine::EditorTools::Capability::ReadEditor])
    }
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools, "Selected buffer", "", "buf-1", "rev-1",
      Adamantine::Chat::LuaScriptGrant.new("script-1", "Reviewed script", "a" * 64,
        [Adamantine::EditorTools::Capability::ReadEditor]),
      source_path: "src/main.cr"
    )
    frontend = Adamantine::Chat::Frontend.new(transport,
      context_session_factory: session_factory)
    captured = nil.as(Adamantine::EditorTools::DeferredCall?)
    frontend.deferred_tool_handler = ->(ticket : Adamantine::EditorTools::DeferredCall, _context : Adamantine::Chat::SubmissionContext) { captured = ticket; nil }
    frontend.set_draft("run the reviewed script")
    frontend.submit(context).should be_true
    transport.emit(0, Adamantine::Chat::Event.tool_request("outer-1",
      chat_tool_call("outer-1", "lua.run_script", {"script_id" => JSON::Any.new("script-1")})))
    frontend.drain

    ticket = captured
    ticket.should_not be_nil
    oversized = JSON.parse({"stdout" => "x" * Adamantine::EditorTools::MAX_SAFE_DATA_BYTES}.to_json)
    result = frontend.complete_deferred_tool_result(ticket.not_nil!, oversized)

    result.should_not be_nil
    result.not_nil!.status.should eq(Adamantine::EditorTools::Status::LimitExceeded)
    result.not_nil!.ok?.should be_false
    delivered = JSON.parse(transport.handles.first.tool_results.last[1])
    delivered["status"].as_s.should eq("limit_exceeded")
    frontend.active?.should be_true
  end
end
