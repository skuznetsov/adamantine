require "spec"
require "json"
require "../src/adamantine/editor_tools"

include Adamantine::EditorTools

private class EditorToolsProtocolBackend < Adamantine::EditorTools::Backend
  include Adamantine::EditorTools

  getter calls : Array(Request)
  getter last_context : Context?
  getter observed_permit : ExecutionPermit?
  property response : JSON::Any
  property on_execute : Proc(ExecutionPermit, Nil)?

  def initialize
    @context = Context.new("/project", "epoch-1")
    @calls = [] of Request
    @response = JSON.parse({"ok" => true}.to_json)
    @observed_permit = nil
    @on_execute = nil
  end

  def context : Context
    @context
  end

  def execute(request : Request, permit : ExecutionPermit) : JSON::Any
    @calls << request
    @last_context = permit.context
    @observed_permit = permit
    @on_execute.try(&.call(permit))
    @response
  end

  def change_context(context : Context) : Nil
    @context = context
  end
end

private def editor_tools_wire(id : String, name : String,
                              arguments : Hash(String, JSON::Any)) : String
  {"id" => id, "name" => name, "arguments" => arguments}.to_json
end

private def editor_tools_args(values : Hash(String, T)) : Hash(String, JSON::Any) forall T
  values.transform_values { |value| JSON::Any.new(value) }
end

private def editor_tools_status(result : Adamantine::EditorTools::Result) : String
  JSON.parse(result.to_json)["status"].as_s
end

describe Adamantine::EditorTools do
  it "parses strict wire calls into typed requests before backend access" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Chat, [Capability::ReadEditor])

    result = session.invoke_json(editor_tools_wire("page-1", "editor.list_buffers",
      editor_tools_args({"offset" => 3, "limit" => 7})))
    result.ok?.should be_true
    result.id.should eq("page-1")
    backend.calls.size.should eq(1)
    request = backend.calls.first.as(ListBuffersRequest)
    request.offset.should eq(3)
    request.limit.should eq(7)

    defaulted = session.invoke_json(editor_tools_wire("page-2", "editor.list_buffers",
      {} of String => JSON::Any))
    defaulted.ok?.should be_true
    request = backend.calls.last.as(ListBuffersRequest)
    request.offset.should eq(0)
    request.limit.should eq(32)
  end

  it "rejects unknown fields, duplicate JSON keys, float integers, and trailing JSON" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Interactive, [Capability::ReadEditor])

    invalid = [
      %({"id":"fields","name":"editor.list_buffers","arguments":{"limit":4,"extra":true}}),
      %({"id":"float","name":"editor.list_buffers","arguments":{"limit":4.0}}),
      %({"id":"x","id":"y","name":"editor.list_buffers","arguments":{}}),
      %({"id":"trailing","name":"editor.list_buffers","arguments":{}} true),
      %({"id":"envelope","name":"editor.list_buffers","arguments":{},"extra":1}),
    ]
    expected_ids = ["fields", "float", nil, nil, "envelope"] of String?

    invalid.each_with_index do |raw, index|
      result = session.invoke_json(raw)
      result.ok?.should be_false
      editor_tools_status(result).should eq("invalid_request")
      # A valid call id in a failed call remains single-use.
      result.id.should eq(expected_ids[index])
    end
    backend.calls.should be_empty
  end

  it "enforces request byte and nesting ceilings before JSON object dispatch" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Chat, [Capability::ReadEditor])
    too_large = session.invoke_json(" " * (MAX_REQUEST_BYTES + 1))
    editor_tools_status(too_large).should eq("limit_exceeded")

    deep = "[" * (MAX_JSON_DEPTH + 1) + "null" + "]" * (MAX_JSON_DEPTH + 1)
    nested = session.invoke_json(deep)
    editor_tools_status(nested).should eq("limit_exceeded")
    backend.calls.should be_empty
  end

  it "validates identifiers, paths, query bounds, and numeric ranges without coercion" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Chat,
      [Capability::ReadEditor, Capability::Navigate])

    invalid = [
      editor_tools_wire("bad\u007f", "editor.list_buffers", {} of String => JSON::Any),
      editor_tools_wire("float", "editor.list_buffers", editor_tools_args({"offset" => 1.5})),
      editor_tools_wire("large", "editor.list_buffers", editor_tools_args({"offset" => Int64.new(Int32::MAX) + 1})),
      editor_tools_wire("path", "editor.open_file", editor_tools_args({"path" => "src\u0085/main.cr"})),
      editor_tools_wire("query", "editor.find_files", editor_tools_args({"query" => "é" * 257})),
      editor_tools_wire("line", "editor.read_buffer", editor_tools_args({
        "buffer_id" => "buffer-1", "revision" => "r1", "start_line" => 0,
      })),
    ]
    invalid.each do |raw|
      session.invoke_json(raw).ok?.should be_false
    end
    backend.calls.should be_empty

    accepted_query = session.invoke_json(editor_tools_wire("unicode-query", "editor.find_files",
      editor_tools_args({"query" => "é🙂"})))
    accepted_query.ok?.should be_true
    backend.calls.last.as(FindFilesRequest).query.should eq("é🙂")
  end

  it "filters the catalog by explicit capabilities and denies before execution" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Lua, [Capability::ReadEditor])
    definitions = session.definitions

    definitions.map(&.name).should eq([
      "editor.list_buffers",
      "editor.read_buffer",
      "editor.find_files",
    ])
    definitions.clear
    session.definitions.size.should eq(3)

    denied = session.invoke_json(editor_tools_wire("debug", "debug.snapshot",
      editor_tools_args({"limit" => 1})))
    editor_tools_status(denied).should eq("denied")
    backend.calls.should be_empty
  end

  it "uses each catalog definition's capability and argument contract for dispatch" do
    expected = {
      "editor.list_buffers" => Capability::ReadEditor,
      "editor.read_buffer"  => Capability::ReadEditor,
      "editor.find_files"   => Capability::ReadEditor,
      "editor.open_file"    => Capability::Navigate,
      "editor.focus_buffer" => Capability::Navigate,
      "debug.snapshot"      => Capability::ReadDebugger,
    }
    required = {
      "editor.list_buffers" => [] of String,
      "editor.read_buffer"  => ["buffer_id", "revision"],
      "editor.find_files"   => ["query"],
      "editor.open_file"    => ["path"],
      "editor.focus_buffer" => ["buffer_id", "revision"],
      "debug.snapshot"      => [] of String,
    }
    properties = {
      "editor.list_buffers" => ["offset", "limit"],
      "editor.read_buffer"  => ["buffer_id", "revision", "start_line", "line_count", "start_column", "max_columns"],
      "editor.find_files"   => ["query", "limit"],
      "editor.open_file"    => ["path"],
      "editor.focus_buffer" => ["buffer_id", "revision"],
      "debug.snapshot"      => ["limit"],
    }
    defaults = {
      "editor.list_buffers" => editor_tools_args({"offset" => 0, "limit" => 32}),
      "editor.read_buffer"  => editor_tools_args({"start_line" => 1, "line_count" => 16, "start_column" => 0, "max_columns" => 512}),
      "editor.find_files"   => editor_tools_args({"limit" => 32}),
      "editor.open_file"    => {} of String => JSON::Any,
      "editor.focus_buffer" => {} of String => JSON::Any,
      "debug.snapshot"      => editor_tools_args({"limit" => 32}),
    }
    arguments = {
      "editor.list_buffers" => {} of String => JSON::Any,
      "editor.read_buffer"  => editor_tools_args({"buffer_id" => "b1", "revision" => "r1"}),
      "editor.find_files"   => editor_tools_args({"query" => "src"}),
      "editor.open_file"    => editor_tools_args({"path" => "src/main.cr"}),
      "editor.focus_buffer" => editor_tools_args({"buffer_id" => "b1", "revision" => "r1"}),
      "debug.snapshot"      => {} of String => JSON::Any,
    }

    backend = EditorToolsProtocolBackend.new
    host = Host.new(backend)
    session = host.open_session(Consumer::Chat, expected.values.uniq)
    definitions = session.definitions
    definitions.size.should eq(expected.size)

    definitions.each_with_index do |definition, index|
      definition.capability.should eq(expected[definition.name])
      schema = definition.parameters.as_h
      schema["additionalProperties"].should eq(JSON::Any.new(false))
      schema_properties = schema["properties"].as_h
      schema_properties.keys.to_set.should eq(properties[definition.name].to_set)
      (schema["required"]?.try(&.as_a.map(&.as_s)) || [] of String).should eq(required[definition.name])
      schema_defaults = {} of String => JSON::Any
      schema_properties.each do |key, property|
        if value = property.as_h["default"]?
          schema_defaults[key] = value
        end
      end
      schema_defaults.should eq(defaults[definition.name])
      result = session.invoke_json(editor_tools_wire("catalog-#{index}", definition.name,
        arguments[definition.name]))
      result.ok?.should be_true
      request = backend.calls[index]
      case definition.name
      when "editor.list_buffers" then request.should be_a(ListBuffersRequest)
      when "editor.read_buffer"  then request.should be_a(ReadBufferRequest)
      when "editor.find_files"   then request.should be_a(FindFilesRequest)
      when "editor.open_file"    then request.should be_a(OpenFileRequest)
      when "editor.focus_buffer" then request.should be_a(FocusBufferRequest)
      when "debug.snapshot"      then request.should be_a(DebugSnapshotRequest)
      end
    end
  end

  it "intersects delegated capabilities, shares budgets, and invalidates descendants" do
    backend = EditorToolsProtocolBackend.new
    host = Host.new(backend, Limits.new(max_calls: 8, max_total_response_bytes: 4096))
    root = host.open_session(Consumer::Chat, [Capability::ReadEditor, Capability::Navigate])
    child = root.delegate(Consumer::Lua, [Capability::ReadEditor, Capability::ReadDebugger])

    child.definitions.map(&.name).should eq([
      "editor.list_buffers",
      "editor.read_buffer",
      "editor.find_files",
    ])
    denied = child.invoke_json(editor_tools_wire("child-debug", "debug.snapshot",
      editor_tools_args({"limit" => 1})))
    editor_tools_status(denied).should eq("denied")
    backend.calls.should be_empty

    child.close
    child.closed?.should be_true
    root.closed?.should be_false
    root.invoke_json(editor_tools_wire("root-list", "editor.list_buffers",
      {} of String => JSON::Any)).ok?.should be_true

    descendant = root.delegate(Consumer::Interactive, [Capability::ReadEditor])
    root.close
    descendant.closed?.should be_true
    closed = descendant.invoke_json(editor_tools_wire("closed", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(closed).should eq("denied")
    backend.calls.size.should eq(1)
  end

  it "captures context and refuses stale sessions without calling the backend" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Chat, [Capability::ReadEditor])
    captured = Context.new("/project", "epoch-1")
    backend.change_context(Context.new("/project", "epoch-2"))

    stale = session.invoke_json(editor_tools_wire("stale", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(stale).should eq("stale")
    backend.calls.should be_empty
    backend.last_context.should be_nil

    mutable_root = "/project"
    protected_context = Context.new(mutable_root, "epoch-1")
    mutable_root = "/changed"
    protected_context.should eq(captured)
  end

  it "rechecks captured context and ancestor closure after backend execution" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Chat, [Capability::ReadEditor])
    backend.on_execute = ->(permit : ExecutionPermit) {
      backend.change_context(Context.new("/project", "epoch-2"))
      permit.active?.should be_false
      nil
    }
    stale = session.invoke_json(editor_tools_wire("changed-during-call", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(stale).should eq("stale")
    backend.observed_permit.not_nil!.context.should eq(Context.new("/project", "epoch-1"))
    backend.observed_permit.not_nil!.active?.should be_false

    backend.change_context(Context.new("/project", "epoch-1"))
    root = Host.new(backend).open_session(Consumer::Chat, [Capability::ReadEditor])
    child = root.delegate(Consumer::Lua, [Capability::ReadEditor])
    committed = false
    backend.on_execute = ->(permit : ExecutionPermit) {
      root.close                         # Represents closure while the backend is yielded on a guarded read.
      committed = true if permit.active? # The guarded commit must not proceed.
      nil
    }
    closed = child.invoke_json(editor_tools_wire("closed-during-call", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(closed).should eq("denied")
    child.closed?.should be_true
    committed.should be_false
    backend.observed_permit.not_nil!.active?.should be_false

    direct_backend = EditorToolsProtocolBackend.new
    direct = Host.new(direct_backend).open_session(Consumer::Chat, [Capability::ReadEditor])
    direct_backend.on_execute = ->(permit : ExecutionPermit) {
      direct.close
      permit.active?.should be_false
      nil
    }
    direct_closed = direct.invoke_json(editor_tools_wire("direct-close-during-call", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(direct_closed).should eq("denied")
    direct_backend.observed_permit.not_nil!.active?.should be_false
  end

  it "does not publish a result after the invocation permit was transiently revoked" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Chat, [Capability::ReadEditor])
    backend.on_execute = ->(permit : ExecutionPermit) {
      backend.change_context(Context.new("/project", "epoch-2"))
      permit.active?.should be_false
      backend.change_context(Context.new("/project", "epoch-1"))
      nil
    }

    revoked = session.invoke_json(editor_tools_wire("transient-revoke", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(revoked).should eq("stale")
    revoked.ok?.should be_false
    backend.observed_permit.not_nil!.active?.should be_false
  end

  it "revokes a permit after its backend invocation returns" do
    backend = EditorToolsProtocolBackend.new
    session = Host.new(backend).open_session(Consumer::Chat, [Capability::ReadEditor])
    result = session.invoke_json(editor_tools_wire("permit-lifetime", "editor.list_buffers",
      {} of String => JSON::Any))

    result.ok?.should be_true
    permit = backend.observed_permit.not_nil!
    permit.context.should eq(Context.new("/project", "epoch-1"))
    permit.active?.should be_false
  end

  it "records failed call IDs and charges malformed attempts against the shared call budget" do
    backend = EditorToolsProtocolBackend.new
    host = Host.new(backend, Limits.new(max_calls: 2, max_total_response_bytes: 1024))
    session = host.open_session(Consumer::Chat, [Capability::ReadEditor])

    unknown = session.invoke_json(editor_tools_wire("used", "editor.unknown",
      {} of String => JSON::Any))
    editor_tools_status(unknown).should eq("invalid_request")
    duplicate = session.invoke_json(editor_tools_wire("used", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(duplicate).should eq("duplicate_call")
    exhausted = session.invoke_json(editor_tools_wire("third", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(exhausted).should eq("limit_exceeded")
    session.exhausted?.should be_true
    backend.calls.should be_empty
  end

  it "seals result JSON and returns one bounded terminal response on budget exhaustion" do
    backend = EditorToolsProtocolBackend.new
    backend.response = JSON.parse({"text" => "small"}.to_json)
    host = Host.new(backend, Limits.new(max_calls: 1, max_response_bytes: 256,
      max_total_response_bytes: 512))
    session = host.open_session(Consumer::Chat, [Capability::ReadEditor])

    result = session.invoke_json(editor_tools_wire("one", "editor.list_buffers",
      {} of String => JSON::Any))
    result.ok?.should be_true
    original = result.to_json
    mutable_data = result.data.not_nil!
    mutable_data.as_h["text"] = JSON::Any.new("changed")
    result.to_json.should eq(original)
    result.encoded_bytes.should eq(original.bytesize)

    terminal = session.invoke_json(editor_tools_wire("two", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(terminal).should eq("limit_exceeded")
    session.exhausted?.should be_true
    calls_after_limit = backend.calls.size
    repeated = session.invoke_json("not parsed after exhaustion")
    repeated.to_json.should eq(terminal.to_json)
    backend.calls.size.should eq(calls_after_limit)
    terminal.encoded_bytes.should be <= MAX_RESPONSE_BYTES
  end

  it "prevents child creation from resetting the session budget or exceeding depth" do
    backend = EditorToolsProtocolBackend.new
    host = Host.new(backend, Limits.new(max_calls: 1, max_total_response_bytes: 1024,
      max_depth: 1, max_children: 1))
    root = host.open_session(Consumer::Chat, [Capability::ReadEditor])
    child = root.delegate(Consumer::Lua, [Capability::ReadEditor])
    expect_raises(Failure) { child.delegate(Consumer::Interactive, [Capability::ReadEditor]) }
    expect_raises(Failure) { root.delegate(Consumer::Lua, [Capability::ReadEditor]) }

    root.invoke_json(editor_tools_wire("first", "editor.list_buffers",
      {} of String => JSON::Any)).ok?.should be_true
    blocked = child.invoke_json(editor_tools_wire("second", "editor.list_buffers",
      {} of String => JSON::Any))
    editor_tools_status(blocked).should eq("limit_exceeded")
    backend.calls.size.should eq(1)
  end

  it "defers one approved named run and shares child calls and result bytes with its parent" do
    backend = EditorToolsProtocolBackend.new
    host = Host.new(backend, Limits.new(max_calls: 4, max_total_response_bytes: 4096))
    parent = host.open_session(Consumer::Chat,
      [Capability::RunScript, Capability::ReadEditor, Capability::ProposeEdits])

    deferred = parent.defer_json(editor_tools_wire("outer-1", "lua.run_script",
      editor_tools_args({"script_id" => "approved-script"})), expected_call_id: "outer-1")
    deferred.should be_a(DeferredCall)
    ticket = deferred.as(DeferredCall)
    ticket.request.should be_a(RunScriptRequest)
    ticket.request.as(RunScriptRequest).script_id.should eq("approved-script")
    ticket.id.should eq("outer-1")
    ticket.active?.should be_true

    child = ticket.child_session([Capability::ReadEditor, Capability::ProposeEdits,
                                  Capability::RunScript])
    child.consumer.should eq(Consumer::Lua)
    child.definitions.map(&.name).should eq([
      "editor.list_buffers",
      "editor.read_buffer",
      "editor.propose_edits",
      "editor.find_files",
    ])
    child.invoke_json(editor_tools_wire("child-read", "editor.read_buffer",
      editor_tools_args({"buffer_id" => "b1", "revision" => "r1"}))).ok?.should be_true

    completed = ticket.complete(JSON.parse({"stdout" => "bounded output"}.to_json))
    completed.status.should eq(Status::Ok)
    completed.id.should eq("outer-1")
    completed.to_json.should contain("bounded output")
    ticket.active?.should be_false
    ticket.complete(JSON.parse({"stdout" => "late"}.to_json)).status.should_not eq(Status::Ok)
    backend.calls.size.should eq(1)
  end

  it "keeps child tool failures sticky even if the named script continues and returns" do
    backend = EditorToolsProtocolBackend.new
    parent = Host.new(backend, Limits.new(max_calls: 4, max_total_response_bytes: 4096))
      .open_session(Consumer::Chat, [Capability::RunScript, Capability::ReadEditor])
    ticket = parent.defer_json(editor_tools_wire("outer", "lua.run_script",
      editor_tools_args({"script_id" => "approved-script"})), expected_call_id: "outer")
      .as(DeferredCall)
    child = ticket.child_session([Capability::RunScript])

    denied = child.invoke_json(editor_tools_wire("child-run", "lua.run_script",
      editor_tools_args({"script_id" => "nested-script"})))
    denied.status.should eq(Status::Denied)
    ticket.child_failed?.should be_true
    ticket.complete(JSON.parse({"stdout" => "script caught the denial"}.to_json)).status.should eq(Status::Denied)
    ticket.active?.should be_false
    child.closed?.should be_true
  end

  it "rejects forged tickets and honors the configured deferred-child depth bound" do
    backend = EditorToolsProtocolBackend.new
    parent = Host.new(backend, Limits.new(max_calls: 4, max_total_response_bytes: 4096,
      max_depth: 0)).open_session(Consumer::Chat, [Capability::RunScript, Capability::ReadEditor])
    ticket = parent.defer_json(editor_tools_wire("outer", "lua.run_script",
      editor_tools_args({"script_id" => "approved-script"})), expected_call_id: "outer")
      .as(DeferredCall)

    forged = DeferredCall.new(parent, "forged", RunScriptRequest.new("approved-script"))
    forged.active?.should be_false
    expect_raises(Failure) { forged.child_session([Capability::ReadEditor]) }
    expect_raises(Failure) { ticket.child_session([Capability::ReadEditor]) }
  end

  it "charges expected-ID and request-guard refusals through the shared Session budget" do
    backend = EditorToolsProtocolBackend.new
    host = Host.new(backend, Limits.new(max_calls: 2, max_total_response_bytes: 4096))
    session = host.open_session(Consumer::Chat, [Capability::ReadEditor])
    guard : Proc(Request, Nil) = ->(request : Request) {
      if request.is_a?(ReadBufferRequest)
        raise Failure.new(Status::Denied, "buffer is outside the approved turn scope")
      end
    }

    mismatch = session.invoke_json(editor_tools_wire("payload-id", "editor.list_buffers",
      {} of String => JSON::Any), expected_call_id: "event-id", request_guard: guard)
    mismatch.status.should eq(Status::InvalidRequest)
    mismatch.id.should eq("event-id")

    denied = session.invoke_json(editor_tools_wire("outside", "editor.read_buffer",
      editor_tools_args({"buffer_id" => "other", "revision" => "r1"})),
      expected_call_id: "outside", request_guard: guard)
    denied.status.should eq(Status::Denied)
    exhausted = session.invoke_json(editor_tools_wire("third", "editor.list_buffers",
      {} of String => JSON::Any), expected_call_id: "third", request_guard: guard)
    exhausted.status.should eq(Status::LimitExceeded)
    session.exhausted?.should be_true
    backend.calls.should be_empty
  end

  it "denies a second deferred run, duplicate outer IDs, and late results after parent close" do
    backend = EditorToolsProtocolBackend.new
    parent = Host.new(backend, Limits.new(max_calls: 4, max_total_response_bytes: 4096))
      .open_session(Consumer::Chat, [Capability::RunScript])
    wire = editor_tools_wire("outer-1", "lua.run_script",
      editor_tools_args({"script_id" => "approved-script"}))
    ticket = parent.defer_json(wire, expected_call_id: "outer-1").as(DeferredCall)

    duplicate = parent.defer_json(wire, expected_call_id: "outer-1").as(Result)
    duplicate.status.should eq(Status::DuplicateCall)
    second = parent.defer_json(editor_tools_wire("outer-2", "lua.run_script",
      editor_tools_args({"script_id" => "approved-script"})), expected_call_id: "outer-2").as(Result)
    second.status.should eq(Status::Denied)

    child = ticket.child_session([Capability::ReadEditor])
    parent.close
    ticket.active?.should be_false
    child.closed?.should be_true
    ticket.complete(JSON.parse({"stdout" => "late"}.to_json)).status.should_not eq(Status::Ok)
    parent.definitions.should be_empty
    backend.calls.should be_empty
  end
end
