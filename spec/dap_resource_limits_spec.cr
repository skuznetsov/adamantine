require "json"
require "spec"
require "file_utils"
require "random/secure"

require "../src/adamantine/dap/client"

private DAP_RESOURCE_ADAPTER           = Path.new(Dir.current, "spec/fixtures/debugger/dap_resource_adapter.rb")
private DAP_RESOURCE_LARGE_FRAME_BYTES = 15 * 1024 * 1024
private DAP_RESOURCE_NULL_ITEMS        = 247_500

private def with_dap_resource_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-dap-resource-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def new_dap_resource_client(tmp : Path, mode : String, args : Array(String) = [] of String,
                                    limits : Adamantine::Dap::Limits = Adamantine::Dap::Limits.new) : Adamantine::Dap::Client
  argv = ["ruby", DAP_RESOURCE_ADAPTER.to_s, mode]
  argv.concat(args)
  Adamantine::Dap::Client.new(argv, tmp, limits)
end

private def dap_resource_json(values : Hash(String, JSON::Any)) : JSON::Any
  JSON::Any.new(values)
end

private def wait_for_dap_resource_result(client : Adamantine::Dap::Client, ticket : Adamantine::Dap::Ticket,
                                         timeout_span : Time::Span = 8.seconds) : Adamantine::Dap::RequestResult
  deadline = Time.instant + timeout_span
  loop do
    if result = client.poll_result(ticket)
      return result
    end
    raise "timed out waiting for DAP resource result; failure=#{client.failure_message.inspect}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def wait_for_dap_resource_failure(client : Adamantine::Dap::Client,
                                          timeout_span : Time::Span = 8.seconds) : String
  deadline = Time.instant + timeout_span
  loop do
    if message = client.failure_message
      return message
    end
    raise "timed out waiting for DAP resource failure" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def wait_for_dap_resource_snapshot(client : Adamantine::Dap::Client,
                                           timeout_span : Time::Span = 5.seconds,
                                           &condition : Adamantine::Dap::ResourceSnapshot -> Bool) : Adamantine::Dap::ResourceSnapshot
  deadline = Time.instant + timeout_span
  loop do
    snapshot = client.resource_snapshot
    return snapshot if yield snapshot
    raise "timed out waiting for DAP resource state: #{snapshot}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def wait_for_dap_resource_retirement(client : Adamantine::Dap::Client,
                                             timeout_span : Time::Span = 5.seconds) : Nil
  deadline = Time.instant + timeout_span
  until client.retired?
    raise "DAP actors did not retire after close: #{client.resource_snapshot}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def initialize_dap_resource_client(client : Adamantine::Dap::Client) : Nil
  client.start
  ticket = client.initialize_adapter("resource-spec", "fixture")
  result = wait_for_dap_resource_result(client, ticket)
  raise "resource adapter initialize failed: status=#{result.status} message=#{result.message.inspect} transport=#{client.failure_message.inspect}" unless result.success?
end

private def assert_dap_resource_caps(snapshot : Adamantine::Dap::ResourceSnapshot,
                                     limits : Adamantine::Dap::Limits) : Nil
  snapshot.inbound_wire_bytes.should be <= limits.max_aggregate_inbound_bytes
  snapshot.decoded_queue_bytes.should be <= limits.max_decoded_queue_bytes
  snapshot.decoded_queue_items.should be <= limits.max_decoded_queue_items
  snapshot.writer_queue_bytes.should be <= limits.max_writer_queue_bytes
  snapshot.writer_queue_frames.should be <= limits.max_writer_queue_frames
end

describe "DAP transport resource limits" do
  it "admits two legal 15 MiB frames below the inbound cap and visibly rejects a burst beyond it" do
    with_dap_resource_workspace do |tmp|
      limits = Adamantine::Dap::Limits.new
      client = new_dap_resource_client(tmp, "wire_burst", [DAP_RESOURCE_LARGE_FRAME_BYTES.to_s], limits)
      begin
        initialize_dap_resource_client(client)

        below = client.request("probe", dap_resource_json({"count" => JSON::Any.new(2_i64)}))
        wait_for_dap_resource_result(client, below).success?.should be_true
        retained = client.resource_snapshot
        retained.inbound_wire_bytes.should be > 30_i64 * 1024 * 1024
        retained.inbound_wire_bytes.should be < limits.max_aggregate_inbound_bytes
        retained.decoded_queue_items.should eq(2)
        assert_dap_resource_caps(retained, limits)
        client.poll_events(2).size.should eq(2)
        released = client.resource_snapshot
        released.inbound_wire_bytes.should eq(0_i64)
        released.decoded_queue_items.should eq(0)
        released.decoded_queue_bytes.should eq(0_i64)

        over = client.request("probe", dap_resource_json({"count" => JSON::Any.new(3_i64)}))
        failure = wait_for_dap_resource_failure(client)
        failure.should contain("aggregate inbound byte budget exceeded")
        wait_for_dap_resource_result(client, over).status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        assert_dap_resource_caps(client.resource_snapshot, limits)
      ensure
        client.close
      end
    end
  end

  it "enforces decoded-byte credits independently of wire bytes and per-message token ceilings" do
    with_dap_resource_workspace do |tmp|
      limits = Adamantine::Dap::Limits.new
      client = new_dap_resource_client(tmp, "decoded_burst", [DAP_RESOURCE_NULL_ITEMS.to_s], limits)
      begin
        initialize_dap_resource_client(client)

        first_batch = client.request("probe", dap_resource_json({"batch" => JSON::Any.new("first")}))
        wait_for_dap_resource_result(client, first_batch).success?.should be_true
        retained = client.resource_snapshot
        retained.decoded_queue_items.should eq(16)
        retained.decoded_queue_bytes.should be > 60_i64 * 1024 * 1024
        retained.decoded_queue_bytes.should be < limits.max_decoded_queue_bytes
        retained.inbound_wire_bytes.should be < limits.max_aggregate_inbound_bytes
        assert_dap_resource_caps(retained, limits)

        overflow = client.request("probe", dap_resource_json({"batch" => JSON::Any.new("overflow")}))
        failure = wait_for_dap_resource_failure(client)
        failure.should contain("decoded queue byte budget exceeded")
        wait_for_dap_resource_result(client, overflow).status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        bounded = client.resource_snapshot
        bounded.inbound_wire_bytes.should be < limits.max_aggregate_inbound_bytes
        assert_dap_resource_caps(bounded, limits)
      ensure
        client.close
      end
    end
  end

  it "admits exactly the default decoded item budget and fails visibly rather than dropping events" do
    with_dap_resource_workspace do |tmp|
      limits = Adamantine::Dap::Limits.new
      client = new_dap_resource_client(tmp, "item_burst", [] of String, limits)
      begin
        initialize_dap_resource_client(client)

        first_batch = client.request("probe", dap_resource_json({"count" => JSON::Any.new(127_i64)}))
        wait_for_dap_resource_result(client, first_batch).success?.should be_true
        client.resource_snapshot.decoded_queue_items.should eq(127)
        retained_events = client.poll_events(64).concat(client.poll_events(63))
        retained_events.size.should eq(127)
        retained_events.all? { |event| event.event == "stopped" }.should be_true
        retained_events.map { |event| event.body.not_nil!["threadId"].as_i }.should eq((1_i64..127_i64).to_a)

        overflow = client.request("probe", dap_resource_json({
          "count" => JSON::Any.new(128_i64),
          "hold"  => JSON::Any.new(true),
        }))
        wait_for_dap_resource_snapshot(client) { |snapshot| snapshot.decoded_queue_items == 128 }
        release = client.request("releaseItem")
        failure = wait_for_dap_resource_failure(client)
        failure.should contain("decoded queue item budget exceeded")
        wait_for_dap_resource_result(client, overflow).status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        wait_for_dap_resource_result(client, release).status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        assert_dap_resource_caps(client.resource_snapshot, limits)
      ensure
        client.close
      end
    end
  end

  it "charges a fragmented in-progress frame before decode and releases it only after consumption" do
    with_dap_resource_workspace do |tmp|
      client = new_dap_resource_client(tmp, "partial")
      begin
        initialize_dap_resource_client(client)

        first = client.request("probe")
        partial = wait_for_dap_resource_snapshot(client) { |snapshot| snapshot.inbound_wire_bytes > 0 }
        partial.decoded_queue_items.should eq(0)
        partial.decoded_queue_bytes.should eq(0_i64)

        finish = client.request("finishPartial")
        wait_for_dap_resource_result(client, finish).success?.should be_true
        retained = client.resource_snapshot
        retained.inbound_wire_bytes.should be > partial.inbound_wire_bytes
        retained.decoded_queue_items.should eq(1)
        client.poll_events(1).size.should eq(1)
        released = client.resource_snapshot
        released.inbound_wire_bytes.should eq(0_i64)
        released.decoded_queue_items.should eq(0)
        released.decoded_queue_bytes.should eq(0_i64)
        client.failure_message.should be_nil
        client.poll_result(first).should be_nil
      ensure
        client.close
      end
    end
  end

  it "counts active and queued writer bytes, bounds blocked close, and reaps only its adapter" do
    with_dap_resource_workspace do |tmp|
      sentinel = Process.new(["ruby", "-e", "sleep 60"], chdir: tmp.to_s,
        input: Process::Redirect::Close, output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      limits = Adamantine::Dap::Limits.new(
        max_message_bytes: 256 * 1024,
        max_writer_queue_bytes: 440_i64 * 1024,
        max_writer_queue_frames: 8,
      )
      client = new_dap_resource_client(tmp, "no_read", [] of String, limits)
      begin
        initialize_dap_resource_client(client)
        payload = dap_resource_json({"payload" => JSON::Any.new("x" * (190 * 1024))})
        first = client.request("probe", payload)
        active = wait_for_dap_resource_snapshot(client) { |snapshot| snapshot.active_writer_io_tasks == 1 }
        second = client.request("probe", payload)
        queued = client.resource_snapshot
        queued.active_writer_io_tasks.should eq(1)
        queued.writer_queue_frames.should eq(2)
        queued.writer_queue_bytes.should be > active.writer_queue_bytes
        queued.writer_queue_bytes.should be <= limits.max_writer_queue_bytes
        assert_dap_resource_caps(queued, limits)
        expect_raises(Adamantine::Dap::ClientError) { client.request("probe", payload) }
        client.failure_message.not_nil!.should contain("writer queue budget exceeded")
        client.resource_snapshot.writer_queue_frames.should eq(2)

        owned_pid = client.owned_adapter_pid
        owned_pid.should_not be_nil
        client.owned_adapter_alive?.should be_true
        close_started = Time.instant
        client.close
        wait_for_dap_resource_retirement(client)
        (Time.instant - close_started).should be < 8.seconds
        client.retired?.should be_true
        client.owned_adapter_alive?.should be_false
        retired = client.resource_snapshot
        retired.writer_queue_bytes.should eq(0_i64)
        retired.writer_queue_frames.should eq(0)
        retired.active_writer_io_tasks.should eq(0)
        sentinel.exists?.should be_true
        client.poll_result(first).not_nil!.status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        client.poll_result(second).not_nil!.status.should eq(Adamantine::Dap::ResultStatus::TransportError)
      ensure
        client.close
        if sentinel.exists?
          sentinel.terminate(graceful: false)
          sentinel.wait
        end
      end
    end
  end

  it "applies the writer frame-count credit to the active frame as well as queued frames" do
    with_dap_resource_workspace do |tmp|
      limits = Adamantine::Dap::Limits.new(
        max_message_bytes: 256 * 1024,
        max_writer_queue_bytes: 1024_i64 * 1024,
        max_writer_queue_frames: 2,
      )
      client = new_dap_resource_client(tmp, "no_read", [] of String, limits)
      begin
        initialize_dap_resource_client(client)
        payload = dap_resource_json({"payload" => JSON::Any.new("x" * (190 * 1024))})
        first = client.request("probe", payload)
        wait_for_dap_resource_snapshot(client) { |snapshot| snapshot.active_writer_io_tasks == 1 }
        second = client.request("probe", payload)
        full = client.resource_snapshot
        full.writer_queue_frames.should eq(2)
        full.writer_queue_bytes.should be < limits.max_writer_queue_bytes
        assert_dap_resource_caps(full, limits)
        expect_raises(Adamantine::Dap::ClientError) { client.request("probe", payload) }
        client.failure_message.not_nil!.should contain("writer queue budget exceeded")
        client.resource_snapshot.writer_queue_frames.should eq(2)
        client.poll_result(first).not_nil!.status.should eq(Adamantine::Dap::ResultStatus::TransportError)
        client.poll_result(second).not_nil!.status.should eq(Adamantine::Dap::ResultStatus::TransportError)
      ensure
        client.close
      end
      wait_for_dap_resource_retirement(client)
      client.retired?.should be_true
      client.resource_snapshot.active_writer_io_tasks.should eq(0)
    end
  end
end
