require "json"
require "spec"
require "file_utils"

require "../src/adamantine/dap/client"

private DAP_FAKE_ADAPTER = Path.new(Dir.current, "spec/fixtures/debugger/dap_scripted_adapter.rb")

private def with_dap_transport_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-dap-transport-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def dap_json(value : Hash(String, JSON::Any)) : JSON::Any
  JSON::Any.new(value)
end

private def wait_for_dap_result(client : Adamantine::Dap::Client, ticket : Adamantine::Dap::Ticket,
                                timeout_span : Time::Span = 2.seconds) : Adamantine::Dap::RequestResult
  deadline = Time.instant + timeout_span
  loop do
    if result = client.poll_result(ticket)
      return result
    end
    raise "timed out waiting for DAP result; failure=#{client.failure_message.inspect}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def wait_for_dap_failure(client : Adamantine::Dap::Client, timeout_span : Time::Span = 2.seconds) : String
  deadline = Time.instant + timeout_span
  loop do
    if message = client.failure_message
      return message
    end
    raise "timed out waiting for DAP transport failure" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def wait_for_dap_retirement(client : Adamantine::Dap::Client,
                                    timeout_span : Time::Span = 4.seconds) : Nil
  deadline = Time.instant + timeout_span
  until client.retired?
    raise "owned DAP actors did not retire; pid=#{client.owned_adapter_pid.inspect} alive=#{client.owned_adapter_alive?}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private class DapPartialReadNotObserved < Exception
  getter result : Adamantine::Dap::RequestResult?

  def initialize(message : String, @result : Adamantine::Dap::RequestResult? = nil)
    super(message)
  end
end

private def require_dap_partial_observation!(observed_bytes : Int64, expected_bytes : Int64,
                                             waiting_marker_present : Bool) : Nil
  return if waiting_marker_present && observed_bytes == expected_bytes

  raise DapPartialReadNotObserved.new(
    "fragmentation evidence was not observed: expected=#{expected_bytes} observed=#{observed_bytes} " +
    "fixture_waiting=#{waiting_marker_present}"
  )
end

private def wait_for_dap_partial_read(client : Adamantine::Dap::Client,
                                      ticket : Adamantine::Dap::Ticket, waiting_marker : Path,
                                      expected_bytes : Int64, timeout_span : Time::Span = 2.seconds) : Nil
  deadline = Time.instant + timeout_span
  loop do
    if result = client.poll_result(ticket)
      raise DapPartialReadNotObserved.new(
        "request completed before exact partial read: expected=#{expected_bytes} status=#{result.status}", result
      )
    end

    snapshot = client.resource_snapshot
    observed_bytes = snapshot.inbound_wire_bytes
    waiting = File.exists?(waiting_marker.to_s)

    if waiting && observed_bytes >= expected_bytes
      require_dap_partial_observation!(observed_bytes, expected_bytes, waiting)
      return
    end

    if Time.instant >= deadline
      raise DapPartialReadNotObserved.new(
        "timed out waiting for exact partial read: expected=#{expected_bytes} observed=#{observed_bytes} " +
        "fixture_waiting=#{waiting} failure=#{bounded_diagnostic_text(client.failure_message)}"
      )
    end
    sleep 1.millisecond
  end
end

private def publish_dap_fragment_ack(ack_marker : Path) : Nil
  temporary_marker = Path.new("#{ack_marker}.tmp")
  File.write(temporary_marker, "ack\n")
  File.rename(temporary_marker.to_s, ack_marker.to_s)
ensure
  File.delete(temporary_marker.to_s) if temporary_marker && File.exists?(temporary_marker.to_s)
end

private def dap_fragment_marker(directory : Path, kind : String, sequence : Int32, offset : Int32) : Path
  directory / "#{kind}-#{sequence}-#{offset}"
end

private def bounded_fixture_log(path : Path, max_bytes : Int32 = 4096) : String
  return "<missing>" unless File.exists?(path)

  contents = File.read(path)
  return contents if contents.bytesize <= max_bytes

  "#{contents.byte_slice(0, max_bytes)}<truncated>"
rescue ex
  "<unavailable: #{ex.class}>"
end

private def bounded_diagnostic_text(value : String?, max_bytes : Int32 = 512) : String
  return "nil" unless value
  return value.inspect if value.bytesize <= max_bytes

  prefix = value.byte_slice(0, max_bytes) || ""
  until prefix.valid_encoding?
    prefix = prefix.byte_slice(0, prefix.bytesize - 1) || ""
  end
  "#{prefix}<truncated>".inspect
end

private def require_dap_success(client : Adamantine::Dap::Client,
                                ticket : Adamantine::Dap::Ticket,
                                phase : String,
                                request_log : Path,
                                fragment_trace : Path? = nil) : Adamantine::Dap::RequestResult
  result = wait_for_dap_result(client, ticket)
  return result if result.success?

  response = result.response.try do |message|
    "seq=#{message.sequence} kind=#{message.kind.inspect} command=#{bounded_diagnostic_text(message.command, 128)} " +
      "request_seq=#{message.request_sequence.inspect} success=#{message.success.inspect}"
  end || "<none>"
  snapshot = client.resource_snapshot
  trace = fragment_trace.try { |path| bounded_fixture_log(path) } || "<not configured>"

  raise "#{phase} DAP result failed: status=#{result.status} message=#{bounded_diagnostic_text(result.message)} " +
        "failure=#{bounded_diagnostic_text(client.failure_message)} response=#{response} " +
        "resources={inbound_wire_bytes=#{snapshot.inbound_wire_bytes},decoded_queue_items=#{snapshot.decoded_queue_items}," +
        "decoded_queue_bytes=#{snapshot.decoded_queue_bytes},writer_queue_bytes=#{snapshot.writer_queue_bytes}," +
        "writer_queue_frames=#{snapshot.writer_queue_frames},active_writer_io_tasks=#{snapshot.active_writer_io_tasks}} " +
        "adapter_requests=#{bounded_fixture_log(request_log).inspect} fragment_trace=#{trace.inspect}"
end

private def new_scripted_dap_client(tmp : Path, mode : String, args : Array(String) = [] of String,
                                    limits : Adamantine::Dap::Limits = Adamantine::Dap::Limits.new) : Adamantine::Dap::Client
  log = tmp / "adapter-requests.jsonl"
  argv = ["ruby", DAP_FAKE_ADAPTER.to_s, mode, log.to_s]
  argv.concat(args)
  Adamantine::Dap::Client.new(argv, tmp, limits)
end

describe "DAP transport adversaries" do
  it "correlates independent requests when the adapter replies in reverse order" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "reorder")
      begin
        client.start
        initialized = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialized).success?.should be_true

        first = client.request("probe", dap_json({"label" => JSON::Any.new("first")}))
        second = client.request("probe", dap_json({"label" => JSON::Any.new("second")}))
        wait_for_dap_result(client, first).body.not_nil!["label"].as_s.should eq("first")
        wait_for_dap_result(client, second).body.not_nil!["label"].as_s.should eq("second")
        client.failure_message.should be_nil
      ensure
        client.close
      end
    end
  end

  it "serializes concurrent ordinary requests and reverse-request replies on one client sequence" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "concurrent_reverse")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true

        tickets = Channel(Adamantine::Dap::Ticket).new(12)
        12.times do |index|
          spawn do
            tickets.send(client.request("probe", dap_json({"label" => JSON::Any.new(index.to_s)})))
          end
        end
        pending = Array(Adamantine::Dap::Ticket).new(12) { tickets.receive }
        pending.each { |ticket| wait_for_dap_result(client, ticket).success?.should be_true }

        deadline = Time.instant + 1.second
        messages = [] of JSON::Any
        log = tmp / "adapter-requests.jsonl"
        loop do
          messages = File.read(log).lines.compact_map { |line| JSON.parse(line) rescue nil }
          break if messages.any? { |message| message["type"].as_s? == "response" }
          raise "adapter did not record its reverse-request response" if Time.instant >= deadline
          sleep 5.milliseconds
        end
        client_sequences = messages.map { |message| message["seq"].as_i }
        client_sequences.should eq(client_sequences.sort)
        messages.count { |message| message["type"].as_s? == "response" }.should eq(1)
        client.failure_message.should be_nil
      ensure
        client.close
      end
    end
  end

  it "requires initialize success before launch and delivers initialized while launch awaits configuration" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "init_launch")
      begin
        client.start
        expect_raises(Adamantine::Dap::ClientError) { client.request("launch", dap_json({"program" => JSON::Any.new("fixture")})) }

        initialize_ticket = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize_ticket).success?.should be_true
        launch = client.request("launch", dap_json({"program" => JSON::Any.new("fixture")}))
        deadline = Time.instant + 1.second
        events = [] of Adamantine::Dap::Message
        until events.any? { |event| event.event == "initialized" }
          events.concat(client.poll_events(8))
          raise "initialized event not delivered during pending launch" if Time.instant >= deadline
          sleep 5.milliseconds
        end
        client.poll_result(launch).should be_nil

        configuration = client.request("configurationDone")
        wait_for_dap_result(client, configuration).success?.should be_true
        wait_for_dap_result(client, launch).success?.should be_true
      ensure
        client.close
      end
    end
  end

  it "does not advertise terminal, shell, memory-reference or unimplemented child capabilities" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "basic")
      begin
        client.start
        ticket = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, ticket).success?.should be_true
        deadline = Time.instant + 1.second
        requests = [] of JSON::Any
        log = tmp / "adapter-requests.jsonl"
        until File.exists?(log.to_s) && !requests.empty?
          if File.exists?(log.to_s)
            requests = File.read(log.to_s).lines.compact_map { |line| JSON.parse(line) rescue nil }
          end
          raise "adapter did not observe initialize" if Time.instant >= deadline
          sleep 5.milliseconds
        end
        initialize_args = requests.first["arguments"]
        forbidden = ["supportsRunInTerminalRequest", "supportsMemoryReferences", "supportsStartDebuggingRequest", "supportsANSIStyling", "supportsVariablePaging"]
        forbidden.each do |key|
          initialize_args[key]?.should be_nil
        end
      ensure
        client.close
      end
    end
  end

  it "rejects unsupported reverse requests promptly without running their arguments" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "reverse")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true
        probe = client.request("probe")
        result = wait_for_dap_result(client, probe)
        reverse = result.body.not_nil!["reverse_response"]
        reverse["type"].as_s.should eq("response")
        reverse["success"].as_bool.should be_false
        reverse["request_seq"].as_i.should eq(2)
        client.failure_message.should be_nil
      ensure
        client.close
      end
    end
  end

  it "consumes a matching late response after timeout without poisoning the next request" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "late", ["0.15"])
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true
        timed = client.request("probe", nil, timeout: 30.milliseconds)
        wait_for_dap_result(client, timed).timed_out?.should be_true

        next_ticket = client.request("probe", dap_json({"label" => JSON::Any.new("after-late")}))
        wait_for_dap_result(client, next_ticket).body.not_nil!["label"].as_s.should eq("after-late")
        client.failure_message.should be_nil
      ensure
        client.close
      end
    end
  end

  it "fails visibly instead of dropping a saturated critical event queue" do
    with_dap_transport_workspace do |tmp|
      limits = Adamantine::Dap::Limits.new(max_decoded_queue_items: 2)
      client = new_scripted_dap_client(tmp, "flood", ["3"], limits: limits)
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true
        _probe = client.request("probe")
        failure = wait_for_dap_failure(client)
        failure.should contain("queue")
      ensure
        client.close
      end
    end
  end

  it "retires pending work and reaps only its adapter on EOF" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "eof")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true
        pending = client.request("probe")
        wait_for_dap_result(client, pending).status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        wait_for_dap_failure(client).should contain("EOF")
      ensure
        client.close
      end
    end
  end

  it "binds tickets to client identity and returns independent identity snapshots" do
    with_dap_transport_workspace do |tmp|
      first = new_scripted_dap_client(tmp / "first", "basic")
      second = new_scripted_dap_client(tmp / "second", "basic")
      Dir.mkdir_p(tmp / "first")
      Dir.mkdir_p(tmp / "second")
      begin
        first.start
        second.start
        first_id = first.session_id
        first_id.should eq(first.session_id)

        first_ticket = first.initialize_adapter("test-client", "scripted")
        second_ticket = second.initialize_adapter("test-client", "scripted")
        first_ticket.sequence.should eq(second_ticket.sequence)
        second_ticket.session_id.should eq(second.session_id)

        expect_raises(Adamantine::Dap::ClientError) { first.poll_result(second_ticket) }
        wait_for_dap_result(first, first_ticket).success?.should be_true
        wait_for_dap_result(second, second_ticket).success?.should be_true
      ensure
        first.close
        second.close
      end
    end
  end

  it "rejects execution requests through the generic request path" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "basic")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true

        expect_raises(Adamantine::Dap::ClientError) { client.request("next") }
        step = client.request_execution("next")
        wait_for_dap_result(client, step).success?.should be_true
      ensure
        client.close
      end
    end
  end

  it "rejects a mismatched response command without consuming the live ticket" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "wrong_command")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true
        ticket = client.request("probe")
        wait_for_dap_failure(client).should eq("DAP response command does not match its request")
        result = wait_for_dap_result(client, ticket)
        result.status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        result.message.should eq("DAP transport failed; target exit is unknown")
      ensure
        client.close
      end
    end
  end

  it "automatically closes and reaps the owned adapter after semantic protocol failure" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "wrong_command_hang")
      client.start
      initialize = client.initialize_adapter("test-client", "scripted")
      wait_for_dap_result(client, initialize).success?.should be_true
      ticket = client.request("probe")
      wait_for_dap_failure(client).should eq("DAP response command does not match its request")
      wait_for_dap_result(client, ticket).status.should eq(Adamantine::Dap::ResultStatus::TransportError)

      # This is the evidence: no caller close/ensure has run before these checks.
      wait_for_dap_retirement(client)
      client.owned_adapter_alive?.should be_false
      client.retired?.should be_true
      client.close
    end
  end

  it "retires partial headers and bodies on the frame completion deadline" do
    {"partial_header", "partial_body"}.each do |mode|
      with_dap_transport_workspace do |tmp|
        limits = Adamantine::Dap::Limits.new(incomplete_frame_timeout: 120.milliseconds)
        client = new_scripted_dap_client(tmp, mode, limits: limits)
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_failure(client).should eq("DAP incomplete frame completion deadline exceeded")
        wait_for_dap_result(client, initialize).status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        wait_for_dap_retirement(client)
        client.owned_adapter_alive?.should be_false
        client.resource_snapshot.inbound_wire_bytes.should eq(0)
        client.close
      end
    end
  end

  it "allows idle output silence beyond the incomplete-frame deadline" do
    with_dap_transport_workspace do |tmp|
      limits = Adamantine::Dap::Limits.new(incomplete_frame_timeout: 160.milliseconds)
      idle = new_scripted_dap_client(tmp / "idle", "idle", limits: limits)
      Dir.mkdir_p(tmp / "idle")
      begin
        idle.start
        ticket = idle.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(idle, ticket).success?.should be_true
        sleep 220.milliseconds
        idle.failure_message.should be_nil
      ensure
        idle.close
      end
    end
  end

  it "observes exact partial reads before releasing valid fragmented frames" do
    with_dap_transport_workspace do |tmp|
      fragmented_dir = tmp / "fragmented"
      ack_dir = fragmented_dir / "fragment-acks"
      Dir.mkdir_p(fragmented_dir)
      Dir.mkdir_p(ack_dir)
      request_log = fragmented_dir / "adapter-requests.jsonl"
      fragment_trace = fragmented_dir / "fragmented-write-trace.jsonl"
      fragmented = new_scripted_dap_client(fragmented_dir, "fragmented", [fragment_trace.to_s, ack_dir.to_s])
      begin
        fragmented.start
        ticket = fragmented.initialize_adapter("test-client", "scripted")
        {1, 8, 27, 29, 40}.each do |offset|
          waiting = dap_fragment_marker(ack_dir, "waiting", 1, offset)
          ack = dap_fragment_marker(ack_dir, "ack", 1, offset)
          wait_for_dap_partial_read(fragmented, ticket, waiting, offset.to_i64)
          publish_dap_fragment_ack(ack)
        end
        require_dap_success(fragmented, ticket, "fragmented initialize", request_log, fragment_trace).success?.should be_true

        probe = fragmented.request("probe")
        {1, 8, 27, 29, 40}.each do |offset|
          waiting = dap_fragment_marker(ack_dir, "waiting", 2, offset)
          ack = dap_fragment_marker(ack_dir, "ack", 2, offset)
          wait_for_dap_partial_read(fragmented, probe, waiting, offset.to_i64)
          publish_dap_fragment_ack(ack)
        end
        require_dap_success(fragmented, probe, "fragmented probe", request_log, fragment_trace).success?.should be_true
        fragmented.failure_message.should be_nil
      ensure
        fragmented.close
      end
    end
  end

  it "rejects an unacknowledged fragmented response as fragmentation evidence" do
    with_dap_transport_workspace do |tmp|
      fragmented_dir = tmp / "unacknowledged"
      Dir.mkdir_p(fragmented_dir)
      trace = fragmented_dir / "unacknowledged-write-trace.jsonl"
      client = new_scripted_dap_client(fragmented_dir, "fragmented", [trace.to_s])
      begin
        client.start
        ticket = client.initialize_adapter("test-client", "scripted")
        waiting_marker = dap_fragment_marker(fragmented_dir, "waiting", 1, 1)
        File.exists?(waiting_marker.to_s).should be_false
        error = expect_raises(DapPartialReadNotObserved) do
          wait_for_dap_partial_read(client, ticket, waiting_marker, 1_i64)
        end
        result = error.result || wait_for_dap_result(client, ticket)
        result.success?.should be_true
      ensure
        client.close
      end
    end
  end

  it "rejects a coalesced response as fragmented-read evidence" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "basic")
      begin
        client.start
        ticket = client.initialize_adapter("test-client", "scripted")
        waiting_marker = dap_fragment_marker(tmp, "waiting", 1, 1)
        File.exists?(waiting_marker.to_s).should be_false
        error = expect_raises(DapPartialReadNotObserved) do
          wait_for_dap_partial_read(client, ticket, waiting_marker, 1_i64)
        end
        error.result.should_not be_nil
        error.result.not_nil!.success?.should be_true
      ensure
        client.close
      end
    end
  end

  it "does not clear the first initialize reservation when a duplicate is rejected" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "basic")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        expect_raises(Adamantine::Dap::ClientError) { client.initialize_adapter("other-client", "scripted") }
        expect_raises(ArgumentError) { client.initialize_adapter("", "scripted") }
        wait_for_dap_result(client, initialize).success?.should be_true
        launch = client.request("launch")
        wait_for_dap_result(client, launch).success?.should be_true
        expect_raises(Adamantine::Dap::ClientError) { client.initialize_adapter("test-client", "scripted") }

        messages = File.read(tmp / "adapter-requests.jsonl").lines.compact_map { |line| JSON.parse(line) rescue nil }
        messages.count { |message| message["command"].as_s? == "initialize" }.should eq(1)
        client.failure_message.should be_nil
      ensure
        client.close
      end
    end
  end

  it "rejects an unknown request sequence and retires the affected ticket as transport failure" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "unknown_response")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true
        ticket = client.request("probe")
        wait_for_dap_failure(client).should eq("DAP response has unknown or duplicate request_seq")
        result = wait_for_dap_result(client, ticket)
        result.status.should eq(Adamantine::Dap::ResultStatus::TransportError)
      ensure
        client.close
      end
    end
  end

  it "rejects invalid deadlines before creating a pending request" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "basic")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true
        expect_raises(ArgumentError) { client.request("probe", timeout: Time::Span.zero) }
        expect_raises(ArgumentError) { client.request("probe", timeout: 6.minutes) }
        client.request("probe").sequence.should eq(2)
      ensure
        client.close
      end
    end
  end

  it "does not consume the client sequence when local request encoding fails" do
    with_dap_transport_workspace do |tmp|
      limits = Adamantine::Dap::Limits.new(
        max_message_bytes: 4_096,
        max_aggregate_inbound_bytes: 4_096_i64,
        max_decoded_queue_bytes: 4_096_i64,
        max_writer_queue_bytes: 4_096_i64
      )
      client = new_scripted_dap_client(tmp, "basic", limits: limits)
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true

        oversized = dap_json({"payload" => JSON::Any.new("x" * 5_000)})
        expect_raises(Adamantine::Dap::ClientError) { client.request("probe", oversized) }
        valid = client.request("probe")
        valid.sequence.should eq(2)
        wait_for_dap_result(client, valid).success?.should be_true
        client.failure_message.should be_nil
      ensure
        client.close
      end
    end
  end

  it "resolves every expired ticket when the tombstone budget overflows" do
    with_dap_transport_workspace do |tmp|
      limits = Adamantine::Dap::Limits.new(max_timeout_tombstones: 1)
      client = new_scripted_dap_client(tmp, "hold", limits: limits)
      client.start
      initialize = client.initialize_adapter("test-client", "scripted")
      wait_for_dap_result(client, initialize).success?.should be_true
      first = client.request("probe", nil, timeout: 40.milliseconds)
      second = client.request("probe", nil, timeout: 40.milliseconds)

      wait_for_dap_failure(client).should eq("DAP timed-out response tracking budget exceeded")
      first_result = wait_for_dap_result(client, first)
      second_result = wait_for_dap_result(client, second)
      first_result.status.should eq(Adamantine::Dap::ResultStatus::TimedOut)
      second_result.status.should eq(Adamantine::Dap::ResultStatus::TransportError)
      client.poll_result(first).should be_nil
      client.poll_result(second).should be_nil

      wait_for_dap_retirement(client)
      client.owned_adapter_alive?.should be_false
      client.close
    end
  end

  it "does not treat a well-formed initialize rejection as success" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "init_reject")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        result = wait_for_dap_result(client, initialize)
        result.status.should eq(Adamantine::Dap::ResultStatus::AdapterError)
        result.message.should eq("fixture initialize rejection")
        expect_raises(Adamantine::Dap::ClientError) { client.request("launch") }
      ensure
        client.close
      end
    end
  end

  it "serializes start and close so close cannot leak a late adapter process" do
    with_dap_transport_workspace do |tmp|
      4.times do |index|
        work = tmp / "race-#{index}"
        Dir.mkdir_p(work)
        client = new_scripted_dap_client(work, "basic")
        started = Channel(Nil).new(1)
        start_error = nil.as(Exception?)
        spawn do
          begin
            client.start
          rescue ex
            start_error = ex
          ensure
            started.send(nil)
          end
        end
        client.close
        select
        when started.receive
        when timeout(5.seconds)
          fail "concurrent DAP start did not return"
        end
        start_error.should be_a(Adamantine::Dap::ClientError) if start_error
        wait_for_dap_retirement(client)
        client.owned_adapter_alive?.should be_false
      end
    end
  end

  it "resolves concurrent enqueue attempts during writer failure without orphaning tickets" do
    with_dap_transport_workspace do |tmp|
      client = new_scripted_dap_client(tmp, "close_stdin")
      begin
        client.start
        initialize = client.initialize_adapter("test-client", "scripted")
        wait_for_dap_result(client, initialize).success?.should be_true

        closed_marker = Path.new("#{tmp / "adapter-requests.jsonl"}.stdin-closed")
        marker_deadline = Time.instant + 1.second
        until File.exists?(closed_marker.to_s)
          raise "fixture did not confirm closed stdin before initialization completed" if Time.instant >= marker_deadline
          sleep 5.milliseconds
        end

        outcomes = Channel(Tuple(Adamantine::Dap::Ticket?, String?)).new(8)
        payload = dap_json({"blob" => JSON::Any.new("x" * (512 * 1024))})
        8.times do
          spawn do
            begin
              outcomes.send({client.request("probe", payload, timeout: 5.seconds), nil})
            rescue ex
              outcomes.send({nil, ex.class.to_s})
            end
          end
        end
        requests = Array(Tuple(Adamantine::Dap::Ticket?, String?)).new(8) { outcomes.receive }

        wait_for_dap_failure(client, Adamantine::Dap::Transport::WRITE_DEADLINE + 1.second)
          .should eq("DAP adapter stopped accepting protocol input")
        requests.each do |ticket, error|
          if ticket
            error.should be_nil
          else
            error.should eq("Adamantine::Dap::ClientError")
          end
        end
        accepted = requests.compact_map(&.[0])
        accepted.each do |ticket|
          wait_for_dap_result(client, ticket).status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        end
        accepted.size.should be > 0
        wait_for_dap_retirement(client)
        client.owned_adapter_alive?.should be_false
        snapshot = client.resource_snapshot
        snapshot.writer_queue_bytes.should eq(0)
        snapshot.writer_queue_frames.should eq(0)
        snapshot.active_writer_io_tasks.should eq(0)
      ensure
        client.close
      end
    end
  end
end
