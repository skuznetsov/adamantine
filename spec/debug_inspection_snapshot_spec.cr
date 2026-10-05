require "spec"
require "file_utils"
require "random/secure"
require "../src/adamantine/debug_controller"

private def inspection_fixture_root(label : String) : Path
  root = Path.new(Dir.tempdir, "adamantine-debug-inspection-#{label}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root.to_s)
  Path.new(File.realpath(root.to_s))
end

private def inspection_fixture_profile(root : Path, adapter : Path,
                                       mode : String = "basic") : Adamantine::Debugging::LaunchProfile
  ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
  Adamantine::Debugging::LaunchProfile.new(
    id: "inspection-profile",
    name: "Inspection fixture",
    adapter_argv: [ruby, adapter.to_s, (root / "adapter.jsonl").to_s, mode],
    program: Process.find_executable("true") || "/usr/bin/true",
    cwd: root.to_s
  )
end

private def inspection_fixture_controller(root : Path, mode : String = "basic") : Adamantine::DebugController
  adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
  controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
    Adamantine::Dap::Client.new(argv, cwd)
  })
  review = controller.prepare_launch(inspection_fixture_profile(root, adapter, mode), root)
  raise "inspection fixture launch review should be valid: #{review.errors.join("; ")}" unless review.valid?
  raise "inspection fixture launch should be accepted" unless controller.start(review).accepted?
  controller
end

private def await_inspection_snapshot(controller : Adamantine::DebugController,
                                      timeout : Time::Span = 3.seconds,
                                      &ready : Adamantine::DebugController::InspectionSnapshot -> Bool) : Adamantine::DebugController::InspectionSnapshot
  deadline = Time.instant + timeout
  loop do
    snapshot = controller.inspection_snapshot
    return snapshot if ready.call(snapshot)
    if Time.instant >= deadline
      raise "debug inspection timed out: lifecycle=#{snapshot.state.lifecycle}, execution=#{snapshot.state.execution}, " \
            "selected_thread=#{snapshot.state.selected_thread_id}, threads=#{snapshot.threads.map { |thread| {thread.id, thread.execution} }}, " \
            "stack_fresh=#{snapshot.stack_fresh}, frames=#{snapshot.frames.size}, scopes_error=#{snapshot.scopes_error}"
    end
    controller.poll
    sleep 5.milliseconds
  end
end

private def inspection_adapter_commands(root : Path) : Array(String)
  log = root / "adapter.jsonl"
  return [] of String unless File.file?(log.to_s)
  File.read_lines(log).compact_map do |line|
    record = JSON.parse(line).as_h
    record["command"]?.try(&.as_s?) if record["type"]?.try(&.as_s?) == "request"
  end
end

describe Adamantine::DebugController do
  it "returns inert bounded retained state and no stale frames" do
    root = inspection_fixture_root("inert")
    controller = inspection_fixture_controller(root)
    initial = controller.inspection_snapshot
    raise "initial execution must remain explicitly unknown" unless initial.state.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "initial scopes must be explicitly unloaded" if initial.scopes_loaded || initial.scopes_request_pending || initial.scopes_error
    raise "initial variables must be empty rather than fabricated" unless initial.variables.roots.empty?
    raise "an unaccepted stack must not be fresh or expose frames" if initial.stack_fresh || !initial.frames.empty?

    stopped = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }
    raise "the accepted stop should retain the tracked thread" unless stopped.threads.map(&.id) == [42_i64]
    raise "inspection should expose the target's canonical project origin" unless stopped.origin_project_root == root.to_s
    origin_stamp = stopped.origin_project_stamp || raise "inspection should retain target directory identity"
    raise "origin identity should name the fixture directory" unless origin_stamp.same_target?(Adamantine::FileRevision.probe(root))
    raise "the accepted stack should retain both fixture rows" unless stopped.frames.map(&.id) == [500_i64, 501_i64]

    before = inspection_adapter_commands(root)
    8.times { controller.inspection_snapshot }
    after = inspection_adapter_commands(root)
    raise "inspection must not poll or send another DAP request" unless before == after
    raise "inspection must not trigger evaluation or scopes loading" if after.any? { |command| command.in?("evaluate", "scopes", "variables", "source") }

    detached = controller.inspection_snapshot.frames
    detached.clear
    raise "returned frame arrays must not mutate controller-retained rows" unless controller.inspection_snapshot.frames.size == 2
  ensure
    controller.try(&.close)
  end

  it "hides resumed retained rows, refuses stale resealing, and accepts reused IDs only after a new stack" do
    root = inspection_fixture_root("resume-reuse")
    controller = inspection_fixture_controller(root)
    first = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }
    raise "fixture should use numeric frame IDs 500 and 501" unless first.frames.map(&.id) == [500_i64, 501_i64]

    raise "step should be accepted" unless controller.step_over.accepted?
    resumed = controller.inspection_snapshot
    raise "resuming must make the retained stack stale immediately" if resumed.stack_fresh || !resumed.frames.empty?

    # The UI still retains the numeric rows internally. Selecting one after
    # resume must not turn those old rows into new evidence.
    raise "the retained UI row remains selectable" unless controller.select_frame(500_i64).accepted?
    stale_selection = controller.inspection_snapshot
    raise "selecting a stale retained row must not reseal it" if stale_selection.stack_fresh || !stale_selection.frames.empty?

    second = await_inspection_snapshot(controller) do |snapshot|
      snapshot.stack_fresh && snapshot.state.stop_epoch > first.state.stop_epoch
    end
    raise "numeric ID reuse is permitted only for the newly accepted stack" unless second.frames.map(&.id) == [500_i64, 501_i64]

    raise "selecting a current frame should succeed" unless controller.select_frame(501_i64).accepted?
    selected = controller.inspection_snapshot
    raise "a legitimate current-stack frame selection must reseal the retained stack" unless selected.stack_fresh
    raise "the selected frame should remain marked in the fresh stack" unless selected.frames.find(&.selected).try(&.id) == 501_i64
  ensure
    controller.try(&.close)
  end

  it "hides certified rows after the reducer observes a continued running state" do
    root = inspection_fixture_root("continued-running")
    controller = inspection_fixture_controller(root, "pause_ack_no_stop")
    stopped = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }
    raise "fixture must begin with a current stopped stack" unless stopped.state.execution == Adamantine::DebugSessionState::Execution::Stopped

    raise "continue should be accepted" unless controller.continue.accepted?
    running = await_inspection_snapshot(controller) do |snapshot|
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Running
    end
    raise "continued execution must invalidate the retained stack" if running.stack_fresh || !running.frames.empty?
    raise "the retained thread should report running" unless running.threads.first?.try(&.execution) == Adamantine::DebugSessionState::ThreadExecution::Running
  ensure
    controller.try(&.close)
  end

  it "projects pending thread execution from the reducer before another DAP event" do
    root = inspection_fixture_root("immediate-resume-state")
    controller = inspection_fixture_controller(root)
    stopped = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }
    raise "fixture should expose a stopped thread" unless stopped.threads.first?.try(&.execution) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    name = stopped.threads.first.name

    raise "continue should be accepted" unless controller.continue.accepted?
    pending = controller.inspection_snapshot
    expected = pending.state.thread_execution(42_i64)
    thread = pending.threads.find(&.id.==(42_i64))
    actual = thread.try(&.execution)
    raise "reducer should mark the thread resume-pending immediately" unless expected == Adamantine::DebugSessionState::ThreadExecution::ResumePending
    raise "inert thread projection must not retain the pre-request execution state" unless actual == expected
    raise "inert projection should preserve the bounded cached name" unless thread.try(&.name) == name
  ensure
    controller.try(&.close)
  end

  it "does not relabel a retained target when a launch review and project binding move" do
    root_a = inspection_fixture_root("retained-origin-a")
    root_b = inspection_fixture_root("retained-origin-b")
    controller = inspection_fixture_controller(root_a)
    initial = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }
    origin_stamp = initial.origin_project_stamp || raise "active target should have a retained directory identity"

    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    replacement_review = controller.prepare_launch(inspection_fixture_profile(root_b, adapter), root_b)
    raise "a review for another project should be constructible" unless replacement_review.valid?
    raise "new editor project should bind" unless controller.bind_project(root_b, initial.state.project_generation + 1_u64)

    rebound = controller.inspection_snapshot
    raise "reviewing another root must not relabel the active target" unless rebound.origin_project_root == root_a.to_s
    retained_stamp = rebound.origin_project_stamp || raise "target origin proof should survive editor rebinding"
    raise "editor rebinding must not replace the target directory proof" unless retained_stamp.same_target?(origin_stamp)
    raise "target origin must remain distinct from the new editor binding" if retained_stamp.same_target?(Adamantine::FileRevision.probe(root_b))
  ensure
    controller.try(&.close)
    FileUtils.rm_rf(root_a.to_s) if root_a
    FileUtils.rm_rf(root_b.to_s) if root_b
  end

  it "retains launch-time directory identity when that canonical path is replaced" do
    root = inspection_fixture_root("same-path-origin")
    replacement = inspection_fixture_root("same-path-replacement")
    moved_root = Path.new("#{root}.old")
    controller = inspection_fixture_controller(root)
    initial = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }
    origin_stamp = initial.origin_project_stamp || raise "active target should have a retained directory identity"

    File.rename(root.to_s, moved_root.to_s)
    File.rename(replacement.to_s, root.to_s)
    current_stamp = Adamantine::FileRevision.probe(root)
    raise "same-path replacement must have a different target identity" if origin_stamp.same_target?(current_stamp)

    retained = controller.inspection_snapshot
    raise "retained origin keeps the canonical string for diagnosis" unless retained.origin_project_root == root.to_s
    retained_stamp = retained.origin_project_stamp || raise "retained target identity should not be restamped from its current path"
    raise "snapshot must preserve the original directory identity" unless retained_stamp.same_target?(origin_stamp)
    raise "snapshot must not relabel the original target with the replacement directory" if retained_stamp.same_target?(current_stamp)
  ensure
    controller.try(&.close)
    FileUtils.rm_rf(root.to_s) if root
    FileUtils.rm_rf(replacement.to_s) if replacement
    FileUtils.rm_rf(moved_root.to_s) if moved_root
  end

  it "retains a selected stopped-thread stack during partial execution, then hides it on resume" do
    root = inspection_fixture_root("partial-stop")
    controller = inspection_fixture_controller(root, "pause_stop_before_ack")
    initial = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }
    raise "fixture must begin with a globally stopped target" unless initial.state.execution == Adamantine::DebugSessionState::Execution::Stopped

    raise "continue should be accepted" unless controller.continue.accepted?
    await_inspection_snapshot(controller) do |snapshot|
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Running
    end
    raise "pause should be accepted for the running thread" unless controller.pause.accepted?

    partial = await_inspection_snapshot(controller) do |snapshot|
      snapshot.stack_fresh && snapshot.state.execution == Adamantine::DebugSessionState::Execution::Partial
    end
    raise "the selected thread should remain stopped inside Partial execution" unless partial.state.thread_execution(42_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    raise "the current stopped-thread stack should remain observable" unless partial.state.selected_thread_id == 42_i64 && !partial.frames.empty?

    raise "resume from the selected stopped thread should be accepted" unless controller.continue.accepted?
    running = await_inspection_snapshot(controller) do |snapshot|
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Running
    end
    raise "the stack must be hidden after that thread resumes" if running.stack_fresh || !running.frames.empty?
  ensure
    controller.try(&.close)
  end

  it "hides the stack when a running thread becomes Unknown after an unconfirmed pause" do
    root = inspection_fixture_root("unknown-thread")
    controller = inspection_fixture_controller(root, "pause_ack_no_stop")
    await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }

    raise "continue should be accepted" unless controller.continue.accepted?
    await_inspection_snapshot(controller) do |snapshot|
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Running
    end
    raise "pause should be accepted" unless controller.pause.accepted?
    unknown = await_inspection_snapshot(controller, 4.seconds) do |snapshot|
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Unknown
    end
    raise "an Unknown thread cannot retain a fresh stack" if unknown.stack_fresh || !unknown.frames.empty?
    raise "the selected thread must remain explicitly Unknown" unless unknown.state.thread_execution(42_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
  ensure
    controller.try(&.close)
  end

  it "invalidates retained rows on project changes and fresh-session rebinding" do
    root = inspection_fixture_root("project-session-rebind")
    controller = inspection_fixture_controller(root)
    first = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }

    controller.project_changed(first.state.project_generation + 1_u64)
    project_changed = controller.inspection_snapshot
    raise "project generation changes must invalidate old stack evidence" if project_changed.stack_fresh || !project_changed.frames.empty?
    raise "the new project generation should be explicit" unless project_changed.state.project_generation == first.state.project_generation + 1_u64

    raise "Stop should be accepted after project change" unless controller.stop.accepted?
    deadline = Time.instant + 4.seconds
    until controller.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended && !controller.cleanup_pending?
      raise "old session did not become restartable" if Time.instant >= deadline
      controller.poll
      sleep 5.milliseconds
    end

    adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
    review = controller.prepare_launch(inspection_fixture_profile(root, adapter), root)
    raise "new session review should be valid" unless review.valid?
    raise "new session should start after prior cleanup" unless controller.start(review).accepted?
    between_sessions = controller.inspection_snapshot
    raise "old retained rows must not cross a debugger-session rebind" if between_sessions.stack_fresh || !between_sessions.frames.empty?

    rebound = await_inspection_snapshot(controller) { |snapshot| snapshot.stack_fresh }
    raise "the next stack must carry a new debugger-session generation" unless rebound.state.session_generation > first.state.session_generation
    raise "reused numeric IDs should be exposed only after the new stack is accepted" unless rebound.frames.map(&.id) == [500_i64, 501_i64]
  ensure
    controller.try(&.close)
  end

  it "keeps unloaded, pending, loaded-empty, failed, and partial scope values distinct" do
    empty_root = inspection_fixture_root("empty-scopes")
    empty_controller = inspection_fixture_controller(empty_root, "empty_scopes")
    await_inspection_snapshot(empty_controller) { |snapshot| snapshot.stack_fresh }
    unloaded = empty_controller.inspection_snapshot
    raise "before a request, scopes should be unloaded and idle" if unloaded.scopes_loaded || unloaded.scopes_request_pending || unloaded.scopes_error
    raise "scope roots should not be fabricated before loading" unless unloaded.variables.roots.empty?

    raise "empty scopes request should be accepted" unless empty_controller.open_scopes.accepted?
    pending = empty_controller.inspection_snapshot
    raise "request-pending must differ from unloaded" unless pending.scopes_request_pending && !pending.scopes_loaded
    raise "pending scopes must not fabricate values" unless pending.variables.roots.empty?
    loaded_empty = await_inspection_snapshot(empty_controller) { |snapshot| snapshot.scopes_loaded }
    raise "an accepted empty response is loaded, not pending" if loaded_empty.scopes_request_pending || loaded_empty.scopes_error
    raise "loaded-empty scopes must remain explicitly empty" unless loaded_empty.variables.roots.empty?
  ensure
    empty_controller.try(&.close)
  end

  it "retains explicit failed and partial variable states without evaluation" do
    failed_root = inspection_fixture_root("failed-scopes")
    failed_controller = inspection_fixture_controller(failed_root, "reject_scopes")
    await_inspection_snapshot(failed_controller) { |snapshot| snapshot.stack_fresh }
    raise "rejected scopes request should be accepted asynchronously" unless failed_controller.open_scopes.accepted?
    failed = await_inspection_snapshot(failed_controller) { |snapshot| !snapshot.scopes_request_pending && !snapshot.scopes_error.nil? }
    raise "failed scopes must not be represented as loaded" if failed.scopes_loaded
    raise "failed scopes must not invent roots" unless failed.variables.roots.empty?
    failed_controller.close

    partial_root = inspection_fixture_root("partial-variables")
    partial_controller = inspection_fixture_controller(partial_root, "value_format")
    await_inspection_snapshot(partial_controller) { |snapshot| snapshot.stack_fresh }
    raise "partial fixture scopes request should be accepted" unless partial_controller.open_scopes.accepted?
    partial = await_inspection_snapshot(partial_controller) do |snapshot|
      snapshot.scopes_loaded && snapshot.variables.partial?
    end
    root_node = partial.variables.roots.first?
    raise "partial variable data must preserve its root state" unless root_node && root_node.not_nil!.load_state == Adamantine::Debugging::DebugVariableLoadState::Partial
    raise "inspection must not evaluate retained values" if inspection_adapter_commands(partial_root).includes?("evaluate")
  ensure
    failed_controller.try(&.close)
    partial_controller.try(&.close)
  end
end
