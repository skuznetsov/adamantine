require "spec"
require "random/secure"
require "../src/adamantine/debug_controller"

private def debugger_fixture_root(label : String) : Path
  root = Path.new(Dir.tempdir, "adamantine-debug-controller-#{label}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root.to_s)
  Path.new(File.realpath(root.to_s))
end

private def debugger_fixture_profile(root : Path, adapter : Path, mode : String? = nil,
                                     mode_args : Array(String) = [] of String) : Adamantine::Debugging::LaunchProfile
  ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
  adapter_argv = [ruby, adapter.to_s, (root / "adapter.jsonl").to_s]
  adapter_argv << mode.not_nil! if mode
  adapter_argv.concat(mode_args)
  Adamantine::Debugging::LaunchProfile.new(
    id: "fixture-profile",
    name: "Fixture",
    adapter_argv: adapter_argv,
    program: Process.find_executable("true") || "/usr/bin/true",
    cwd: root.to_s
  )
end

private def start_source_checksum_fixture(label : String, adapter_contents : String,
                                          baseline_contents : String,
                                          mode : String = "source_checksum")
  adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
  root = debugger_fixture_root(label)
  source_path = root / "main.cr"
  File.write(source_path.to_s, adapter_contents)
  source_key = Adamantine::Debugging::DebugSourceKey.local(source_path)
  controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
    Adamantine::Dap::Client.new(argv, cwd)
  })
  profile = debugger_fixture_profile(root, adapter, mode, [source_path.to_s])
  review = controller.prepare_launch(profile, root,
    [Adamantine::DebugController::SourceBaseline.new(source_path, baseline_contents)])
  raise "source checksum fixture should be reviewable: #{review.errors.join("; ")}" unless review.valid?
  raise "source checksum fixture should start" unless controller.start(review).accepted?
  await_debug_state(controller) { |snapshot| !snapshot.frames.empty? }
  {controller, root, source_key}
end

private def await_debug_state(controller : Adamantine::DebugController,
                              timeout : Time::Span = 3.seconds,
                              &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  latest = controller.poll
  until ready.call(latest)
    if Time.monotonic >= deadline
      raise "debug controller did not reach the expected state before timeout: lifecycle=#{latest.state.lifecycle}, execution=#{latest.state.execution}, last_error=#{latest.last_error}"
    end
    sleep 5.milliseconds
    latest = controller.poll
  end
  latest
end

describe Adamantine::DebugController do
  it "certifies a retained launch baseline only from an exact DAP SHA256 report" do
    controller, _root, source_key = start_source_checksum_fixture("checksum-match", "puts 1\n", "puts 1\n")
    source = controller.snapshot.sources.find { |entry| entry.key == source_key }
    raise "the retained baseline should be exposed as a source view" unless source
    raise "the DAP SHA256 should match the exact retained launch baseline" unless source.not_nil!.checksum_status == Adamantine::Debugging::ChecksumStatus::Match
    raise "the certified source must remain the launch baseline" unless source.not_nil!.origin == Adamantine::Debugging::SourceOrigin::LaunchBaseline
  ensure
    controller.try(&.close)
  end

  it "reports Mismatch when adapter SHA256 differs from retained live draft text" do
    controller, _root, source_key = start_source_checksum_fixture("checksum-mismatch", "puts 1\n", "puts 2\n")
    source = controller.snapshot.sources.find { |entry| entry.key == source_key }
    raise "the retained baseline should be exposed as a source view" unless source
    raise "the differing adapter SHA256 must be an explicit mismatch" unless source.not_nil!.checksum_status == Adamantine::Debugging::ChecksumStatus::Mismatch
  ensure
    controller.try(&.close)
  end

  ["checksum_absent", "checksum_unknown", "checksum_malformed"].each do |checksum_mode|
    it "leaves #{checksum_mode} adapter source evidence Unverified" do
      controller, _root, source_key = start_source_checksum_fixture(
        checksum_mode, "puts 1\n", "puts 1\n", "source_checksum,#{checksum_mode}")
      source = controller.snapshot.sources.find { |entry| entry.key == source_key }
      raise "the retained baseline should be exposed as a source view" unless source
      raise "#{checksum_mode} must not certify the retained baseline" unless source.not_nil!.checksum_status == Adamantine::Debugging::ChecksumStatus::Unverified
    ensure
      controller.try(&.close)
    end
  end

  it "does not certify a local baseline from a positive sourceReference and local path" do
    controller, _root, source_key = start_source_checksum_fixture(
      "checksum-source-reference", "puts 1\n", "puts 1\n", "source_checksum,source_reference")
    frame = controller.snapshot.frames.first
    raise "the fixture should provide a positive sourceReference" unless frame.source_reference == 77
    raise "positive sourceReference must win over the provided local path" unless frame.source_key.try(&.kind) == Adamantine::Debugging::SourceKeyKind::SessionReference
    raise "a local baseline must not become certified from sourceReference metadata" if controller.snapshot.sources.any? do |source|
                                                                                          source.key == source_key && source.checksum_status == Adamantine::Debugging::ChecksumStatus::Match
                                                                                        end
  ensure
    controller.try(&.close)
  end

  it "keeps a matching checksum Outdated after a source edit and later stack report" do
    contents = (1..16).map { |line| "line #{line}\n" }.join
    controller, _root, source_key = start_source_checksum_fixture("checksum-outdated", contents, contents)
    before_edit = controller.snapshot.sources.find { |entry| entry.key == source_key }
    raise "initial adapter evidence should match" unless before_edit && before_edit.not_nil!.checksum_status == Adamantine::Debugging::ChecksumStatus::Match
    raise "source edit should mark the retained baseline outdated" unless controller.mark_source_edited(source_key)
    raise "the edit barrier should be visible" unless controller.snapshot.sources.any? { |entry| entry.key == source_key && entry.outdated }
    raise "step should request a later stack source report" unless controller.step_over.accepted?
    await_debug_state(controller) { |snapshot| snapshot.frames.first?.try(&.dap_line) == 13 }
    after_report = controller.snapshot.sources.find { |entry| entry.key == source_key }
    raise "a matching later report must not clear Outdated" unless after_report && after_report.not_nil!.outdated
    raise "the later report should retain its factual checksum result" unless after_report.not_nil!.checksum_status == Adamantine::Debugging::ChecksumStatus::Match
  ensure
    controller.try(&.close)
  end

  it "keeps review and construction inert, then services initialized before launch completion" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("handshake")
    factory_calls = 0
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      factory_calls += 1
      Adamantine::Dap::Client.new(argv, cwd)
    end
    controller = Adamantine::DebugController.new(factory)
    profile = debugger_fixture_profile(root, adapter, "stop_before_launch_response")

    review = controller.prepare_launch(profile, root)
    raise "valid fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
    raise "review must not start the adapter" unless factory_calls == 0
    raise "review must not change lifecycle" unless controller.snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Idle

    submission = controller.start(review)
    raise "explicit start should be accepted" unless submission.accepted?
    raise "client factory should be called exactly once" unless factory_calls == 1
    await_debug_state(controller) { |state| state.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }
    active = await_debug_state(controller) { |state| !state.frames.empty? }

    log_path = root / "adapter.jsonl"
    records = File.read_lines(log_path).map { |line| JSON.parse(line).as_h }
    initialize_request = records.find do |record|
      record["type"]?.try(&.as_s?) == "request" && record["command"]?.try(&.as_s?) == "initialize"
    end || raise "fixture must observe the initialize request"
    initialize_arguments = initialize_request["arguments"].as_h
    raise "the consumer must advertise top-level variable paging support" unless initialize_arguments["supportsVariablePaging"]?.try(&.as_bool?) == true
    raise "the consumer must advertise top-level variable type support" unless initialize_arguments["supportsVariableType"]?.try(&.as_bool?) == true
    if nested_capabilities = initialize_arguments["clientCapabilities"]?
      raise "variable capabilities must not be hidden in nested clientCapabilities" unless nested_capabilities.as_h.empty?
    end
    commands = records.select { |record| record["type"]?.try(&.as_s?) == "request" }
      .map { |record| record["command"].as_s }
    raise "initialize must precede launch" unless commands.index("initialize").not_nil! < commands.index("launch").not_nil!
    raise "initialized must be configured while launch is pending" unless commands.includes?("configurationDone")
    raise "exception filters must be explicitly configured" unless commands.includes?("setExceptionBreakpoints")
    raise "configuration must finish before the held launch response is emitted" unless records.index { |record| record["name"]?.try(&.as_s?) == "launch_response" }.not_nil! > records.index { |record| record["command"]?.try(&.as_s?) == "configurationDone" }.not_nil!
    raise "the test fixture should not invent target exit" unless active.state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
    raise "the first stop observed before launch acknowledgement must still load its stack" unless active.frames.size == 2
    first_frame = active.frames.first
    raise "the retained frame must preserve the adapter source line" unless first_frame.dap_line == 12
    raise "the fixture must deliver the stop before the launch response" unless records.index { |record| record["name"]?.try(&.as_s?) == "stopped_before_launch_response" }.not_nil! < records.index { |record| record["name"]?.try(&.as_s?) == "launch_response" }.not_nil!
  ensure
    controller.try(&.stop)
  end

  it "waits for the complete latest breakpoint set before configurationDone" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("held-breakpoints")
    source_path = root / "main.cr"
    File.write(source_path.to_s, "puts 1\n")
    release_path = Path.new("#{root / "adapter.jsonl"}.release")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    raise "project binding should be inert and accepted" unless controller.bind_project(root, 0_u64)
    source_key = Adamantine::Debugging::DebugSourceKey.local(source_path.to_s)
    raise "idle breakpoint should be accepted" unless controller.toggle_breakpoint(source_key, 0).accepted?
    profile = debugger_fixture_profile(root, adapter, "hold_breakpoints")
    review = controller.prepare_launch(profile, root, [Adamantine::DebugController::SourceBaseline.new(source_path, "puts 1\n")])
    raise "fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
    raise "launch should be accepted" unless controller.start(review).accepted?

    log_path = root / "adapter.jsonl"
    deadline = Time.monotonic + 3.seconds
    until File.file?(log_path.to_s) && File.read(log_path.to_s).includes?("set_breakpoints_pending")
      raise "fixture did not hold the breakpoint response" if Time.monotonic >= deadline
      sleep 5.milliseconds
      controller.poll
    end
    held_records = File.read_lines(log_path.to_s).map { |line| JSON.parse(line).as_h }
    raise "configurationDone must wait for the in-flight full breakpoint set" if held_records.any? { |record| record["command"]?.try(&.as_s?) == "configurationDone" }

    File.write(release_path.to_s, "release")
    active = await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }
    records = File.read_lines(log_path.to_s).map { |line| JSON.parse(line).as_h }
    command_index = ->(name : String) { records.index { |record| record["command"]?.try(&.as_s?) == name } }
    marker_index = ->(name : String) { records.index { |record| record["name"]?.try(&.as_s?) == name } }
    done_index = command_index.call("configurationDone").not_nil!
    raise "configurationDone preceded setBreakpoints response" unless done_index > marker_index.call("set_breakpoints_response").not_nil!
    raise "configurationDone preceded exception filter response" unless done_index > marker_index.call("exception_breakpoints_response").not_nil!
    raise "held launch response must follow configurationDone" unless marker_index.call("launch_response").not_nil! > done_index
    raise "breakpoint should have an applied verified row" unless active.breakpoints.any? { |row| row.breakpoint.status == Adamantine::Debugging::BreakpointStatus::Verified }
    breakpoint_count = records.count { |record| record["command"]?.try(&.as_s?) == "setBreakpoints" }
    raise "source edit should retire the prior debug source certificate" unless controller.mark_source_edited(source_key)
    edited = controller.snapshot
    raise "edited source breakpoint should remain visibly Outdated" unless edited.breakpoints.any? { |row| row.breakpoint.status == Adamantine::Debugging::BreakpointStatus::Outdated }
    raise "captured baseline should remain retained as outdated source evidence" unless controller.open_source(source_key).accepted? && controller.snapshot.sources.any?(&.outdated)
    updated_records = File.read_lines(log_path.to_s).map { |line| JSON.parse(line).as_h }
    raise "editing source must not automatically resubmit breakpoints" unless updated_records.count { |record| record["command"]?.try(&.as_s?) == "setBreakpoints" } == breakpoint_count
  ensure
    File.write(release_path.to_s, "release") if release_path
    controller.try(&.close)
  end

  ["pause_ack_before_stop", "pause_stop_before_ack"].each do |mode|
    it "accepts #{mode} only as Pause acknowledgement followed by real stopped evidence" do
      controller, root = start_pause_fixture(mode)
      running = await_debug_state(controller) { |snapshot| snapshot.state.execution == Adamantine::DebugSessionState::Execution::Running }
      raise "continue must leave the target alive" unless running.state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
      raise "pause should be accepted for the live running thread" unless controller.pause.accepted?
      stopped = await_debug_state(controller) do |snapshot|
        snapshot.state.thread_execution(42_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
      end
      raise "stopped event must re-enable execution controls" unless stopped.available?(Adamantine::DebugController::Action::Continue)
    ensure
      controller.try(&.close)
    end
  end

  it "leaves a pause-without-stop outcome Unknown after its bounded deadline" do
    controller, _root = start_pause_fixture("pause_ack_no_stop")
    await_debug_state(controller) { |snapshot| snapshot.state.execution == Adamantine::DebugSessionState::Execution::Running }
    raise "pause should be accepted" unless controller.pause.accepted?
    unknown = await_debug_state(controller, 3.seconds) do |snapshot|
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Unknown &&
        snapshot.state.tracked_thread_ids.includes?(42_i64)
    end
    raise "pause acknowledgement must not claim stopped" unless unknown.state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
    raise "ambiguous pause must not enable Continue" if unknown.available?(Adamantine::DebugController::Action::Continue)
    raise "Pause should remain the explicit recovery action" unless unknown.available?(Adamantine::DebugController::Action::Pause)
  ensure
    controller.try(&.close)
  end

  it "marks an accepted empty scopes response and clears it when the frame changes or resumes" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("empty-scopes")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    profile = debugger_fixture_profile(root, adapter, "empty_scopes")
    review = controller.prepare_launch(profile, root)
    raise "empty-scopes fixture review should be valid" unless review.valid?
    initial_format_generation = controller.snapshot.value_format_generation
    raise "empty-scopes fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active && !snapshot.frames.empty? }
    raise "snapshot should expose the controller's value-format invalidation generation" unless controller.snapshot.value_format_generation > initial_format_generation
    raise "scope state should start unloaded" if controller.snapshot.scopes_loaded
    raise "scope state should start idle" if controller.snapshot.scopes_request_pending
    raise "scope request should be accepted" unless controller.open_scopes.accepted?
    raise "accepted scope request should become pending" unless controller.snapshot.scopes_request_pending
    raise "a new request should clear the prior scope error" if controller.snapshot.scopes_error

    loaded = await_debug_state(controller) { |snapshot| snapshot.scopes_loaded }
    raise "an empty accepted response must contain no fabricated roots" unless loaded.variables.roots.empty?
    raise "an empty accepted response must complete without an error" unless !loaded.scopes_request_pending && loaded.scopes_error.nil?
    raise "selected frame change should clear scope state" unless controller.select_frame(501).accepted? &&
                                                                  !controller.snapshot.scopes_loaded && !controller.snapshot.scopes_request_pending && controller.snapshot.scopes_error.nil?
    raise "second scope request should be accepted" unless controller.open_scopes.accepted?
    await_debug_state(controller) { |snapshot| snapshot.scopes_loaded }
    raise "resume should immediately retire scope state" unless controller.step_over.accepted? &&
                                                                !controller.snapshot.scopes_loaded && !controller.snapshot.scopes_request_pending && controller.snapshot.scopes_error.nil?
  ensure
    controller.try(&.close)
  end

  it "exposes value-format status transitions without changing the request generation" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("value-format-status")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    profile = debugger_fixture_profile(root, adapter, "value_format")
    review = controller.prepare_launch(profile, root)
    raise "value-format fixture review should be valid" unless review.valid?
    raise "value-format fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active && !snapshot.frames.empty? }
    raise "scope request should be accepted" unless controller.open_scopes.accepted?
    await_debug_state(controller) do |snapshot|
      snapshot.scopes_loaded && snapshot.variables.nodes.any? { |node| node.name == "duplicate" && node.value == "11" }
    end
    target = controller.snapshot.variables.nodes.find { |node| node.name == "duplicate" && node.value == "11" }
    raise "second duplicate variable should be retained" unless target

    raise "Hex request should be accepted" unless controller.request_value_format(target.not_nil!.id).accepted?
    pending = controller.snapshot
    raise "snapshot should expose Pending format status" unless pending.value_format_status == Adamantine::DebugController::ValueFormatStatus::Pending
    request_generation = pending.value_format_generation
    available = await_debug_state(controller) do |snapshot|
      snapshot.value_format_status == Adamantine::DebugController::ValueFormatStatus::Available
    end
    raise "Pending-to-Available must not change request identity" unless available.value_format_generation == request_generation
    raise "formatted value response should remain available" unless controller.render_value(target.not_nil!.id, Adamantine::Debugging::DebugValueFormat::Hex).available?

    raise "second Hex request should be accepted" unless controller.request_value_format(target.not_nil!.id).accepted?
    cancelling = controller.snapshot
    raise "second request should become Pending" unless cancelling.value_format_status == Adamantine::DebugController::ValueFormatStatus::Pending
    controller.cancel_value_format(target.not_nil!.id)
    cancelled = controller.snapshot
    raise "cancelling detail should invalidate its local request identity" unless cancelled.value_format_generation > cancelling.value_format_generation
    raise "cancelled detail status should no longer be cached" unless cancelled.value_format_status.nil?
  ensure
    controller.try(&.close)
  end

  it "leaves scopes unloaded after a rejected scope request" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("failed-scopes")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    profile = debugger_fixture_profile(root, adapter, "reject_scopes")
    review = controller.prepare_launch(profile, root)
    raise "failed-scopes fixture review should be valid" unless review.valid?
    raise "failed-scopes fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active && !snapshot.frames.empty? }
    raise "scope request should be accepted" unless controller.open_scopes.accepted?
    raise "rejected-scope request should become pending" unless controller.snapshot.scopes_request_pending
    rejected = await_debug_state(controller) { |snapshot| snapshot.scopes_error.try(&.includes?("fixture rejected scopes")) == true }
    raise "failed request must finish loading" if rejected.scopes_request_pending
    raise "failed request must remain unloaded" if rejected.scopes_loaded
    raise "rejected request should expose its scoped error" unless rejected.scopes_error.try(&.includes?("fixture rejected scopes"))
    raise "explicit retry should be accepted" unless controller.open_scopes.accepted?
    raise "retry should clear the previous scoped error while pending" unless controller.snapshot.scopes_request_pending && controller.snapshot.scopes_error.nil?
    await_debug_state(controller) { |snapshot| snapshot.scopes_error.try(&.includes?("fixture rejected scopes")) == true }
  ensure
    controller.try(&.close)
  end

  it "completes a malformed successful scopes response as an explicit scoped error" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("malformed-scopes")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    profile = debugger_fixture_profile(root, adapter, "malformed_scopes")
    review = controller.prepare_launch(profile, root)
    raise "malformed-scopes fixture review should be valid" unless review.valid?
    raise "malformed-scopes fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active && !snapshot.frames.empty? }
    raise "scope request should be accepted" unless controller.open_scopes.accepted?
    malformed = await_debug_state(controller) { |snapshot| snapshot.scopes_error.try(&.includes?("malformed scopes response")) == true }
    raise "malformed response must end loading" if malformed.scopes_request_pending
    raise "malformed response must not mark scopes loaded" if malformed.scopes_loaded
  ensure
    controller.try(&.close)
  end

  it "rejects malformed retained scope entries without fabricating roots or failing the session" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("malformed-scope-entries")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    profile = debugger_fixture_profile(root, adapter, "malformed_scope_entries")
    review = controller.prepare_launch(profile, root)
    raise "malformed-entry fixture review should be valid" unless review.valid?
    raise "malformed-entry fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active && !snapshot.frames.empty? }
    raise "scope request should be accepted" unless controller.open_scopes.accepted?
    malformed = await_debug_state(controller) { |snapshot| snapshot.scopes_error.try(&.includes?("malformed scopes response")) == true }
    raise "malformed entries must complete loading" if malformed.scopes_request_pending
    raise "malformed entries must remain unloaded" if malformed.scopes_loaded
    raise "malformed entries must not fabricate scope roots" unless malformed.variables.roots.empty?
    raise "malformed entries must not fail the debug session" unless malformed.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active
  ensure
    controller.try(&.close)
  end

  it "does not publish a rejected scopes response after frame retirement" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("stale-scopes-rejection")
    log_path = root / "adapter.jsonl"
    release_path = Path.new("#{log_path}.scopes-release")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    profile = debugger_fixture_profile(root, adapter, "hold_scopes_reject")
    review = controller.prepare_launch(profile, root)
    raise "held-rejection fixture review should be valid" unless review.valid?
    raise "held-rejection fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active && !snapshot.frames.empty? }
    raise "scope request should be accepted" unless controller.open_scopes.accepted?
    raise "scope request should remain pending while held" unless controller.snapshot.scopes_request_pending
    deadline = Time.monotonic + 3.seconds
    until File.file?(log_path.to_s) && File.read(log_path.to_s).includes?("scopes_held")
      raise "fixture did not hold the scopes failure" if Time.monotonic >= deadline
      sleep 5.milliseconds
      controller.poll
    end
    raise "frame change should retire pending scope state" unless controller.select_frame(501).accepted? &&
                                                                  !controller.snapshot.scopes_request_pending && controller.snapshot.scopes_error.nil?
    retired_last_error = controller.snapshot.last_error
    retired_generation = controller.snapshot.generation
    File.write(release_path.to_s, "release")
    deadline = Time.monotonic + 3.seconds
    until controller.snapshot.generation > retired_generation
      raise "held stale response was not consumed" if Time.monotonic >= deadline
      sleep 5.milliseconds
      controller.poll
    end
    stale = controller.snapshot
    raise "stale failure must not restore pending scope state" if stale.scopes_request_pending
    raise "stale failure must not publish a scope error" if stale.scopes_error
    raise "stale failure must not mark scopes loaded" if stale.scopes_loaded
    raise "stale failure must not overwrite the unrelated controller error" unless stale.last_error == retired_last_error
  ensure
    File.write(release_path.to_s, "release") if release_path
    controller.try(&.close)
  end

  it "sends no formatter effects for Generic and one embedded LLDB init command for reviewed StockCrystal" do
    adapter_fixture = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    [
      {Adamantine::Debugging::NativeValueProvider::Generic, false},
      {Adamantine::Debugging::NativeValueProvider::StockCrystal, true},
    ].each do |provider, enabled|
      root = debugger_fixture_root("native-values-#{provider}")
      adapter = if enabled
                  lldb_named_fixture = root / "lldb-dap"
                  File.copy(adapter_fixture.to_s, lldb_named_fixture.to_s)
                  File.chmod(lldb_named_fixture.to_s, 0o700)
                  lldb_named_fixture
                else
                  adapter_fixture
                end
      factory_calls = 0
      controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
        factory_calls += 1
        Adamantine::Dap::Client.new(argv, cwd)
      })
      adapter_argv = if enabled
                       [adapter.to_s, "--no-lldbinit", (root / "adapter.jsonl").to_s, "basic"]
                     else
                       [Process.find_executable("ruby") || raise("Ruby required"), adapter.to_s, (root / "adapter.jsonl").to_s, "basic"]
                     end
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "native-#{provider}", name: "Native #{provider}",
        adapter_argv: adapter_argv,
        program: Process.find_executable("true") || "/usr/bin/true", cwd: root.to_s,
        native_values: provider,
      )
      review = controller.prepare_launch(profile, root)
      raise "native launch review should be valid: #{review.errors.join("; ")}" unless review.valid?
      raise "selecting or reviewing a provider must not start the adapter" unless factory_calls == 0
      raise "native launch should be accepted" unless controller.start(review).accepted?
      raise "explicit start should create one adapter" unless factory_calls == 1
      await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active && !snapshot.frames.empty? }
      launch = File.read_lines(root / "adapter.jsonl").map { |line| JSON.parse(line).as_h }.find do |record|
        record["type"]?.try(&.as_s?) == "request" && record["command"]?.try(&.as_s?) == "launch"
      end || raise "fixture must capture the launch request"
      arguments = launch["arguments"].as_h
      commands = arguments["initCommands"]?.try(&.as_a?)
      if enabled
        raise "StockCrystal should send exactly one init command" unless commands && commands.not_nil!.size == 1
        command = commands.not_nil!.first.as_s
        raise "init command must install and register the bundled module" unless command.includes?("adamantine_crystal = _adamantine_types.ModuleType") && command.includes?("_adamantine_sys.modules[\"adamantine_crystal\"] = adamantine_crystal") && command.includes?("adamantine_crystal.register(lldb.debugger)")
        raise "init command must use LLDB failure checking" unless command.starts_with?("!script ")
        raise "init command must remain one safely escaped line" if command.includes?('\n') || command.includes?('\r')
        payload = command.match(/base64\.b64decode\("([A-Za-z0-9+\/=]+)"\)/).try(&.[1]) || raise "init command must carry a base64 source payload"
        embedded_source = Base64.decode_string(payload)
        bundled_source = File.read(Path.new(Dir.current, "tools/lldb/adamantine_crystal.py"))
        raise "wire payload must equal compile-time source" unless embedded_source == Adamantine::Debugging::PROVIDER_SOURCE
        raise "compile-time source must equal provider asset, byte for byte" unless embedded_source == bundled_source
        raise "provider must not import project code or discovery paths" if embedded_source.includes?("importlib") || embedded_source.includes?("sys.path")
      else
        raise "Generic must not send formatter effects" if commands
      end
    ensure
      controller.try(&.close)
    end
  end

  it "fails closed when mandatory exception-breakpoint setup is rejected" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("exception-filter-reject")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    review = controller.prepare_launch(debugger_fixture_profile(root, adapter, "exception_breakpoints_reject"), root)
    raise "rejected-filter fixture review should be valid" unless review.valid?
    raise "rejected-filter fixture launch should be accepted" unless controller.start(review).accepted?

    failed = await_debug_state(controller) do |snapshot|
      snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Failed && !snapshot.cleanup_pending
    end
    raise "mandatory filter failure must be visible" unless failed.last_error.try(&.includes?("fixture rejected exception filters"))
    records = File.read_lines(root / "adapter.jsonl").map { |line| JSON.parse(line).as_h }
    raise "failed mandatory setup must not send configurationDone" if records.any? { |record| record["command"]?.try(&.as_s?) == "configurationDone" }
    raise "filter setup failure must not claim target exit" unless failed.state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown
  ensure
    controller.try(&.close)
  end

  it "keeps a rejected breakpoint visible but completes configuration" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("breakpoint-reject")
    source_path = root / "main.cr"
    File.write(source_path.to_s, "puts 1\n")
    source_key = Adamantine::Debugging::DebugSourceKey.local(source_path.to_s)
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    raise "project binding should succeed" unless controller.bind_project(root, 0_u64)
    raise "idle breakpoint should be accepted" unless controller.toggle_breakpoint(source_key, 0).accepted?
    review = controller.prepare_launch(debugger_fixture_profile(root, adapter, "set_breakpoints_reject"), root,
      [Adamantine::DebugController::SourceBaseline.new(source_path, "puts 1\n")])
    raise "rejected-breakpoint fixture review should be valid" unless review.valid?
    raise "rejected-breakpoint fixture launch should be accepted" unless controller.start(review).accepted?

    active = await_debug_state(controller) do |snapshot|
      snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active
    end
    raise "rejected breakpoint should remain visible" unless active.breakpoints.any? { |row| row.breakpoint.status == Adamantine::Debugging::BreakpointStatus::Rejected }
    records = File.read_lines(root / "adapter.jsonl").map { |line| JSON.parse(line).as_h }
    raise "fixture must reject the full breakpoint set" unless records.any? { |record| record["name"]?.try(&.as_s?) == "set_breakpoints_rejected" }
    raise "breakpoint rejection must not stall configuration" unless records.any? { |record| record["command"]?.try(&.as_s?) == "configurationDone" }
  ensure
    controller.try(&.close)
  end

  it "ends failed and Unknown when Stop's pending execution cannot be resolved" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("stop-pending-timeout")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    review = controller.prepare_launch(debugger_fixture_profile(root, adapter, "next_never_replies"), root)
    raise "stop-timeout fixture review should be valid" unless review.valid?
    raise "stop-timeout fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }
    raise "fixture must begin stopped" unless controller.state.execution == Adamantine::DebugSessionState::Execution::Stopped
    raise "Step should be accepted before Stop" unless controller.step_over.accepted?

    log_path = root / "adapter.jsonl"
    deadline = Time.monotonic + 3.seconds
    until File.file?(log_path.to_s) && File.read(log_path.to_s).includes?("next_held_without_response")
      raise "fixture did not receive the pending step" if Time.monotonic >= deadline
      controller.poll
      sleep 5.milliseconds
    end
    raise "Stop should be accepted while the step is unresolved" unless controller.stop.accepted?
    failed = await_debug_state(controller, 4.seconds) do |snapshot|
      snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Failed && !snapshot.cleanup_pending
    end
    raise "pending Stop timeout must not invent target exit" unless failed.state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown
    raise "pending Stop timeout must expose its reason" unless failed.last_error.try(&.includes?("pending execution request"))
  ensure
    controller.try(&.close)
  end

  it "fails and retires an adapter that rejects disconnect" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("disconnect-reject")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    review = controller.prepare_launch(debugger_fixture_profile(root, adapter, "disconnect_reject"), root)
    raise "disconnect-reject fixture review should be valid" unless review.valid?
    raise "disconnect-reject fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }
    raise "Stop should be accepted" unless controller.stop.accepted?

    failed = await_debug_state(controller, 4.seconds) do |snapshot|
      snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Failed && !snapshot.cleanup_pending
    end
    raise "disconnect rejection should be visible" unless failed.last_error.try(&.includes?("fixture rejected disconnect"))
    raise "disconnect rejection must not claim target exit" unless failed.state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown
    records = File.read_lines(root / "adapter.jsonl").map { |line| JSON.parse(line).as_h }
    raise "fixture must reject the correlated disconnect" unless records.any? { |record| record["name"]?.try(&.as_s?) == "disconnect_rejected" }
  ensure
    controller.try(&.close)
  end

  it "publishes the exit code only after an explicit exited event" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("exit-code")
    controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
      Adamantine::Dap::Client.new(argv, cwd)
    })
    review = controller.prepare_launch(debugger_fixture_profile(root, adapter), root)
    raise "exit-code fixture review should be valid" unless review.valid?
    raise "exit-code fixture launch should be accepted" unless controller.start(review).accepted?
    await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }
    before_continue = controller.snapshot
    raise "exit code must be unknown before an exited event" unless before_continue.target_exit_code.nil?
    raise "Continue should be accepted" unless controller.continue.accepted?

    ended = await_debug_state(controller, 4.seconds) do |snapshot|
      snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended &&
        snapshot.state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Exited &&
        snapshot.target_exit_code == 0
    end
    raise "the explicit exited event must retain code zero through terminated" unless ended.target_exit_code == 0
  ensure
    controller.try(&.close)
  end

  it "retires each owned adapter before permitting a repeated start and stop" do
    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    root = debugger_fixture_root("repeat-session")
    clients = [] of Adamantine::Dap::Client
    factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
      client = Adamantine::Dap::Client.new(argv, cwd)
      clients << client
      client
    end
    controller = Adamantine::DebugController.new(factory)

    2.times do
      review = controller.prepare_launch(debugger_fixture_profile(root, adapter), root)
      raise "repeated launch review should be valid" unless review.valid?
      raise "repeated launch should wait until the prior adapter is retired" unless controller.start(review).accepted?
      await_debug_state(controller) do |snapshot|
        snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          snapshot.state.execution == Adamantine::DebugSessionState::Execution::Stopped
      end
      raise "stop should be accepted for the owned session" unless controller.stop.accepted?
      await_debug_state(controller) do |snapshot|
        snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended && !snapshot.cleanup_pending
      end
      client = clients.last
      deadline = Time.monotonic + 3.seconds
      until client.retired? || Time.monotonic >= deadline
        controller.poll
        sleep 5.milliseconds
      end
      raise "controller-owned adapter and actors must retire between sessions" unless client.retired? && !client.owned_adapter_alive?
    end
    raise "each repeat must receive a distinct owned client" unless clients.size == 2
  ensure
    controller.try(&.close)
  end
end

private def start_pause_fixture(mode : String) : Tuple(Adamantine::DebugController, Path)
  adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
  root = debugger_fixture_root(mode)
  factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) {
    Adamantine::Dap::Client.new(argv, cwd)
  }
  controller = Adamantine::DebugController.new(factory)
  profile = debugger_fixture_profile(root, adapter, mode)
  review = controller.prepare_launch(profile, root)
  raise "pause fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
  raise "pause fixture launch should start" unless controller.start(review).accepted?
  await_debug_state(controller) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }
  raise "fixture should establish stopped target before Continue" unless controller.state.execution == Adamantine::DebugSessionState::Execution::Stopped
  raise "Continue should be accepted" unless controller.continue.accepted?
  {controller, root}
end
