require "spec"
require "json"
require "file_utils"
require "random/secure"
require "./support/debugger_fixture_support"
require "../src/adamantine/debug_controller"

private def debugger_ownership_root : Path
  root = Path.new(Dir.tempdir, "adamantine-debug-owner-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root.to_s)
  root
end

private def debugger_ownership_profile(root : Path, adapter : Path, program : String? = nil,
                                       mode : String = "basic") : Adamantine::Debugging::LaunchProfile
  ruby = DebuggerFixtureSupport.ruby_executable
  Adamantine::Debugging::LaunchProfile.new(
    id: "owner-fixture-profile",
    name: "Ownership fixture",
    adapter_argv: [ruby, adapter.to_s, (root / "adapter.jsonl").to_s, mode],
    program: program || Process.find_executable("true") || "/usr/bin/true",
    cwd: File.realpath(root.to_s)
  )
end

private def await_debug_ownership(controller : Adamantine::DebugController,
                                  timeout : Time::Span = 5.seconds,
                                  &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  latest = controller.poll
  until ready.call(latest)
    if Time.monotonic >= deadline
      raise "debug controller did not reach the expected ownership state before timeout " \
            "(lifecycle=#{latest.state.lifecycle}, execution=#{latest.state.execution}, " \
            "target=#{latest.state.target_liveness}, error=#{latest.last_error.inspect})"
    end
    sleep 5.milliseconds
    latest = controller.poll
  end
  latest
end

private def debugger_ownership_requests(path : Path) : Array(Hash(String, JSON::Any))
  return [] of Hash(String, JSON::Any) unless File.file?(path.to_s)
  File.read_lines(path.to_s).map { |line| JSON.parse(line).as_h }
    .select { |record| record["type"]?.try(&.as_s?) == "request" }
end

private def cleanup_debug_ownership(controller : Adamantine::DebugController?, clients : Array(Adamantine::Dap::Client), root : Path) : Nil
  if owner = controller
    owner.stop
    deadline = Time.monotonic + 5.seconds
    while owner.cleanup_pending? || clients.any? { |client| !client.retired? }
      break if Time.monotonic >= deadline
      owner.poll
      sleep 5.milliseconds
    end
    owner.close
  end
  clients.each do |client|
    client.close
    deadline = Time.monotonic + 3.seconds
    until client.retired? || Time.monotonic >= deadline
      sleep 5.milliseconds
    end
    raise "owned fixture adapter was not retired" unless client.retired?
  end
  FileUtils.rm_rf(root.to_s)
end

describe Adamantine::DebugController, "launch ownership" do
  it "revalidates the reviewed executable and working directory before spawning" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_ownership_root
    cwd_root = debugger_ownership_root
    executable = Path.new(File.realpath(root.to_s)) / "fixture-target"
    File.write(executable.to_s, "#!/bin/sh\nexit 0\n")
    File.chmod(executable.to_s, 0o755)
    clients = [] of Adamantine::Dap::Client
    factory_calls = 0
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      factory_calls += 1
      client = Adamantine::Dap::Client.new(argv, cwd)
      clients << client
      client
    end
    owner = Adamantine::DebugController.new(factory)
    cwd_owner = Adamantine::DebugController.new(factory)

    begin
      executable_review = owner.prepare_launch(debugger_ownership_profile(root, adapter, executable.to_s), root)
      executable_review.errors.should be_empty
      executable_review.valid?.should be_true
      File.chmod(executable.to_s, 0o644)
      owner.start(executable_review).accepted?.should be_false
      factory_calls.should eq(0)

      cwd_review = cwd_owner.prepare_launch(debugger_ownership_profile(cwd_root, adapter), cwd_root)
      cwd_review.valid?.should be_true
      Dir.delete(cwd_root.to_s)
      cwd_owner.start(cwd_review).accepted?.should be_false
      factory_calls.should eq(0)
    ensure
      cleanup_debug_ownership(owner, clients, root)
      cleanup_debug_ownership(cwd_owner, clients, cwd_root)
    end
  end

  it "keeps preparation inert and rejects foreign, stale, reused, and replacing reviews before spawning" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_ownership_root
    clients = [] of Adamantine::Dap::Client
    factory_calls = 0
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      factory_calls += 1
      client = Adamantine::Dap::Client.new(argv, cwd)
      clients << client
      client
    end
    owner = Adamantine::DebugController.new(factory)
    foreign = Adamantine::DebugController.new(factory)

    begin
      profile = debugger_ownership_profile(root, adapter)
      first_review = owner.prepare_launch(profile, root)
      first_review.errors.should be_empty
      first_review.valid?.should be_true
      factory_calls.should eq(0)

      foreign.start(first_review).accepted?.should be_false
      factory_calls.should eq(0)

      owner.project_changed(1_u64)
      owner.start(first_review).accepted?.should be_false
      factory_calls.should eq(0)

      current_review = owner.prepare_launch(profile, root)
      current_review.valid?.should be_true
      owner.start(current_review).accepted?.should be_true
      factory_calls.should eq(1)
      await_debug_ownership(owner) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          view.state.execution == Adamantine::DebugSessionState::Execution::Stopped
      end

      owner.start(current_review).accepted?.should be_false
      factory_calls.should eq(1)
      replacement_review = owner.prepare_launch(profile, root)
      owner.start(replacement_review).accepted?.should be_false
      factory_calls.should eq(1)
    ensure
      foreign.close
      cleanup_debug_ownership(owner, clients, root)
    end
  end

  it "disconnects through its owned DAP client, keeps target exit Unknown, and sends no DAP terminate request" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_ownership_root
    clients = [] of Adamantine::Dap::Client
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      client = Adamantine::Dap::Client.new(argv, cwd)
      clients << client
      client
    end
    owner = Adamantine::DebugController.new(factory)
    log_path = root / "adapter.jsonl"

    begin
      review = owner.prepare_launch(debugger_ownership_profile(root, adapter), root)
      owner.start(review).accepted?.should be_true
      await_debug_ownership(owner) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          view.state.execution == Adamantine::DebugSessionState::Execution::Stopped
      end

      owner.stop.accepted?.should be_true
      stopped = await_debug_ownership(owner) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended &&
          !view.cleanup_pending
      end
      stopped.state.target_liveness.should eq(Adamantine::DebugSessionState::TargetLiveness::Unknown)

      client = clients.first
      deadline = Time.monotonic + 3.seconds
      until client.retired? || Time.monotonic >= deadline
        owner.poll
        sleep 5.milliseconds
      end
      client.retired?.should be_true
      client.owned_adapter_alive?.should be_false

      requests = debugger_ownership_requests(log_path)
      commands = requests.map { |request| request["command"].as_s }
      commands.includes?("disconnect").should be_true
      commands.includes?("terminate").should be_false
      commands.includes?("terminateThreads").should be_false
      disconnect = requests.find { |request| request["command"]?.try(&.as_s?) == "disconnect" }.not_nil!
      # The fixture does not advertise supportTerminateDebuggee. In this
      # launch-only session the omitted override uses DAP's default terminate
      # behavior; never send a contradictory false override.
      if arguments = disconnect["arguments"]?
        arguments.as_h.has_key?("terminateDebuggee").should be_false
      end
    ensure
      cleanup_debug_ownership(owner, clients, root)
    end
  end

  it "sends the terminateDebuggee override only when the adapter advertises support" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_ownership_root
    clients = [] of Adamantine::Dap::Client
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      client = Adamantine::Dap::Client.new(argv, cwd)
      clients << client
      client
    end
    owner = Adamantine::DebugController.new(factory)
    log_path = root / "adapter.jsonl"

    begin
      review = owner.prepare_launch(debugger_ownership_profile(root, adapter, mode: "terminate_capability"), root)
      review.errors.should be_empty
      owner.start(review).accepted?.should be_true
      started = await_debug_ownership(owner) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          view.state.execution == Adamantine::DebugSessionState::Execution::Stopped
      end
      started.capabilities.support_terminate_debuggee.should be_true

      owner.stop.accepted?.should be_true
      stopped = await_debug_ownership(owner) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended &&
          !view.cleanup_pending
      end
      stopped.state.target_liveness.should eq(Adamantine::DebugSessionState::TargetLiveness::Unknown)
      clients.first.retired?.should be_true
      clients.first.owned_adapter_alive?.should be_false

      disconnect = debugger_ownership_requests(log_path)
        .find { |request| request["command"]?.try(&.as_s?) == "disconnect" }.not_nil!
      disconnect["arguments"].as_h["terminateDebuggee"].as_bool.should be_true
      debugger_ownership_requests(log_path).any? { |request| request["command"]?.try(&.as_s?) == "terminate" }.should be_false
    ensure
      cleanup_debug_ownership(owner, clients, root)
    end
  end

  it "retires the owned adapter after a correlated disconnect rejection without claiming target exit" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_ownership_root
    clients = [] of Adamantine::Dap::Client
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      client = Adamantine::Dap::Client.new(argv, cwd)
      clients << client
      client
    end
    owner = Adamantine::DebugController.new(factory)
    log_path = root / "adapter.jsonl"

    begin
      review = owner.prepare_launch(debugger_ownership_profile(root, adapter, mode: "disconnect_reject"), root)
      review.valid?.should be_true
      owner.start(review).accepted?.should be_true
      await_debug_ownership(owner) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          view.state.execution == Adamantine::DebugSessionState::Execution::Stopped
      end

      stop_at = Time.monotonic
      owner.stop.accepted?.should be_true
      failed = await_debug_ownership(owner, 5.seconds) do |view|
        view.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Failed &&
          !view.cleanup_pending
      end
      (Time.monotonic - stop_at < 5.seconds).should be_true
      failed.state.target_liveness.should eq(Adamantine::DebugSessionState::TargetLiveness::Unknown)
      failed.last_error.try(&.includes?("fixture rejected disconnect")).should be_true

      client = clients.first
      client.retired?.should be_true
      client.owned_adapter_alive?.should be_false
      requests = debugger_ownership_requests(log_path)
      requests.any? { |request| request["command"]?.try(&.as_s?) == "disconnect" }.should be_true
      requests.any? { |request| request["command"]?.try(&.as_s?) == "terminate" }.should be_false
      requests.any? { |request| request["command"]?.try(&.as_s?) == "terminateThreads" }.should be_false
    ensure
      cleanup_debug_ownership(owner, clients, root)
    end
  end
end
