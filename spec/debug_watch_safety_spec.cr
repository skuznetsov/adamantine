require "spec"
require "json"
require "file_utils"
require "random/secure"
require "../src/adamantine/debug_controller"

private def debugger_watch_root : Path
  root = Path.new(Dir.tempdir, "adamantine-debug-watch-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root.to_s)
  root
end

private def debugger_watch_profile(root : Path, adapter : Path,
                                   mode : String = "basic") : Adamantine::Debugging::LaunchProfile
  ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
  Adamantine::Debugging::LaunchProfile.new(
    id: "watch-fixture-profile",
    name: "Watch fixture",
    adapter_argv: [ruby, adapter.to_s, (root / "adapter.jsonl").to_s, mode],
    program: Process.find_executable("true") || "/usr/bin/true",
    cwd: File.realpath(root.to_s)
  )
end

private def await_debug_watch(controller : Adamantine::DebugController,
                              timeout : Time::Span = 5.seconds,
                              &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  latest = controller.poll
  until ready.call(latest)
    raise "debug controller did not reach the expected watch state before timeout" if Time.monotonic >= deadline
    sleep 5.milliseconds
    latest = controller.poll
  end
  latest
end

private def debugger_watch_requests(path : Path) : Array(Hash(String, JSON::Any))
  return [] of Hash(String, JSON::Any) unless File.file?(path.to_s)
  File.read_lines(path.to_s).map { |line| JSON.parse(line).as_h }
    .select { |record| record["type"]?.try(&.as_s?) == "request" }
end

private def debugger_watch_fixture_records(path : Path) : Array(Hash(String, JSON::Any))
  return [] of Hash(String, JSON::Any) unless File.file?(path.to_s)
  records = [] of Hash(String, JSON::Any)
  File.read_lines(path.to_s).each do |line|
    begin
      record = JSON.parse(line).as_h
      records << record if record["type"]?.try(&.as_s?) == "fixture"
    rescue
      # Ignore only an in-progress final log line while the peer is appending.
    end
  end
  records
end

private def await_debug_watch_fixture(controller : Adamantine::DebugController, path : Path,
                                      name : String, timeout : Time::Span = 5.seconds) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  latest = controller.poll
  until debugger_watch_fixture_records(path).any? { |record| record["name"]?.try(&.as_s?) == name }
    raise "debug adapter did not emit fixture marker #{name.inspect} before timeout" if Time.monotonic >= deadline
    sleep 5.milliseconds
    latest = controller.poll
  end
  latest
end

private def cleanup_debug_watch(controller : Adamantine::DebugController?, client : Adamantine::Dap::Client?, root : Path) : Nil
  if owner = controller
    owner.stop
    deadline = Time.monotonic + 5.seconds
    while (owner.cleanup_pending? || (client && !client.not_nil!.retired?)) && Time.monotonic < deadline
      owner.poll
      sleep 5.milliseconds
    end
    owner.close
  end
  if client_owner = client
    client_owner.close
    deadline = Time.monotonic + 3.seconds
    until client_owner.retired? || Time.monotonic >= deadline
      sleep 5.milliseconds
    end
    raise "watch fixture adapter was not retired" unless client_owner.retired?
  end
  FileUtils.rm_rf(root.to_s)
end

describe Adamantine::DebugController, "manual watch safety" do
  it "keeps adding, snapshotting, and selecting frames inert until explicit evaluation" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_watch_root
    client : Adamantine::Dap::Client? = nil
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      client = Adamantine::Dap::Client.new(argv, cwd)
    end
    controller = Adamantine::DebugController.new(factory)
    log_path = root / "adapter.jsonl"

    begin
      profile = debugger_watch_profile(root, adapter)
      review = controller.prepare_launch(profile, root)
      review.valid?.should be_true
      controller.snapshot.watches.should be_empty
      controller.start(review).accepted?.should be_true

      stopped = await_debug_watch(controller) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          view.state.execution == Adamantine::DebugSessionState::Execution::Stopped &&
          !view.frames.empty? && !view.state.selected_frame_id.nil?
      end
      frames = stopped.frames
      frames.size.should be >= 2

      controller.add_watch("  local_value  ").accepted?.should be_true
      watch = controller.snapshot.watches.last
      watch.expression.should eq("local_value")
      watch.status.should eq(Adamantine::DebugController::WatchStatus::NotEvaluated)
      watch.result.should be_nil

      controller.select_frame(frames.last.id).accepted?.should be_true
      selected_frame = controller.snapshot.state.selected_frame_id
      selected_frame.should eq(frames.last.id)
      5.times { controller.snapshot }
      debugger_watch_requests(log_path).any? { |request| request["command"]?.try(&.as_s?) == "evaluate" }.should be_false

      controller.evaluate_watch(watch.id).accepted?.should be_true
      evaluated = await_debug_watch(controller) do |view|
        candidate = view.watches.find { |item| item.id == watch.id }
        candidate.try(&.status) == Adamantine::DebugController::WatchStatus::Available
      end
      result = evaluated.watches.find { |item| item.id == watch.id }.not_nil!
      result.result.should eq("fixture-result:local_value")

      evaluate = debugger_watch_requests(log_path).find { |request| request["command"]?.try(&.as_s?) == "evaluate" }.not_nil!
      arguments = evaluate["arguments"].as_h
      arguments["expression"].as_s.should eq("local_value")
      arguments["frameId"].as_i64.should eq(frames.last.id)
      arguments["context"].as_s.should eq("watch")
    ensure
      cleanup_debug_watch(controller, client, root)
    end
  end

  it "does not attach an evaluation reply reduced only after resume to the new stop" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_watch_root
    client : Adamantine::Dap::Client? = nil
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      client = Adamantine::Dap::Client.new(argv, cwd)
    end
    controller = Adamantine::DebugController.new(factory)
    log_path = root / "adapter.jsonl"

    begin
      review = controller.prepare_launch(debugger_watch_profile(root, adapter, "hold_evaluate"), root)
      controller.start(review).accepted?.should be_true
      initial = await_debug_watch(controller) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          view.state.execution == Adamantine::DebugSessionState::Execution::Stopped &&
          !view.frames.empty? && !view.state.selected_frame_id.nil?
      end
      watch_submission = controller.add_watch("late_value")
      watch_submission.accepted?.should be_true
      watch = controller.snapshot.watches.last

      controller.evaluate_watch(watch.id).accepted?.should be_true
      await_debug_watch_fixture(controller, log_path, "evaluate_held")
      # The fixture withholds this response until after the next stopped event,
      # so the result is known to arrive with an old stop certificate.
      controller.step_over(initial.state.selected_thread_id).accepted?.should be_true
      next_stop = await_debug_watch(controller) do |view|
        view.state.execution == Adamantine::DebugSessionState::Execution::Stopped &&
          view.state.stop_epoch > initial.state.stop_epoch &&
          !view.frames.empty?
      end
      await_debug_watch_fixture(controller, log_path, "evaluate_release_written")
      controller.open_scopes.accepted?.should be_true
      final = await_debug_watch(controller) { |view| !view.variables.roots.empty? }

      next_stop.state.stop_epoch.should be > initial.state.stop_epoch
      stale = final.watches.find { |item| item.id == watch.id }.not_nil!
      stale.status.should_not eq(Adamantine::DebugController::WatchStatus::Available)
      stale.result.should_not eq("fixture-result:late_value")
      debugger_watch_requests(log_path).count { |request| request["command"]?.try(&.as_s?) == "evaluate" }.should eq(1)
    ensure
      cleanup_debug_watch(controller, client, root)
    end
  end

  ["hold_evaluate_success_after_second", "hold_evaluate_fail_after_second"].each do |mode|
    it "preserves a newer pending evaluation when an old #{mode.includes?("fail") ? "failure" : "success"} arrives" do
      adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
      root = debugger_watch_root
      client : Adamantine::Dap::Client? = nil
      factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
        client = Adamantine::Dap::Client.new(argv, cwd)
      end
      controller = Adamantine::DebugController.new(factory)
      log_path = root / "adapter.jsonl"

      begin
        review = controller.prepare_launch(debugger_watch_profile(root, adapter, mode), root)
        review.valid?.should be_true
        controller.start(review).accepted?.should be_true
        initial = await_debug_watch(controller) do |view|
          view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
            view.state.execution == Adamantine::DebugSessionState::Execution::Stopped &&
            view.frames.size >= 2 && !view.state.selected_frame_id.nil?
        end
        controller.add_watch("late_value").accepted?.should be_true
        watch_id = controller.snapshot.watches.last.id

        # Evaluation A is bound to the initially selected frame and held by the
        # fixture. Selecting another frame retires A's certificate and permits
        # a fresh evaluation of the same watch.
        controller.evaluate_watch(watch_id).accepted?.should be_true
        await_debug_watch_fixture(controller, log_path, "evaluate_held")
        controller.select_frame(initial.frames.last.id).accepted?.should be_true
        current_error = controller.snapshot.last_error
        controller.evaluate_watch(watch_id).accepted?.should be_true
        await_debug_watch_fixture(controller, log_path, "evaluate_release_written")

        # This request is an ordered DAP barrier: the adapter wrote stale A's
        # response before it can answer scopes, so poll must reduce A before
        # the barrier response makes the snapshot observable.
        controller.open_scopes.accepted?.should be_true
        latest = await_debug_watch(controller) { |view| !view.variables.roots.empty? }
        latest.state.selected_frame_id.should eq(initial.frames.last.id)
        latest.last_error.should eq(current_error)
        pending = latest.watches.find { |item| item.id == watch_id }.not_nil!
        pending.status.should eq(Adamantine::DebugController::WatchStatus::Pending)
        pending.result.should be_nil
        pending.reason.should be_nil
        controller.evaluate_watch(watch_id).accepted?.should be_false

        requests = debugger_watch_requests(log_path).select { |request| request["command"]?.try(&.as_s?) == "evaluate" }
        requests.size.should eq(2)
        requests.map { |request| request["arguments"].as_h["frameId"].as_i64 }.should eq([initial.frames.first.id, initial.frames.last.id])
      ensure
        cleanup_debug_watch(controller, client, root)
      end
    end
  end
end
