require "spec"
require "http/server"
require "json"
require "../src/adamantine/chat_frontend"
require "../src/adamantine/chat_provider_config"
require "../src/adamantine/chat_provider_transport"

private struct ChatProviderObservedRequest
  getter path : String
  getter authorization : String?
  getter accept_encoding : String?
  getter body : String

  def initialize(@path : String, @authorization : String?, @accept_encoding : String?, @body : String)
  end
end

private class ChatProviderStub
  getter requests = Channel(ChatProviderObservedRequest).new(8)

  @server : HTTP::Server
  @address : Socket::IPAddress
  @request_count = Atomic(Int32).new(0)

  def initialize(&handler : HTTP::Server::Context, String -> Nil)
    requests = @requests
    @server = HTTP::Server.new do |context|
      request = context.request
      observed = ChatProviderObservedRequest.new(
        request.resource,
        request.headers["Authorization"]?,
        request.headers["Accept-Encoding"]?,
        request.body.try(&.gets_to_end) || ""
      )
      @request_count.add(1)
      requests.send(observed)
      handler.call(context, observed.body)
    end
    @address = @server.bind_tcp("127.0.0.1", 0)
    spawn(name: "chat-provider-stub") { @server.listen }
    deadline = Time.instant + 5.seconds
    until @server.listening?
      raise "provider stub did not start listening" unless (deadline - Time.instant).positive?
      select
      when timeout(1.millisecond)
      end
    end
  end

  def request_count : Int32
    @request_count.get
  end

  def endpoint(path : String = "/v1/chat/completions") : String
    "http://127.0.0.1:#{@address.port}#{path}"
  end

  def close : Nil
    @server.close unless @server.closed?
  end
end

private class ChatProviderQuickTimeoutTransport < Adamantine::Chat::ProviderTransport
  protected def total_timeout : Time::Span
    150.milliseconds
  end
end

private class ChatProviderScopeBackend < Adamantine::EditorTools::Backend
  def context : Adamantine::EditorTools::Context
    Adamantine::EditorTools::Context.new("/project", "chat-provider-scope-spec")
  end

  def execute(request : Adamantine::EditorTools::Request,
              permit : Adamantine::EditorTools::ExecutionPermit) : JSON::Any
    raise "unexpected backend execution for provider adapter refusal"
  end
end

private def chat_provider_text_stream(content : String, finish_reason : String = "stop") : String
  chunks = [
    {"choices" => [{"index" => 0, "delta" => {"role" => "assistant", "content" => content}, "finish_reason" => nil}]},
    {"choices" => [{"index" => 0, "delta" => {} of String => String, "finish_reason" => finish_reason}]},
  ]
  chunks.map { |chunk| "data: #{chunk.to_json}\n\n" }.join + "data: [DONE]\n\n"
end

private def chat_provider_read_arguments(buffer_id : String = "buf-1", revision : String = "rev-1") : String
  {
    "buffer_id"    => buffer_id,
    "revision"     => revision,
    "start_line"   => 1,
    "line_count"   => 20,
    "start_column" => 1,
    "max_columns"  => 120,
  }.to_json
end

private def chat_provider_tool_stream(id : String, function_name : String, arguments : String) : String
  call = {
    "index"    => 0,
    "id"       => id,
    "type"     => "function",
    "function" => {"name" => function_name, "arguments" => arguments},
  }
  chunks = [
    {"choices" => [{"index" => 0, "delta" => {"tool_calls" => [call]}, "finish_reason" => nil}]},
    {"choices" => [{"index" => 0, "delta" => {} of String => String, "finish_reason" => "tool_calls"}]},
  ]
  chunks.map { |chunk| "data: #{chunk.to_json}\n\n" }.join + "data: [DONE]\n\n"
end

private def chat_provider_duplicate_tool_stream(id : String, arguments : String) : String
  calls = [0, 1].map do |index|
    {
      "index"    => index,
      "id"       => id,
      "type"     => "function",
      "function" => {"name" => "editor_read_buffer", "arguments" => arguments},
    }
  end
  chunks = [
    {"choices" => [{"index" => 0, "delta" => {"tool_calls" => calls}, "finish_reason" => nil}]},
    {"choices" => [{"index" => 0, "delta" => {} of String => String, "finish_reason" => "tool_calls"}]},
  ]
  chunks.map { |chunk| "data: #{chunk.to_json}\n\n" }.join + "data: [DONE]\n\n"
end

private def chat_provider_incomplete_tool_stream : String
  call = {
    "index"    => 0,
    "type"     => "function",
    "function" => {"name" => "editor_read_buffer", "arguments" => "{}"},
  }
  chunks = [
    {"choices" => [{"index" => 0, "delta" => {"tool_calls" => [call]}, "finish_reason" => nil}]},
    {"choices" => [{"index" => 0, "delta" => {} of String => String, "finish_reason" => "tool_calls"}]},
  ]
  chunks.map { |chunk| "data: #{chunk.to_json}\n\n" }.join + "data: [DONE]\n\n"
end

private def chat_provider_buffer_context(buffer_id : String = "buf-1", revision : String = "rev-1") : Adamantine::Chat::SubmissionContext
  Adamantine::Chat::SubmissionContext.new(
    Adamantine::Chat::ContextMode::BufferTools,
    "Active buffer tools",
    "",
    buffer_id,
    revision
  )
end

private def receive_chat_provider_event(events : Channel(Adamantine::Chat::Event), timeout : Time::Span = 5.seconds) : Adamantine::Chat::Event
  select
  when event = events.receive
    event
  when timeout(timeout)
    raise "provider event timed out"
  end
end

private def receive_chat_provider_request(requests : Channel(ChatProviderObservedRequest), timeout : Time::Span = 5.seconds) : ChatProviderObservedRequest
  select
  when request = requests.receive
    request
  when timeout(timeout)
    raise "provider stub request timed out"
  end
end

private def receive_chat_provider_body(bodies : Channel(String), timeout : Time::Span = 5.seconds) : String
  select
  when body = bodies.receive
    body
  when timeout(timeout)
    raise "provider stub request body timed out"
  end
end

private def expect_no_chat_provider_request(requests : Channel(ChatProviderObservedRequest)) : Nil
  select
  when request = requests.receive
    raise "unexpected provider request to #{request.path}"
  else
  end
end

private def expect_no_chat_provider_event(events : Channel(Adamantine::Chat::Event)) : Nil
  select
  when event = events.receive
    raise "unexpected provider event #{event.kind}"
  else
  end
end

private def release_chat_provider_fixture(channel : Channel(Nil)) : Nil
  select
  when channel.send(nil)
  else
  end
end

private def rejected_chat_provider_tool_turn(stream : String, context : Adamantine::Chat::SubmissionContext) : String
  stub = nil.as(ChatProviderStub?)
  handle = nil.as(Adamantine::Chat::Handle?)
  stub = ChatProviderStub.new do |response, _body|
    response.response.status_code = 200
    response.response.headers["Content-Type"] = "text/event-stream"
    response.response.print(stream)
  end
  config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "explicit-model", key_env: "")
  transport = Adamantine::Chat::ProviderTransport.new(config)
  events = Channel(Adamantine::Chat::Event).new(8)
  handle = transport.start(Adamantine::Chat::Request.new(91_u64, "read only this buffer", context), chat_provider_callback(events))
  received = read_chat_provider_terminal(events)
  received.map(&.kind).should_not contain(Adamantine::Chat::Event::Kind::ToolRequest)
  received.last.kind.should eq(Adamantine::Chat::Event::Kind::Failure)
  receive_chat_provider_request(stub.requests)
  stub.request_count.should eq(1)
  received.last.text.not_nil!
ensure
  handle.try(&.cancel)
  stub.try(&.close)
end

private def emitted_chat_provider_tool_request(
  stream : String,
  context : Adamantine::Chat::SubmissionContext,
) : Adamantine::Chat::Event
  stub = nil.as(ChatProviderStub?)
  handle = nil.as(Adamantine::Chat::Handle?)
  stub = ChatProviderStub.new do |response, _body|
    response.response.status_code = 200
    response.response.headers["Content-Type"] = "text/event-stream"
    response.response.print(stream)
  end
  config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "explicit-model", key_env: "")
  transport = Adamantine::Chat::ProviderTransport.new(config)
  events = Channel(Adamantine::Chat::Event).new(8)
  handle = transport.start(Adamantine::Chat::Request.new(93_u64, "bounded provider tool test", context), chat_provider_callback(events))
  event = receive_chat_provider_event(events)
  event.kind.should eq(Adamantine::Chat::Event::Kind::ToolRequest)
  receive_chat_provider_request(stub.requests)
  stub.request_count.should eq(1)
  event
ensure
  handle.try(&.cancel)
  stub.try(&.close)
end

private def failed_chat_provider_stream(
  stream : String,
  context : Adamantine::Chat::SubmissionContext = Adamantine::Chat::SubmissionContext.none,
) : Array(Adamantine::Chat::Event)
  stub = nil.as(ChatProviderStub?)
  handle = nil.as(Adamantine::Chat::Handle?)
  stub = ChatProviderStub.new do |response, _body|
    response.response.status_code = 200
    response.response.headers["Content-Type"] = "text/event-stream"
    response.response.print(stream)
  end
  config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "explicit-model", key_env: "")
  transport = Adamantine::Chat::ProviderTransport.new(config)
  events = Channel(Adamantine::Chat::Event).new(8)
  handle = transport.start(Adamantine::Chat::Request.new(92_u64, "bounded provider test", context), chat_provider_callback(events))
  received = read_chat_provider_terminal(events)
  received.last.kind.should eq(Adamantine::Chat::Event::Kind::Failure)
  received.map(&.kind).should_not contain(Adamantine::Chat::Event::Kind::Complete)
  receive_chat_provider_request(stub.requests)
  stub.request_count.should eq(1)
  expect_no_chat_provider_request(stub.requests)
  received
ensure
  handle.try(&.cancel)
  stub.try(&.close)
end

private def await_chat_provider_cleanup(
  transport : Adamantine::Chat::ProviderTransport,
  request : Adamantine::Chat::Request,
  callback : Proc(Adamantine::Chat::Event, Nil),
  timeout : Time::Span = 5.seconds,
) : Nil
  deadline = Time.instant + timeout
  loop do
    returned_handle = nil.as(Adamantine::Chat::Handle?)
    begin
      returned_handle = transport.start(request, callback)
    rescue failure : Adamantine::Chat::ProviderTransport::ProviderFailure
      message = failure.message || ""
      if message == "Configured API key is missing or invalid; draft retained."
        return
      elsif message != "A previous chat request is still shutting down."
        raise failure
      end
    end
    if handle = returned_handle
      handle.cancel
      raise "provider unexpectedly restarted before credential preflight rejected it"
    end
    raise "provider did not release its cancelled handle" unless (deadline - Time.instant).positive?
    select
    when timeout(1.millisecond)
    end
  end
end

private def chat_provider_callback(events : Channel(Adamantine::Chat::Event)) : Proc(Adamantine::Chat::Event, Nil)
  ->(event : Adamantine::Chat::Event) { events.send(event); nil }
end

private def read_chat_provider_terminal(events : Channel(Adamantine::Chat::Event)) : Array(Adamantine::Chat::Event)
  received = [] of Adamantine::Chat::Event
  loop do
    event = receive_chat_provider_event(events)
    received << event
    break if event.kind.complete? || event.kind.failure?
  end
  received
end

describe Adamantine::Chat::ProviderTransport do
  it "is an external transport and availability does not resolve or inspect credentials" do
    stub = ChatProviderStub.new do |context, _body|
      context.response.status_code = 200
      context.response.headers["Content-Type"] = "text/event-stream"
      context.response.print(chat_provider_text_stream("ok"))
    end
    resolver_calls = 0
    resolver = ->(_name : String) : String? { resolver_calls += 1; "fixture-secret" }
    config = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      endpoint: stub.endpoint,
      model: "explicit/model",
      key_env: "CHAT_TEST_KEY"
    )
    transport = Adamantine::Chat::ProviderTransport.new(config, resolver)

    transport.external?.should be_true
    transport.available?.should be_true
    resolver_calls.should eq(0)
    expect_no_chat_provider_request(stub.requests)
  ensure
    stub.try(&.close)
  end

  it "sends bounded Chat Completions fields and emits streamed text without reflecting the key" do
    stub = ChatProviderStub.new do |context, _body|
      context.response.status_code = 200
      context.response.headers["Content-Type"] = "text/event-stream"
      context.response.print(chat_provider_text_stream("hello"))
    end
    resolver = ->(name : String) { name == "CHAT_TEST_KEY" ? "fixture-secret" : nil }
    config = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      endpoint: stub.endpoint,
      model: "user-selected-model",
      key_env: "CHAT_TEST_KEY",
      max_completion_tokens: 1777
    )
    transport = Adamantine::Chat::ProviderTransport.new(config, resolver)
    events = Channel(Adamantine::Chat::Event).new(8)

    handle = transport.start(Adamantine::Chat::Request.new(1_u64, "say hello"), chat_provider_callback(events))
    received = read_chat_provider_terminal(events)
    received.map(&.kind).should eq([Adamantine::Chat::Event::Kind::Delta, Adamantine::Chat::Event::Kind::Complete])
    received.first.text.should eq("hello")
    _ = handle

    request = receive_chat_provider_request(stub.requests)
    request.path.should eq("/v1/chat/completions")
    request.authorization.should eq("Bearer fixture-secret")
    request.accept_encoding.should eq("identity")
    body = JSON.parse(request.body)
    body["model"].as_s.should eq("user-selected-model")
    body["max_completion_tokens"].as_i.should eq(1777)
    body.as_h.has_key?("reasoning_effort").should be_false
    body["n"].as_i.should eq(1)
    body["store"].as_bool.should be_false
    body["stream"].as_bool.should be_true
    body.to_json.should_not contain("fixture-secret")
    config.to_json.should_not contain("fixture-secret")
  ensure
    stub.try(&.close)
  end

  it "performs only the selected-buffer function tool round and returns the owner result" do
    seen_bodies = Channel(String).new(4)
    body_calls = Atomic(Int32).new(0)
    tool_chunk_one = {
      "choices" => [{
        "index" => 0,
        "delta" => {"content" => "Checking the selected buffer.", "tool_calls" => [{
          "index"    => 0,
          "id"       => "call_1",
          "type"     => "function",
          "function" => {"name" => "editor_", "arguments" => "{\"buffer_id\":\"buf-1\","},
        }]},
        "finish_reason" => nil,
      }],
    }.to_json
    tool_chunk_two = {
      "choices" => [{
        "index" => 0,
        "delta" => {"tool_calls" => [{
          "index"    => 0,
          "function" => {"name" => "read_buffer", "arguments" => "\"revision\":\"rev-1\",\"start_line\":1,\"line_count\":20,\"start_column\":1,\"max_columns\":120}"},
        }]},
        "finish_reason" => nil,
      }],
    }.to_json
    tool_chunk_finish = {"choices" => [{"index" => 0, "delta" => {} of String => String, "finish_reason" => "tool_calls"}]}.to_json
    stub = ChatProviderStub.new do |context, body|
      seen_bodies.send(body)
      body_calls.add(1)
      context.response.status_code = 200
      context.response.headers["Content-Type"] = "text/event-stream"
      if body_calls.get == 1
        context.response.print(
          "data: #{tool_chunk_one}\n\n" +
          "data: #{tool_chunk_two}\n\n" +
          "data: #{tool_chunk_finish}\n\n" +
          "data: [DONE]\n\n"
        )
      else
        context.response.print(chat_provider_text_stream("read completed"))
      end
    end
    config = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      endpoint: stub.endpoint,
      model: "local-compatible-model",
      key_env: "",
      reasoning_effort: "none"
    )
    transport = Adamantine::Chat::ProviderTransport.new(config)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools,
      "Active buffer tools",
      "",
      "buf-1",
      "rev-1"
    )
    events = Channel(Adamantine::Chat::Event).new(8)
    handle = transport.start(Adamantine::Chat::Request.new(2_u64, "read the current function", context), chat_provider_callback(events))

    streamed = receive_chat_provider_event(events)
    streamed.kind.should eq(Adamantine::Chat::Event::Kind::Delta)
    streamed.text.should eq("Checking the selected buffer.")
    tool = begin
      receive_chat_provider_event(events)
    rescue
      raise "provider event timed out after #{stub.request_count} observed requests and #{body_calls.get} body callbacks"
    end
    tool.kind.should eq(Adamantine::Chat::Event::Kind::ToolRequest)
    tool.call_id.should eq("call_1")
    envelope = JSON.parse(tool.request_json.not_nil!)
    envelope["name"].as_s.should eq("editor.read_buffer")
    envelope["arguments"]["buffer_id"].as_s.should eq("buf-1")
    envelope["arguments"]["revision"].as_s.should eq("rev-1")
    handle.deliver_tool_result("call_1", %({"status":"ok","data":{"text":"selected text"}}))
    remaining = read_chat_provider_terminal(events)
    remaining.map(&.kind).should eq([Adamantine::Chat::Event::Kind::Delta, Adamantine::Chat::Event::Kind::Complete])
    remaining.first.text.should eq("read completed")

    first = JSON.parse(receive_chat_provider_body(seen_bodies))
    first["tools"].as_a.size.should eq(1)
    first["tools"][0]["function"]["name"].as_s.should eq("editor_read_buffer")
    first["messages"].as_a.last["content"].as_s.should contain("buf-1")
    first["messages"].as_a.last["content"].as_s.should contain("approved read scope): buffer ID buf-1, revision rev-1")
    first["reasoning_effort"].as_s.should eq("none")
    second = JSON.parse(receive_chat_provider_body(seen_bodies))
    second["reasoning_effort"].as_s.should eq("none")
    second["messages"].as_a.any? { |message| message["role"].as_s? == "tool" && message["tool_call_id"].as_s? == "call_1" }.should be_true
    assistant_tool_message = second["messages"].as_a.find do |message|
      message["role"].as_s? == "assistant" && message["tool_calls"]?
    end
    assistant_tool_message.not_nil!["content"].as_s.should eq("Checking the selected buffer.")
  ensure
    handle.try(&.cancel)
    stub.try(&.close)
  end

  it "advertises and dispatches only read plus staged proposal tools for BufferProposals" do
    seen_bodies = Channel(String).new(4)
    body_calls = Atomic(Int32).new(0)
    proposal_arguments = {
      "buffer_id" => "buf-1",
      "revision"  => "rev-1",
      "edits"     => [{
        "start_line"   => 1,
        "start_column" => 0,
        "end_line"     => 1,
        "end_column"   => 1,
        "new_text"     => "x",
      }],
    }.to_json
    stub = ChatProviderStub.new do |context, body|
      seen_bodies.send(body)
      body_calls.add(1)
      context.response.status_code = 200
      context.response.headers["Content-Type"] = "text/event-stream"
      if body_calls.get == 1
        context.response.print(chat_provider_tool_stream("proposal_1", "editor_propose_edits", proposal_arguments))
      else
        context.response.print(chat_provider_text_stream("Proposal staged for review."))
      end
    end
    config = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      endpoint: stub.endpoint,
      model: "explicit-local-model",
      key_env: ""
    )
    transport = Adamantine::Chat::ProviderTransport.new(config)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferProposals,
      "Selected buffer: read and propose edits",
      "",
      "buf-1",
      "rev-1"
    )
    events = Channel(Adamantine::Chat::Event).new(8)
    handle = transport.start(
      Adamantine::Chat::Request.new(31_u64, "suggest a one-character change", context),
      chat_provider_callback(events)
    )

    tool = receive_chat_provider_event(events)
    tool.kind.should eq(Adamantine::Chat::Event::Kind::ToolRequest)
    tool.call_id.should eq("proposal_1")
    envelope = JSON.parse(tool.request_json.not_nil!)
    envelope["name"].as_s.should eq("editor.propose_edits")
    envelope["arguments"].should eq(JSON.parse(proposal_arguments))
    tool.request_json.not_nil!.bytesize.should be <= Adamantine::EditorTools::MAX_REQUEST_BYTES

    handle.deliver_tool_result("proposal_1", %({"status":"ok","data":{"status":"pending_review","applied":false}}))
    terminal = receive_chat_provider_event(events)
    terminal.kind.should eq(Adamantine::Chat::Event::Kind::Delta)
    terminal.text.should eq("Proposal staged for review.")
    complete = receive_chat_provider_event(events)
    complete.kind.should eq(Adamantine::Chat::Event::Kind::Complete)

    first = JSON.parse(receive_chat_provider_body(seen_bodies))
    tools = first["tools"].as_a.map { |entry| entry["function"]["name"].as_s }
    tools.should eq(["editor_read_buffer", "editor_propose_edits"])
    first["messages"].as_a.last["content"].as_s.should contain("Selected buffer: read and propose edits")
    first.to_json.should_not contain("editor.list_buffers")
    first.to_json.should_not contain("editor.find_files")

    second = JSON.parse(receive_chat_provider_body(seen_bodies))
    assistant_tool = second["messages"].as_a.find do |message|
      message["role"].as_s? == "assistant" && message["tool_calls"]?
    end
    assistant_tool.not_nil!["tool_calls"][0]["function"]["name"].as_s.should eq("editor_propose_edits")
    tool_result = second["messages"].as_a.find do |message|
      message["role"].as_s? == "tool" && message["tool_call_id"].as_s? == "proposal_1"
    end
    tool_result.not_nil!["content"].as_s.should contain("pending_review")
    tool_result.not_nil!["content"].as_s.should contain("false")
    body_calls.get.should eq(2)
  ensure
    handle.try(&.cancel)
    stub.try(&.close)
  end

  it "advertises one no-argument approved-script tool and discloses metadata without source or paths" do
    seen_bodies = Channel(String).new(4)
    body_calls = Atomic(Int32).new(0)
    stub = ChatProviderStub.new do |context, body|
      seen_bodies.send(body)
      body_calls.add(1)
      context.response.status_code = 200
      context.response.headers["Content-Type"] = "text/event-stream"
      if body_calls.get == 1
        context.response.print(chat_provider_tool_stream("run_1", "run_approved_lua_script", "{}"))
      else
        context.response.print(chat_provider_text_stream("The reviewed script completed."))
      end
    end
    config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "explicit-local-model", key_env: "")
    transport = Adamantine::Chat::ProviderTransport.new(config)
    digest = "a" * 64
    grant = Adamantine::Chat::LuaScriptGrant.new("reviewed-id", "Review-safe script", digest,
      [Adamantine::EditorTools::Capability::ReadEditor])
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools, "Selected buffer", "", "buf-1", "rev-1", grant
    )
    events = Channel(Adamantine::Chat::Event).new(8)
    handle = transport.start(Adamantine::Chat::Request.new(32_u64, "run the approved script", context), chat_provider_callback(events))

    tool = receive_chat_provider_event(events)
    tool.kind.should eq(Adamantine::Chat::Event::Kind::ToolRequest)
    tool.call_id.should eq("run_1")
    envelope = JSON.parse(tool.request_json.not_nil!)
    envelope["name"].as_s.should eq("lua.run_script")
    envelope["arguments"]["script_id"].as_s.should eq("reviewed-id")

    first = JSON.parse(receive_chat_provider_body(seen_bodies))
    functions = first["tools"].as_a.map(&.["function"])
    functions.map { |function| function["name"].as_s }.should eq(["editor_read_buffer", "run_approved_lua_script"])
    run_tool = functions.last
    run_tool["parameters"]["type"].as_s.should eq("object")
    run_tool["parameters"]["properties"].as_h.should be_empty
    run_tool["parameters"]["required"].as_a.should be_empty
    run_tool["parameters"]["additionalProperties"].as_bool.should be_false
    run_tool["description"].as_s.should contain("reviewed-id")
    run_tool["description"].as_s.should contain("Review-safe script")
    run_tool["description"].as_s.should contain(digest)
    run_tool["description"].as_s.should contain("read_editor")
    first["messages"].as_a.last["content"].as_s.should contain("reviewed-id")
    first["messages"].as_a.last["content"].as_s.should contain("Review-safe script")
    first["messages"].as_a.last["content"].as_s.should contain(digest)
    first.to_json.should_not contain("/Users/")
    first.to_json.should_not contain("source bytes")
    first.to_json.should_not contain("function body")

    handle.deliver_tool_result("run_1", %({"status":"ok","data":{"stdout":"done"},"message":null}))
    terminal = read_chat_provider_terminal(events)
    terminal.map(&.kind).should eq([Adamantine::Chat::Event::Kind::Delta, Adamantine::Chat::Event::Kind::Complete])
    second = JSON.parse(receive_chat_provider_body(seen_bodies))
    tool_result = second["messages"].as_a.find do |message|
      message["role"].as_s? == "tool" && message["tool_call_id"].as_s? == "run_1"
    end
    tool_result.not_nil!["content"].as_s.should contain("done")
  ensure
    handle.try(&.cancel)
    stub.try(&.close)
  end

  it "does not follow redirects or include response bodies in errors" do
    requests = Atomic(Int32).new(0)
    stub = ChatProviderStub.new do |context, _body|
      requests.add(1)
      context.response.status_code = 302
      context.response.headers["Location"] = "/elsewhere"
      context.response.print("fixture-provider-secret")
    end
    config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "model", key_env: "")
    transport = Adamantine::Chat::ProviderTransport.new(config)
    events = Channel(Adamantine::Chat::Event).new(4)

    transport.start(Adamantine::Chat::Request.new(3_u64, "hello"), chat_provider_callback(events))
    failure = receive_chat_provider_event(events)
    failure.kind.should eq(Adamantine::Chat::Event::Kind::Failure)
    failure.text.not_nil!.should_not contain("fixture-provider-secret")
    requests.get.should eq(1)
  ensure
    stub.try(&.close)
  end

  it "rejects malformed or incomplete SSE rather than treating it as a completed turn" do
    stub = ChatProviderStub.new do |context, _body|
      context.response.status_code = 200
      context.response.headers["Content-Type"] = "text/event-stream"
      context.response.print("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n")
    end
    config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "model", key_env: "")
    transport = Adamantine::Chat::ProviderTransport.new(config)
    events = Channel(Adamantine::Chat::Event).new(4)

    transport.start(Adamantine::Chat::Request.new(4_u64, "hello"), chat_provider_callback(events))
    received = read_chat_provider_terminal(events)
    received.last.kind.should eq(Adamantine::Chat::Event::Kind::Failure)
    received.map(&.kind).should_not contain(Adamantine::Chat::Event::Kind::Complete)
  ensure
    stub.try(&.close)
  end

  it "rejects missing, header-unsafe, and oversized credentials before any HTTP request and releases startup state" do
    bad_keys = [nil, "bad\r\nX-Injected: yes", "k" * (Adamantine::Chat::ProviderTransport::MAX_KEY_BYTES + 1)] of String?
    bad_keys.each do |bad_key|
      stub = ChatProviderStub.new do |context, _body|
        context.response.status_code = 200
        context.response.headers["Content-Type"] = "text/event-stream"
        context.response.print(chat_provider_text_stream("unexpected"))
      end
      resolver = ->(_name : String) { bad_key }
      config = Adamantine::Chat::ProviderConfig.new(
        enabled: true,
        endpoint: stub.endpoint,
        model: "explicit-model",
        key_env: "CHAT_TEST_KEY"
      )
      transport = Adamantine::Chat::ProviderTransport.new(config, resolver)
      request = Adamantine::Chat::Request.new(5_u64, "hello")
      events = Channel(Adamantine::Chat::Event).new(4)
      2.times do
        failure = expect_raises(Adamantine::Chat::ProviderTransport::ProviderFailure) do
          transport.start(request, chat_provider_callback(events))
        end
        failure.message.should eq("Configured API key is missing or invalid; draft retained.")
        if value = bad_key
          failure.message.not_nil!.should_not contain(value)
        end
      end
      stub.request_count.should eq(0)
      expect_no_chat_provider_request(stub.requests)
      stub.close
    ensure
      stub.try(&.close)
    end
  end

  it "charges invalid and outside-context tool attempts without widening the provider allowlist" do
    context = chat_provider_buffer_context
    invalid_calls = [
      {chat_provider_tool_stream("call_unknown", "editor_list_workspace", chat_provider_read_arguments), "call_unknown", Adamantine::EditorTools::Status::InvalidRequest, "provider.invalid_tool"},
      {chat_provider_tool_stream("call_editor_alias", "editor.read_buffer", chat_provider_read_arguments), "call_editor_alias", Adamantine::EditorTools::Status::InvalidRequest, "provider.invalid_tool"},
      {chat_provider_tool_stream("call_lua_alias", "lua.run_script", {"script_id" => "script-1"}.to_json), "call_lua_alias", Adamantine::EditorTools::Status::InvalidRequest, "provider.invalid_tool"},
      {chat_provider_tool_stream("call_lua_args", "run_approved_lua_script", {"script_id" => "model-selected"}.to_json), "call_lua_args", Adamantine::EditorTools::Status::InvalidRequest, "lua.run_script"},
      {chat_provider_tool_stream("call_malformed", "editor_read_buffer", "{"), "call_malformed", Adamantine::EditorTools::Status::InvalidRequest, nil.as(String?)},
      {chat_provider_tool_stream("call_wrong_buffer", "editor_read_buffer", chat_provider_read_arguments("other-buffer", "rev-1")), "call_wrong_buffer", Adamantine::EditorTools::Status::Denied, "editor.read_buffer"},
      {chat_provider_tool_stream("call_wrong_revision", "editor_read_buffer", chat_provider_read_arguments("buf-1", "stale-revision")), "call_wrong_revision", Adamantine::EditorTools::Status::Denied, "editor.read_buffer"},
    ]

    invalid_calls.each do |fixture|
      stream, expected_id, expected_status, expected_name = fixture
      event = emitted_chat_provider_tool_request(stream, context)
      event.call_id.should eq(expected_id)
      if name = expected_name
        envelope = JSON.parse(event.request_json.not_nil!)
        envelope["name"].as_s.should eq(name)
      else
        event.request_json.should eq("{")
      end

      if expected_id == "call_lua_args"
        rejected_arguments = JSON.parse(event.request_json.not_nil!)["arguments"]
        rejected_arguments["unexpected_provider_arguments"].as_bool.should be_true
        rejected_arguments.as_h?.not_nil!.has_key?("script_id").should be_false
      end

      host = Adamantine::EditorTools::Host.new(ChatProviderScopeBackend.new,
        Adamantine::EditorTools::Limits.new(max_calls: 1))
      session = host.open_session(Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor])
      scope_guard : Proc(Adamantine::EditorTools::Request, Nil) = ->(request : Adamantine::EditorTools::Request) {
        if request.is_a?(Adamantine::EditorTools::ReadBufferRequest) &&
           context.buffer_id == request.buffer_id && context.revision == request.revision
          nil
        else
          raise Adamantine::EditorTools::Failure.new(Adamantine::EditorTools::Status::Denied,
            "buffer is outside the approved turn scope")
        end
      }
      result = session.invoke_json(event.request_json.not_nil!, expected_call_id: expected_id,
        request_guard: scope_guard)
      result.status.should eq(expected_status)
      exhausted = session.invoke_json(
        {"id" => "quota-probe", "name" => "editor.list_buffers", "arguments" => {} of String => JSON::Any}.to_json,
        expected_call_id: "quota-probe", request_guard: scope_guard
      )
      exhausted.status.should eq(Adamantine::EditorTools::Status::LimitExceeded)
    end

    # Even a structurally complete but unadvertised alias must not be mapped
    # directly to an internal tool by name.
    editor_alias = emitted_chat_provider_tool_request(
      chat_provider_tool_stream("call_alias", "editor.read_buffer", chat_provider_read_arguments), context)
    JSON.parse(editor_alias.request_json.not_nil!)["name"].as_s.should eq("provider.invalid_tool")
    lua_alias = emitted_chat_provider_tool_request(
      chat_provider_tool_stream("call_alias_lua", "lua.run_script", {"script_id" => "approved"}.to_json), context)
    JSON.parse(lua_alias.request_json.not_nil!)["name"].as_s.should eq("provider.invalid_tool")

    rejected_chat_provider_tool_turn(chat_provider_incomplete_tool_stream, context).should contain("incomplete tool call")

    duplicate_id = chat_provider_duplicate_tool_stream("call_duplicate", chat_provider_read_arguments)
    rejected_chat_provider_tool_turn(duplicate_id, context).should contain("repeated a tool-call ID")
  end

  it "enforces the per-event and aggregate response byte limits" do
    oversized_event = ":" + ("x" * Adamantine::Chat::ProviderTransport::MAX_SSE_EVENT_BYTES) + "\n\n"
    event_failure = failed_chat_provider_stream(oversized_event)
    event_failure.last.text.not_nil!.should contain("64 KiB event-size limit")

    oversized_stream = ":x\n\n" * ((Adamantine::Chat::ProviderTransport::MAX_STREAM_BYTES // 4) + 1)
    stream_failure = failed_chat_provider_stream(oversized_stream)
    stream_failure.last.text.not_nil!.should contain("total response-size limit")
  end

  it "retains partial text and treats provider output-limit and filter finishes as non-completions" do
    length_failure = failed_chat_provider_stream(chat_provider_text_stream("partial reply", "length"))
    length_failure.map(&.kind).should eq([Adamantine::Chat::Event::Kind::Delta, Adamantine::Chat::Event::Kind::Failure])
    length_failure.last.text.not_nil!.should contain("output-token limit")
    length_failure.last.text.not_nil!.should contain("partial reply is retained")

    filtered_failure = failed_chat_provider_stream(chat_provider_text_stream("filtered", "content_filter"))
    filtered_failure.map(&.kind).should eq([Adamantine::Chat::Event::Kind::Delta, Adamantine::Chat::Event::Kind::Failure])
    filtered_failure.last.text.not_nil!.should contain("filtered the reply")
  end

  it "wakes promptly when the owner returns malformed or oversized tool results" do
    invalid_results = ["not-json", "x" * (Adamantine::Chat::ProviderTransport::MAX_TOOL_RESULT_BYTES + 1)]
    invalid_results.each do |invalid_result|
      stub = ChatProviderStub.new do |response, _body|
        response.response.status_code = 200
        response.response.headers["Content-Type"] = "text/event-stream"
        response.response.print(chat_provider_tool_stream("call_invalid_result", "editor_read_buffer", chat_provider_read_arguments))
      end
      config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "model", key_env: "")
      transport = Adamantine::Chat::ProviderTransport.new(config)
      events = Channel(Adamantine::Chat::Event).new(4)
      handle = transport.start(
        Adamantine::Chat::Request.new(6_u64, "read selected buffer", chat_provider_buffer_context),
        chat_provider_callback(events)
      )
      tool = receive_chat_provider_event(events)
      tool.kind.should eq(Adamantine::Chat::Event::Kind::ToolRequest)
      receive_chat_provider_request(stub.requests)
      handle.deliver_tool_result("call_invalid_result", invalid_result)
      terminal = read_chat_provider_terminal(events)
      terminal.last.kind.should eq(Adamantine::Chat::Event::Kind::Failure)
      terminal.last.text.not_nil!.should contain("invalid tool result")
      terminal.map(&.kind).should_not contain(Adamantine::Chat::Event::Kind::Complete)
      stub.request_count.should eq(1)
      expect_no_chat_provider_request(stub.requests)
    ensure
      handle.try(&.cancel)
      stub.try(&.close)
    end
  end

  it "cancels while waiting for a tool result, stays busy until cleanup, then releases for a new start" do
    stub = ChatProviderStub.new do |response, _body|
      response.response.status_code = 200
      response.response.headers["Content-Type"] = "text/event-stream"
      response.response.print(chat_provider_tool_stream("call_wait", "editor_read_buffer", chat_provider_read_arguments))
    end
    key_calls = Atomic(Int32).new(0)
    resolver = ->(_name : String) { key_calls.add(1); key_calls.get == 1 ? "fixture-secret" : nil }
    config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "model", key_env: "CHAT_TEST_KEY")
    transport = Adamantine::Chat::ProviderTransport.new(config, resolver)
    request = Adamantine::Chat::Request.new(7_u64, "read selected buffer", chat_provider_buffer_context)
    events = Channel(Adamantine::Chat::Event).new(8)
    handle = transport.start(request, chat_provider_callback(events))
    tool = receive_chat_provider_event(events)
    tool.kind.should eq(Adamantine::Chat::Event::Kind::ToolRequest)
    receive_chat_provider_request(stub.requests)

    busy = expect_raises(Adamantine::Chat::ProviderTransport::ProviderFailure) do
      transport.start(request, chat_provider_callback(events))
    end
    busy.message.should eq("A previous chat request is still shutting down.")
    key_calls.get.should eq(1)
    handle.cancel
    await_chat_provider_cleanup(transport, request, chat_provider_callback(events))
    stub.request_count.should eq(1)
    expect_no_chat_provider_request(stub.requests)
    expect_no_chat_provider_event(events)
    key_calls.get.should eq(2)
  ensure
    handle.try(&.cancel)
    stub.try(&.close)
  end

  it "cancels an in-flight socket read without retrying or starting a later round" do
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    stub = ChatProviderStub.new do |response, _body|
      entered.send(nil)
      release.receive
      begin
        response.response.status_code = 200
        response.response.headers["Content-Type"] = "text/event-stream"
        response.response.print(chat_provider_text_stream("too late"))
      rescue IO::Error
      end
    end
    key_calls = Atomic(Int32).new(0)
    resolver = ->(_name : String) { key_calls.add(1); key_calls.get == 1 ? "fixture-secret" : nil }
    config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "model", key_env: "CHAT_TEST_KEY")
    transport = Adamantine::Chat::ProviderTransport.new(config, resolver)
    request = Adamantine::Chat::Request.new(8_u64, "wait for a response")
    events = Channel(Adamantine::Chat::Event).new(8)
    handle = transport.start(request, chat_provider_callback(events))
    select
    when entered.receive
    when timeout(5.seconds)
      raise "stub did not enter its blocked response"
    end
    receive_chat_provider_request(stub.requests)
    busy = expect_raises(Adamantine::Chat::ProviderTransport::ProviderFailure) do
      transport.start(request, chat_provider_callback(events))
    end
    busy.message.should eq("A previous chat request is still shutting down.")
    key_calls.get.should eq(1)
    handle.cancel
    await_chat_provider_cleanup(transport, request, chat_provider_callback(events))
    release.send(nil)
    stub.request_count.should eq(1)
    expect_no_chat_provider_request(stub.requests)
    expect_no_chat_provider_event(events)
  ensure
    release.try { |channel| release_chat_provider_fixture(channel) }
    handle.try(&.cancel)
    stub.try(&.close)
  end

  it "returns on [DONE] while the peer remains open and closes the provider round locally" do
    body_sent = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    stub = ChatProviderStub.new do |response, _body|
      response.response.status_code = 200
      response.response.headers["Content-Type"] = "text/event-stream"
      response.response.print(chat_provider_text_stream("done before EOF"))
      response.response.flush
      body_sent.send(nil)
      release.receive
    end
    config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "model", key_env: "")
    transport = Adamantine::Chat::ProviderTransport.new(config)
    events = Channel(Adamantine::Chat::Event).new(4)
    handle = transport.start(Adamantine::Chat::Request.new(9_u64, "finish on done"), chat_provider_callback(events))
    select
    when body_sent.receive
    when timeout(5.seconds)
      raise "stub did not flush its still-open response"
    end
    received = read_chat_provider_terminal(events)
    received.map(&.kind).should eq([Adamantine::Chat::Event::Kind::Delta, Adamantine::Chat::Event::Kind::Complete])
    received.first.text.should eq("done before EOF")
    stub.request_count.should eq(1)
  ensure
    release.try { |channel| release_chat_provider_fixture(channel) }
    handle.try(&.cancel)
    stub.try(&.close)
  end

  it "caps the turn at four HTTP rounds even when every response asks for another tool" do
    rounds = Atomic(Int32).new(0)
    stub = ChatProviderStub.new do |response, _body|
      round = rounds.add(1) + 1
      response.response.status_code = 200
      response.response.headers["Content-Type"] = "text/event-stream"
      response.response.print(chat_provider_tool_stream("call_#{round}", "editor_read_buffer", chat_provider_read_arguments))
    end
    config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "model", key_env: "")
    transport = Adamantine::Chat::ProviderTransport.new(config)
    events = Channel(Adamantine::Chat::Event).new(8)
    handle = transport.start(
      Adamantine::Chat::Request.new(10_u64, "read this buffer", chat_provider_buffer_context),
      chat_provider_callback(events)
    )
    1.upto(3) do |round|
      tool = receive_chat_provider_event(events)
      tool.kind.should eq(Adamantine::Chat::Event::Kind::ToolRequest)
      tool.call_id.should eq("call_#{round}")
      handle.deliver_tool_result(tool.call_id.not_nil!, %({"status":"ok","data":{}}))
    end
    failure = receive_chat_provider_event(events)
    failure.kind.should eq(Adamantine::Chat::Event::Kind::Failure)
    failure.text.not_nil!.should contain("four-request turn limit")
    stub.request_count.should eq(4)
    rounds.get.should eq(4)
    4.times { receive_chat_provider_request(stub.requests) }
    expect_no_chat_provider_request(stub.requests)
    expect_no_chat_provider_event(events)
  ensure
    handle.try(&.cancel)
    stub.try(&.close)
  end

  it "enforces the absolute deadline against steady sub-idle-timeout stream trickles" do
    release = Channel(Nil).new(1)
    stub = ChatProviderStub.new do |response, _body|
      response.response.status_code = 200
      response.response.headers["Content-Type"] = "text/event-stream"
      loop do
        select
        when release.receive
          break
        when timeout(25.milliseconds)
          begin
            response.response.print(": keepalive\n\n")
            response.response.flush
          rescue IO::Error
            break
          end
        end
      end
    end
    config = Adamantine::Chat::ProviderConfig.new(enabled: true, endpoint: stub.endpoint, model: "model", key_env: "")
    transport = ChatProviderQuickTimeoutTransport.new(config)
    events = Channel(Adamantine::Chat::Event).new(4)
    handle = transport.start(Adamantine::Chat::Request.new(11_u64, "wait for a slow stream"), chat_provider_callback(events))
    started_at = Time.instant
    received = read_chat_provider_terminal(events)
    elapsed = Time.instant - started_at
    received.last.kind.should eq(Adamantine::Chat::Event::Kind::Failure)
    received.last.text.not_nil!.should contain("exceeded its 120-second limit")
    received.map(&.kind).should_not contain(Adamantine::Chat::Event::Kind::Complete)
    (elapsed < 2.seconds).should be_true
    stub.request_count.should eq(1)
  ensure
    release.try { |channel| release_chat_provider_fixture(channel) }
    handle.try(&.cancel)
    stub.try(&.close)
  end
end
