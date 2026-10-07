require "spec"
require "json"
require "../src/adamantine/chat_frontend"

private class ChatLifetimeAdversaryHandle < Adamantine::Chat::Handle
  getter cancelled : Bool
  getter tool_results : Array({String, String})
  @fail_delivery : Bool
  @on_cancel : Proc(Nil)?

  def initialize(@fail_delivery : Bool = false, @on_cancel : Proc(Nil)? = nil)
    @cancelled = false
    @tool_results = [] of {String, String}
  end

  def cancel : Nil
    @cancelled = true
    @on_cancel.try(&.call)
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    raise "fixture delivery failure" if @fail_delivery
    @tool_results << {call_id, result_json}
  end
end

private class ChatLifetimeAdversaryTransport < Adamantine::Chat::Transport
  getter requests : Array(Adamantine::Chat::Request)
  getter handles : Array(ChatLifetimeAdversaryHandle)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  property on_start : Proc(Adamantine::Chat::Request, Proc(Adamantine::Chat::Event, Nil), Nil)?
  property on_cancel : Proc(Nil)?
  property fail_start : Bool
  property fail_delivery : Bool

  def initialize(@fail_start : Bool = false, @fail_delivery : Bool = false)
    @requests = [] of Adamantine::Chat::Request
    @handles = [] of ChatLifetimeAdversaryHandle
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
  end

  def available? : Bool
    true
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    raise "fixture start failure" if @fail_start

    handle = ChatLifetimeAdversaryHandle.new(@fail_delivery, @on_cancel)
    @requests << request
    @callbacks << on_event
    @handles << handle
    @on_start.try(&.call(request, on_event))
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class ChatLifetimeAdversaryBackend < Adamantine::EditorTools::Backend
  getter calls : Array(Adamantine::EditorTools::Request)
  property on_execute : Proc(Nil)?

  def initialize
    @calls = [] of Adamantine::EditorTools::Request
  end

  def context : Adamantine::EditorTools::Context
    Adamantine::EditorTools::Context.new("/project", "chat-lifetime-adversary")
  end

  def execute(request : Adamantine::EditorTools::Request,
              permit : Adamantine::EditorTools::ExecutionPermit) : JSON::Any
    @calls << request
    @on_execute.try(&.call)
    JSON.parse({"observed" => request.class.name}.to_json)
  end
end

private def chat_lifetime_adversary_tool_call(id : String, name : String) : String
  {"id" => id, "name" => name, "arguments" => {} of String => String}.to_json
end

private def chat_lifetime_adversary_session_factory(
  host : Adamantine::EditorTools::Host,
  sessions : Array(Adamantine::EditorTools::Session),
) : Proc(Adamantine::EditorTools::Session)
  -> : Adamantine::EditorTools::Session {
    session = host.open_session(
      Adamantine::EditorTools::Consumer::Chat,
      [Adamantine::EditorTools::Capability::ReadEditor]
    )
    sessions << session
    session
  }
end

describe "chat frontend lifetime and resource adversaries" do
  it "bounds pending callback bytes independently of event count" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("byte bounded")
    frontend.submit.should be_true

    chunk = "é" * 4096
    event_count = (Adamantine::Chat::MAX_PENDING_BYTES // chunk.bytesize) + 1
    event_count.times do
      transport.emit(0, Adamantine::Chat::Event.delta(chunk))
    end
    transport.callbacks.size.should be < Adamantine::Chat::MAX_PENDING_EVENTS
    frontend.drain

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should eq("Chat callback queue limit reached; request cancelled.")
    transport.handles.first.cancelled.should be_true
  end

  it "truncates multibyte assistant output at a valid UTF-8 message boundary" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("inspect")
    frontend.submit.should be_true
    transport.emit(0, Adamantine::Chat::Event.delta("界" * ((Adamantine::Chat::MAX_MESSAGE_BYTES // 3) + 1)))
    transport.emit(0, Adamantine::Chat::Event.complete)
    frontend.drain

    assistant = frontend.messages.last.text
    assistant.bytesize.should be <= Adamantine::Chat::MAX_MESSAGE_BYTES
    assistant.valid_encoding?.should be_true
    assistant.each_char.any? { |char| char == '�' }.should be_false
    frontend.status.should contain("Message truncated at 64 KiB.")
  end

  it "keeps transcript bytes bounded and reports eviction after multibyte overflow" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    user_text = "é" * (Adamantine::Chat::MAX_DRAFT_BYTES // 2)
    assistant_text = "🙂" * (Adamantine::Chat::MAX_MESSAGE_BYTES // 4)

    4.times do |index|
      frontend.set_draft(user_text).should be_true
      frontend.submit.should be_true
      transport.emit(index, Adamantine::Chat::Event.delta(assistant_text))
      transport.emit(index, Adamantine::Chat::Event.complete)
      frontend.drain
    end

    frontend.messages.map { |message| message.text.bytesize }.sum.should be <= Adamantine::Chat::MAX_TRANSCRIPT_BYTES
    frontend.messages.size.should be <= Adamantine::Chat::MAX_MESSAGES
    frontend.messages.each { |message| message.text.valid_encoding?.should be_true }
    frontend.status.should contain("Older chat messages removed to stay within transcript limit.")
  end

  it "keeps the retained message count bounded even for tiny messages" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)

    (Adamantine::Chat::MAX_MESSAGES // 2 + 1).times do |index|
      frontend.set_draft("u").should be_true
      frontend.submit.should be_true
      transport.emit(index, Adamantine::Chat::Event.delta("a"))
      transport.emit(index, Adamantine::Chat::Event.complete)
      frontend.drain
    end

    frontend.messages.size.should be <= Adamantine::Chat::MAX_MESSAGES
    frontend.status.should contain("Older chat messages removed to stay within transcript limit.")
  end

  it "invalidates captured paste targets when a turn starts and completes, even if text is reused" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("same composer text").should be_true

    before_start = frontend.lifetime_revision
    frontend.submit.should be_true
    after_start = frontend.lifetime_revision
    after_start.should be > before_start

    # Model a delayed clipboard target whose text is unchanged while the turn
    # advances. The lifetime token must still fence it independently of text.
    frontend.set_draft("same composer text").should be_true
    frontend.draft.should eq("same composer text")
    transport.emit(0, Adamantine::Chat::Event.complete)
    frontend.drain

    frontend.draft.should eq("same composer text")
    frontend.lifetime_revision.should be > after_start
  end

  it "advances lifetime revision for idle conversation, root, and shutdown boundaries" do
    frontend = Adamantine::Chat::Frontend.new(ChatLifetimeAdversaryTransport.new)
    initial = frontend.lifetime_revision

    frontend.new_conversation
    after_new_conversation = frontend.lifetime_revision
    after_new_conversation.should be > initial
    frontend.active?.should be_false

    frontend.retire_context
    after_idle_retirement = frontend.lifetime_revision
    after_idle_retirement.should be > after_new_conversation

    frontend.shutdown
    frontend.lifetime_revision.should be > after_idle_retirement
    frontend.available?.should be_false
  end

  it "keeps an explicit truncation notice when a later failure terminates the turn" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("truncate then fail").should be_true
    frontend.submit.should be_true
    transport.emit(0, Adamantine::Chat::Event.delta("x" * (Adamantine::Chat::MAX_MESSAGE_BYTES + 1)))
    transport.emit(0, Adamantine::Chat::Event.failure("model failed after partial output"))

    frontend.drain

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should contain("model failed after partial output")
    frontend.status.should contain("Message truncated at 64 KiB.")
  end

  it "keeps an explicit eviction notice when a turn is cancelled" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)

    (Adamantine::Chat::MAX_MESSAGES // 2).times do |index|
      frontend.set_draft("u#{index}").should be_true
      frontend.submit.should be_true
      transport.emit(index, Adamantine::Chat::Event.delta("a"))
      transport.emit(index, Adamantine::Chat::Event.complete)
      frontend.drain
    end

    frontend.set_draft("cancel after eviction").should be_true
    frontend.submit.should be_true
    frontend.messages.size.should eq(Adamantine::Chat::MAX_MESSAGES)
    frontend.cancel.should be_true

    frontend.state.should eq(Adamantine::Chat::TurnState::Cancelled)
    frontend.status.should contain("Request cancelled.")
    frontend.status.should contain("Older chat messages removed to stay within transcript limit.")
  end

  it "normalizes line endings and strips terminal controls from streamed text" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("line1\r\nline2\rline3").should be_true
    frontend.draft.should eq("line1\nline2\nline3")
    frontend.set_draft("sanitize")
    frontend.submit.should be_true
    transport.emit(0, Adamantine::Chat::Event.delta("A\u001b[2JB\u0000C\u007fD\r\nE\rF\tG"))
    transport.emit(0, Adamantine::Chat::Event.complete)
    frontend.drain

    assistant = frontend.messages.last.text
    assistant.should eq("A[2JBCD\nEF\tG")
    assistant.each_char do |char|
      codepoint = char.ord
      (codepoint >= 0x20 || char == '\n' || char == '\t').should be_true
    end
  end

  it "fails closed on invalid UTF-8 callback data" do
    transport = ChatLifetimeAdversaryTransport.new
    frontend = Adamantine::Chat::Frontend.new(transport)
    frontend.set_draft("safe user text")
    frontend.submit.should be_true
    invalid = String.new(Bytes[0xff_u8])
    transport.emit(0, Adamantine::Chat::Event.delta(invalid))
    frontend.drain

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should eq("Chat event contained invalid UTF-8.")
    frontend.messages.each { |message| message.text.valid_encoding?.should be_true }
    transport.handles.first.cancelled.should be_true
  end

  it "fences queued and late tool requests across reentrant cancel and new submit" do
    transport = ChatLifetimeAdversaryTransport.new
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    session_factory = chat_lifetime_adversary_session_factory(host, sessions)
    frontend : Adamantine::Chat::Frontend? = nil
    transport.on_start = ->(_request : Adamantine::Chat::Request, emit : Proc(Adamantine::Chat::Event, Nil)) {
      if transport.requests.size == 1
        emit.call(Adamantine::Chat::Event.tool_request("queued-old", chat_lifetime_adversary_tool_call("queued-old", "editor.list_buffers")))
        active = frontend.not_nil!
        active.cancel.should be_true
        active.set_draft("new turn")
        active.submit.should be_true
      end
    }
    active = Adamantine::Chat::Frontend.new(transport, session_factory)
    frontend = active
    active.set_draft("old turn")
    active.submit.should be_true

    transport.handles.size.should eq(2)
    transport.emit(0, Adamantine::Chat::Event.tool_request("late-old", chat_lifetime_adversary_tool_call("late-old", "editor.list_buffers")))
    transport.emit(0, Adamantine::Chat::Event.delta("stale output"))
    transport.emit(1, Adamantine::Chat::Event.delta("current output"))
    transport.emit(1, Adamantine::Chat::Event.complete)
    active.drain

    transport.handles.first.cancelled.should be_true
    transport.handles.last.cancelled.should be_false
    sessions.first.closed?.should be_true
    backend.calls.should be_empty
    transport.handles.each { |handle| handle.tool_results.should be_empty }
    active.messages.map(&.text).should eq(["old turn", "new turn", "current output"])
    active.state.should eq(Adamantine::Chat::TurnState::Complete)
  end

  it "does not let a reentrant cancel teardown close or overwrite a newer turn" do
    transport = ChatLifetimeAdversaryTransport.new
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    session_factory = chat_lifetime_adversary_session_factory(host, sessions)
    frontend : Adamantine::Chat::Frontend? = nil
    revision_before_cancel = 0_u64
    revision_seen_in_cancel = 0_u64
    transport.on_cancel = -> {
      if transport.handles.size == 1
        active = frontend.not_nil!
        revision_seen_in_cancel = active.lifetime_revision
        active.set_draft("reentrant turn").should be_true
        active.submit.should be_true
      end
    }
    active = Adamantine::Chat::Frontend.new(transport, session_factory)
    frontend = active
    active.set_draft("cancel me").should be_true
    active.submit.should be_true
    revision_before_cancel = active.lifetime_revision

    active.cancel.should be_true
    revision_seen_in_cancel.should be > revision_before_cancel

    transport.handles.size.should eq(2)
    {
      transport.handles.size == 2,
      transport.handles.first.cancelled,
      transport.handles.last.cancelled,
      sessions.size == 2,
      sessions.first.closed?,
      sessions.last.closed?,
      active.active?,
      active.state == Adamantine::Chat::TurnState::Generating,
    }.should eq({true, true, false, true, true, false, true, true})

    transport.emit(1, Adamantine::Chat::Event.delta("surviving output"))
    transport.emit(1, Adamantine::Chat::Event.complete)
    active.drain
    active.messages.map(&.text).should eq(["cancel me", "reentrant turn", "surviving output"])
    active.state.should eq(Adamantine::Chat::TurnState::Complete)
  end

  it "does not deliver a tool result after the backend retires its generation" do
    transport = ChatLifetimeAdversaryTransport.new
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    frontend : Adamantine::Chat::Frontend? = nil
    active = Adamantine::Chat::Frontend.new(
      transport,
      chat_lifetime_adversary_session_factory(host, sessions)
    )
    frontend = active
    backend.on_execute = -> { frontend.not_nil!.retire_context }
    active.set_draft("retire from backend").should be_true
    active.submit.should be_true
    transport.emit(0, Adamantine::Chat::Event.tool_request("revoked", chat_lifetime_adversary_tool_call("revoked", "editor.list_buffers")))

    active.drain

    {
      backend.calls.size == 1,
      active.state == Adamantine::Chat::TurnState::Cancelled,
      transport.handles.first.cancelled,
      sessions.first.closed?,
      transport.handles.first.tool_results.empty?,
    }.should eq({true, true, true, true, true})
  end

  it "closes a session issued after its factory reentrantly shuts down the frontend" do
    transport = ChatLifetimeAdversaryTransport.new
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    frontend : Adamantine::Chat::Frontend? = nil
    session_factory = -> : Adamantine::EditorTools::Session {
      session = host.open_session(
        Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor]
      )
      sessions << session
      frontend.not_nil!.shutdown
      session
    }
    active = Adamantine::Chat::Frontend.new(transport, session_factory)
    frontend = active
    active.set_draft("factory shutdown").should be_true

    active.submit

    {
      transport.handles.empty?,
      sessions.size == 1,
      sessions.first.closed?,
      !active.active?,
      active.state != Adamantine::Chat::TurnState::Generating,
    }.should eq({true, true, true, true, true})
  end

  it "does not permit a cancel hook to start work during shutdown" do
    transport = ChatLifetimeAdversaryTransport.new
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    frontend : Adamantine::Chat::Frontend? = nil
    transport.on_cancel = -> {
      if transport.handles.size == 1
        active = frontend.not_nil!
        active.set_draft("submit during shutdown").should be_true
        active.submit
      end
    }
    active = Adamantine::Chat::Frontend.new(
      transport,
      chat_lifetime_adversary_session_factory(host, sessions)
    )
    frontend = active
    active.set_draft("shutdown me").should be_true
    active.submit.should be_true

    active.shutdown

    {
      transport.handles.size == 1,
      transport.handles.first.cancelled,
      sessions.size == 1,
      sessions.first.closed?,
      !active.active?,
      !active.available?,
      active.state != Adamantine::Chat::TurnState::Generating,
    }.should eq({true, true, true, true, true, true, true})
  end

  it "keeps new-conversation cancellation reentrancy coherent" do
    transport = ChatLifetimeAdversaryTransport.new
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    frontend : Adamantine::Chat::Frontend? = nil
    transport.on_cancel = -> {
      if transport.handles.size == 1
        active = frontend.not_nil!
        active.set_draft("new conversation turn").should be_true
        active.submit
      end
    }
    active = Adamantine::Chat::Frontend.new(
      transport,
      chat_lifetime_adversary_session_factory(host, sessions)
    )
    frontend = active
    active.set_draft("old conversation").should be_true
    active.submit.should be_true

    active.new_conversation

    old_generation_retired = transport.handles.first.cancelled && sessions.first.closed?
    reset_rejected_reentrant_submit =
      transport.handles.size == 1 && sessions.size == 1 && old_generation_retired &&
        !active.active? && active.state == Adamantine::Chat::TurnState::Idle &&
        active.messages.empty? && active.draft.empty?
    newer_generation_preserved =
      transport.handles.size == 2 && sessions.size == 2 && old_generation_retired &&
        !transport.handles.last.cancelled && !sessions.last.closed? && active.active? &&
        active.state == Adamantine::Chat::TurnState::Generating &&
        active.messages.last?.try(&.text) == "new conversation turn"
    (reset_rejected_reentrant_submit || newer_generation_preserved).should be_true
  end

  it "retirement closes the host session, preserves the draft, and fences late callbacks" do
    transport = ChatLifetimeAdversaryTransport.new
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    session_factory = chat_lifetime_adversary_session_factory(host, sessions)
    frontend = Adamantine::Chat::Frontend.new(transport, session_factory)
    frontend.set_draft("submitted").should be_true
    frontend.submit.should be_true
    frontend.set_draft("draft to retain").should be_true

    frontend.retire_context
    transport.emit(0, Adamantine::Chat::Event.delta("retired output"))
    frontend.drain

    frontend.draft.should eq("draft to retain")
    frontend.messages.map(&.text).should eq(["submitted"])
    sessions.first.closed?.should be_true
    transport.handles.first.cancelled.should be_true
  end

  it "contains transport-start exceptions and closes the newly issued session" do
    transport = ChatLifetimeAdversaryTransport.new(fail_start: true)
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    frontend = Adamantine::Chat::Frontend.new(
      transport,
      chat_lifetime_adversary_session_factory(host, sessions)
    )
    frontend.set_draft("start failure")

    frontend.submit

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should_not be_empty
    sessions.size.should eq(1)
    sessions.first.closed?.should be_true
  end

  it "contains handle-result delivery exceptions on owner drain" do
    transport = ChatLifetimeAdversaryTransport.new(fail_delivery: true)
    backend = ChatLifetimeAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    sessions = [] of Adamantine::EditorTools::Session
    frontend = Adamantine::Chat::Frontend.new(
      transport,
      chat_lifetime_adversary_session_factory(host, sessions)
    )
    frontend.set_draft("delivery failure")
    frontend.submit.should be_true
    transport.emit(0, Adamantine::Chat::Event.tool_request("call", chat_lifetime_adversary_tool_call("call", "editor.list_buffers")))

    frontend.drain

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should_not be_empty
    transport.handles.first.cancelled.should be_true
    sessions.first.closed?.should be_true
    backend.calls.size.should eq(1)
  end
end
