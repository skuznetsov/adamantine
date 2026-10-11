require "spec"
require "json"
require "../src/adamantine/chat_provider_transport"

private class ChatEditProtocolBackend < Adamantine::EditorTools::Backend
  getter calls : Array(Adamantine::EditorTools::Request)

  def initialize
    @calls = [] of Adamantine::EditorTools::Request
  end

  def context : Adamantine::EditorTools::Context
    Adamantine::EditorTools::Context.new("/project", "chat-edit-spec")
  end

  def execute(request : Adamantine::EditorTools::Request,
              permit : Adamantine::EditorTools::ExecutionPermit) : JSON::Any
    @calls << request
    JSON.parse({"status" => "pending_review", "applied" => false}.to_json)
  end
end

private class ChatEditRejectingProposalBackend < Adamantine::EditorTools::Backend
  getter calls : Array(Adamantine::EditorTools::Request)

  def initialize
    @calls = [] of Adamantine::EditorTools::Request
  end

  def context : Adamantine::EditorTools::Context
    Adamantine::EditorTools::Context.new("/project", "chat-edit-reject-spec")
  end

  def execute(request : Adamantine::EditorTools::Request,
              permit : Adamantine::EditorTools::ExecutionPermit) : JSON::Any
    @calls << request
    raise Adamantine::EditorTools::Failure.new(
      Adamantine::EditorTools::Status::InvalidRequest,
      "proposal rejected by owner"
    )
  end
end

private class ChatEditProtocolHandle < Adamantine::Chat::Handle
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

private class ChatEditProtocolTransport < Adamantine::Chat::Transport
  getter requests : Array(Adamantine::Chat::Request)
  getter handles : Array(ChatEditProtocolHandle)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))

  def initialize
    @requests = [] of Adamantine::Chat::Request
    @handles = [] of ChatEditProtocolHandle
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
  end

  def external? : Bool
    true
  end

  def available? : Bool
    true
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    @requests << request
    @callbacks << on_event
    handle = ChatEditProtocolHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private def chat_edit_protocol_envelope(id : String, name : String,
                                        arguments : String) : String
  %({"id":"#{id}","name":"#{name}","arguments":#{arguments}})
end

private def chat_edit_protocol_frontend(transport : ChatEditProtocolTransport) : Adamantine::Chat::Frontend
  host = Adamantine::EditorTools::Host.new(ChatEditProtocolBackend.new)
  context_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
    host.open_session(Adamantine::EditorTools::Consumer::Chat,
      [Adamantine::EditorTools::Capability::ReadEditor, Adamantine::EditorTools::Capability::ProposeEdits])
  }
  Adamantine::Chat::Frontend.new(transport, context_session_factory: context_factory)
end

describe "CHAT-3 typed proposal protocol" do
  it "exposes a separate capability and strict immutable request with codepoint coordinates" do
    backend = ChatEditProtocolBackend.new
    session = Adamantine::EditorTools::Host.new(backend).open_session(
      Adamantine::EditorTools::Consumer::Chat,
      [Adamantine::EditorTools::Capability::ProposeEdits]
    )

    definitions = session.definitions
    definitions.map(&.name).should eq(["editor.propose_edits"])
    definition = definitions.first
    definition.capability.should eq(Adamantine::EditorTools::Capability::ProposeEdits)
    schema = definition.parameters.as_h
    schema["additionalProperties"].should eq(JSON::Any.new(false))
    schema_properties = schema["properties"].as_h
    schema_properties.keys.to_set.should eq(["buffer_id", "revision", "edits"].to_set)
    required = schema["required"].as_a.map(&.as_s)
    required.should eq(["buffer_id", "revision", "edits"])
    edit_schema = schema_properties["edits"].as_h
    edit_schema["minItems"].as_i.should eq(1)
    edit_schema["maxItems"].as_i.should eq(32)
    edit_properties = edit_schema["items"].as_h["properties"].as_h
    edit_properties.keys.to_set.should eq([
      "start_line", "start_column", "end_line", "end_column", "new_text",
    ].to_set)
    edit_schema["items"].as_h["additionalProperties"].should eq(JSON::Any.new(false))

    arguments = {
      "buffer_id" => "buf-1",
      "revision"  => "rev-1",
      "edits"     => [{
        "start_line"   => 1,
        "start_column" => 2,
        "end_line"     => 1,
        "end_column"   => 3,
        "new_text"     => "🙂\n",
      }],
    }.to_json
    raw = chat_edit_protocol_envelope("proposal-1", "editor.propose_edits", arguments)
    result = session.invoke_json(raw)
    result.ok?.should be_true
    request = backend.calls.first.as(Adamantine::EditorTools::ProposeEditsRequest)
    request.buffer_id.should eq("buf-1")
    request.revision.should eq("rev-1")
    request.edits.size.should eq(1)
    request.edits.first.start_line.should eq(1)
    request.edits.first.start_column.should eq(2)
    request.edits.first.end_column.should eq(3)
    request.edits.first.new_text.should eq("🙂\n")
    backend_result = JSON.parse(result.data.not_nil!.to_json)
    backend_result["status"].as_s.should eq("pending_review")
    backend_result["applied"].as_bool.should be_false

    exposed_edits = request.edits
    exposed_edits.clear
    request.edits.size.should eq(1)
  end

  it "rejects malformed, oversized, reversed, overlapping, and same-point batches atomically" do
    backend = ChatEditProtocolBackend.new
    session = Adamantine::EditorTools::Host.new(backend).open_session(
      Adamantine::EditorTools::Consumer::Chat,
      [Adamantine::EditorTools::Capability::ProposeEdits]
    )
    invalid_arguments = [
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"x","path":"no"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":2,"end_line":1,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":3,"new_text":"x"},{"start_line":1,"start_column":2,"end_line":1,"end_column":4,"new_text":"y"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":2,"end_line":1,"end_column":2,"new_text":"x"},{"start_line":1,"start_column":2,"end_line":1,"end_column":2,"new_text":"y"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1.0,"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"x\u0000"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"end_line":1,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":null,"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":null,"end_line":1,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":null,"end_column":1,"new_text":"x"}]}),
      %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":null,"new_text":"x"}]}),
    ]

    invalid_arguments.each_with_index do |arguments, index|
      result = session.invoke_json(chat_edit_protocol_envelope("bad-#{index}", "editor.propose_edits", arguments))
      result.ok?.should be_false
    end
    oversized_edits = Array.new(33) do
      {"start_line" => 1, "start_column" => 0, "end_line" => 1, "end_column" => 0, "new_text" => "x"}
    end
    oversized = session.invoke_json({
      "id"        => "too-many",
      "name"      => "editor.propose_edits",
      "arguments" => {"buffer_id" => "buf-1", "revision" => "rev-1", "edits" => oversized_edits},
    }.to_json)
    oversized.ok?.should be_false

    ambiguous_batches = [
      [
        {"start_line" => 1, "start_column" => 0, "end_line" => 1, "end_column" => 0, "new_text" => ""},
        {"start_line" => 1, "start_column" => 0, "end_line" => 1, "end_column" => 2, "new_text" => "x"},
      ],
      [
        {"start_line" => 1, "start_column" => 0, "end_line" => 1, "end_column" => 2, "new_text" => "x"},
        {"start_line" => 1, "start_column" => 2, "end_line" => 1, "end_column" => 2, "new_text" => ""},
      ],
    ]
    ambiguous_batches.each_with_index do |edits, index|
      result = session.invoke_json({
        "id"        => "ambiguous-#{index}",
        "name"      => "editor.propose_edits",
        "arguments" => {"buffer_id" => "buf-1", "revision" => "rev-1", "edits" => edits},
      }.to_json)
      result.ok?.should be_false
    end
    backend.calls.should be_empty
  end

  it "requires the proposal capability and denies proposal dispatch outside BufferProposals" do
    transport = ChatEditProtocolTransport.new
    backend = ChatEditProtocolBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    context_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor, Adamantine::EditorTools::Capability::ProposeEdits])
    }
    frontend = Adamantine::Chat::Frontend.new(transport, context_session_factory: context_factory)
    selected = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferProposals,
      "Selected buffer proposals",
      "",
      "buf-1",
      "rev-1"
    )
    frontend.set_draft("make a small proposal")
    frontend.submit(selected).should be_true
    transport.emit(0, Adamantine::Chat::Event.tool_request("proposal-1",
      chat_edit_protocol_envelope("proposal-1", "editor.propose_edits",
        %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}))))
    frontend.drain
    backend.calls.size.should eq(1)
    backend.calls.first.should be_a(Adamantine::EditorTools::ProposeEditsRequest)
    JSON.parse(transport.handles.first.tool_results.first[1])["status"].as_s.should eq("ok")
    transport.emit(0, Adamantine::Chat::Event.tool_request("proposal-duplicate",
      chat_edit_protocol_envelope("proposal-duplicate", "editor.propose_edits",
        %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"y"}]}))))
    frontend.drain
    backend.calls.size.should eq(1)
    JSON.parse(transport.handles.first.tool_results.last[1])["status"].as_s.should eq("denied")
    frontend.proposal_revision.should be > 0_u64

    frontend.cancel.should be_true
    after_cancel = frontend.proposal_revision
    frontend.set_draft("read-only disclosure")
    read_only = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools,
      "Read-only buffer tools",
      "",
      "buf-1",
      "rev-1"
    )
    frontend.submit(read_only).should be_true
    transport.emit(1, Adamantine::Chat::Event.tool_request("proposal-2",
      chat_edit_protocol_envelope("proposal-2", "editor.propose_edits",
        %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}))))
    frontend.drain
    backend.calls.size.should eq(1)
    JSON.parse(transport.handles.last.tool_results.first[1])["status"].as_s.should eq("denied")
    frontend.proposal_revision.should be > after_cancel
  end

  it "spends the turn's proposal attempt even when the owner rejects the first typed proposal" do
    transport = ChatEditProtocolTransport.new
    backend = ChatEditRejectingProposalBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    context_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ProposeEdits])
    }
    frontend = Adamantine::Chat::Frontend.new(transport, context_session_factory: context_factory)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferProposals,
      "Selected buffer proposals",
      "",
      "buf-1",
      "rev-1"
    )
    proposal = ->(text : String) {
      chat_edit_protocol_envelope("proposal-call", "editor.propose_edits",
        %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"#{text}"}]}))
    }

    frontend.set_draft("make one bounded proposal")
    frontend.submit(context).should be_true
    transport.emit(0, Adamantine::Chat::Event.tool_request("proposal-call", proposal.call("x")))
    frontend.drain

    backend.calls.size.should eq(1)
    backend.calls.first.should be_a(Adamantine::EditorTools::ProposeEditsRequest)
    JSON.parse(transport.handles.first.tool_results.first[1])["status"].as_s.should eq("invalid_request")

    second_call = "proposal-second"
    second_request = %({"id":"#{second_call}","name":"editor.propose_edits","arguments":{"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"y"}]}})
    transport.emit(0, Adamantine::Chat::Event.tool_request(second_call, second_request))
    frontend.drain

    backend.calls.size.should eq(1)
    JSON.parse(transport.handles.first.tool_results.last[1])["status"].as_s.should eq("denied")
    frontend.state.should eq(Adamantine::Chat::TurnState::Generating)
  end

  it "keeps denied BufferTools proposals inside the existing provider tool-attempt budget" do
    transport = ChatEditProtocolTransport.new
    frontend = chat_edit_protocol_frontend(transport)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools,
      "Read-only selected buffer",
      "",
      "buf-1",
      "rev-1"
    )
    frontend.set_draft("read only")
    frontend.submit(context).should be_true

    Adamantine::Chat::MAX_TOOL_ATTEMPTS.should eq(16)
    17.times do |index|
      call_id = "proposal-attempt-#{index}"
      transport.emit(0, Adamantine::Chat::Event.tool_request(call_id,
        chat_edit_protocol_envelope(call_id, "editor.propose_edits",
          %({"buffer_id":"buf-1","revision":"rev-1","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}))))
      frontend.drain
    end

    frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    frontend.status.should contain("tool-attempt limit")
    transport.handles.first.tool_results.size.should eq(16)
    transport.handles.first.cancelled.should be_true
  end

  it "keeps proposal revision through Complete but revokes it on cancellation and conversation reset" do
    transport = ChatEditProtocolTransport.new
    host = Adamantine::EditorTools::Host.new(ChatEditProtocolBackend.new)
    context_factory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ProposeEdits])
    }
    frontend = Adamantine::Chat::Frontend.new(transport, context_session_factory: context_factory)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferProposals,
      "Selected buffer proposals",
      "",
      "buf-1",
      "rev-1"
    )
    frontend.set_draft("first")
    before_submit = frontend.proposal_revision
    frontend.submit(context).should be_true
    after_submit = frontend.proposal_revision
    after_submit.should be > before_submit
    transport.emit(0, Adamantine::Chat::Event.complete)
    frontend.drain
    frontend.proposal_revision.should eq(after_submit)

    frontend.set_draft("second")
    frontend.submit(context).should be_true
    after_second_submit = frontend.proposal_revision
    after_second_submit.should be > after_submit
    frontend.cancel.should be_true
    frontend.proposal_revision.should be > after_second_submit

    before_reset = frontend.proposal_revision
    frontend.new_conversation
    frontend.proposal_revision.should be > before_reset
  end

  it "revokes proposal review on export clear, failure, retirement, conversation reset, and shutdown" do
    transport = ChatEditProtocolTransport.new
    frontend = chat_edit_protocol_frontend(transport)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferProposals,
      "Selected buffer proposals",
      "",
      "buf-1",
      "rev-1"
    )

    frontend.set_draft("complete first")
    frontend.submit(context).should be_true
    transport.emit(0, Adamantine::Chat::Event.complete)
    frontend.drain
    after_complete = frontend.proposal_revision
    frontend.clear_exportable_history
    after_clear = frontend.proposal_revision
    after_clear.should be > after_complete

    frontend.set_draft("fail this turn")
    frontend.submit(context).should be_true
    before_failure = frontend.proposal_revision
    transport.emit(1, Adamantine::Chat::Event.failure("provider failed"))
    frontend.drain
    after_failure = frontend.proposal_revision
    after_failure.should be > before_failure

    frontend.set_draft("retire this turn")
    frontend.submit(context).should be_true
    before_retire = frontend.proposal_revision
    frontend.retire_context
    frontend.proposal_revision.should be > before_retire

    frontend.set_draft("reset this turn")
    frontend.submit(context).should be_true
    before_reset = frontend.proposal_revision
    frontend.new_conversation
    after_reset = frontend.proposal_revision
    after_reset.should be > before_reset

    frontend.set_draft("shut down this turn")
    frontend.submit(context).should be_true
    before_shutdown = frontend.proposal_revision
    frontend.shutdown
    frontend.proposal_revision.should be > before_shutdown
  end
end
