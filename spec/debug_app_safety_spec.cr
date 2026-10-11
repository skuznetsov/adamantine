require "spec"
require "file_utils"
require "random/secure"
require "crystal_tui"
require "./support/debugger_fixture_support"

require "../src/adamantine/app"

private class DebugAppSafetyController < Adamantine::DebugController
  property stop_calls : Int32 = 0

  def stop : ActionSubmission
    @stop_calls += 1
    super
  end
end

private class DebugAppSafetyTestApp < Adamantine::App
  def project_root_public : String
    @project_root.to_s
  end

  def project_generation_public : UInt64
    @debug_project_generation
  end

  def run_command_public(command : String) : Nil
    @command_palette.open = true
    execute_command(":#{command}")
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def edit_buffer_public(path : Path, text : String) : Nil
    buffer = @document_session.open_buffers[path.to_s] || raise "missing buffer #{path}"
    buffer.editor.insert_text(text)
  end

  def buffer_version_public(path : Path) : Int32
    @document_session.open_buffers[path.to_s]?.try(&.version) || raise "missing buffer #{path}"
  end

  def buffer_modified_public(path : Path) : Bool
    @document_session.open_buffers[path.to_s]?.try(&.editor.modified?) || false
  end

  def buffer_paths_public : Array(String)
    @document_session.open_buffers.keys.sort
  end

  def current_buffer_path_public : String?
    @document_orchestrator.current_buffer.try(&.path.to_s)
  end

  def editor_tab_paths_public : Array(String)
    editor_tab_groups.flat_map { |group| group.tabs.map(&.id) }.sort
  end

  def close_review_open_public? : Bool
    close_confirmation_active?
  end

  def debug_transition_modal_open_public? : Bool
    @debug_modal_kind == DebugModalKind::AppTransition
  end

  def debug_transition_stop_requested_public? : Bool
    @debug_transition_stop_requested
  end

  def app_input_closed_public? : Bool
    @input.events.closed?
  end

  # A false result means the monitor was already live; true means this call
  # had to start it, which would expose an accidental Stop during Cancel.
  def start_monitor_again_public : Bool
    @document_orchestrator.start_external_file_monitor
  end

  def focus_editor_public : Bool
    focus_editor_action
  end

  def open_second_shared_view_public(path : Path) : Bool
    self.rect = Tui::Rect.new(0, 0, 180, 40)
    split_editor_right
    open_file(path)
  end

  def debug_view_execution_lines_public(path : Path) : Array(Int32?)
    buffer = @document_session.open_buffers[path.to_s] || raise "missing buffer #{path}"
    @document_session.views_for(buffer).compact_map(&.as?(Adamantine::EditingTextEditor)).map(&.debug_execution_line)
  end

  def poll_debug_public : Nil
    debug_poll_and_project
  end

  def debug_controller_snapshot_public : Adamantine::DebugController::Snapshot
    @debug_controller.snapshot
  end

  def dispatch_public(event : Tui::Event) : Bool
    handle_event(event)
  end

  def cleanup_debug_public : Nil
    close_debug_ui
  end
end

private def with_debug_app_safety_workspace(label : String, &block : Path ->)
  candidate = Path.new(Dir.tempdir, "adamantine-debug-app-#{label}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(candidate.to_s)
  root = Path.new(File.realpath(candidate.to_s))
  yield root
ensure
  FileUtils.rm_rf(root.to_s) if root
end

private def safety_fixture_profile(root : Path, mode : String, release_path : Path? = nil,
                                   source_path : Path? = nil) : Adamantine::Debugging::LaunchProfile
  fixture = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
  ruby = DebuggerFixtureSupport.ruby_executable
  executable = Process.find_executable("true") || "/usr/bin/true"
  argv = [ruby, fixture.to_s, (root / "adapter.jsonl").to_s, mode]
  argv << source_path.not_nil!.to_s if source_path
  argv << release_path.not_nil!.to_s if release_path
  Adamantine::Debugging::LaunchProfile.new(
    id: "app-safety-fixture",
    name: "App safety fixture",
    adapter_argv: argv,
    program: File.realpath(executable),
    cwd: root.to_s
  )
end

private def safety_keymap_path(root : Path) : String
  path = root / "keymap.json"
  File.write(path.to_s, %({"keymap":{}}))
  path.to_s
end

private def await_app_snapshot(app : DebugAppSafetyTestApp,
                               timeout : Time::Span = 4.seconds,
                               &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  loop do
    app.on_capture(Tui::WakeupEvent.new)
    snapshot = app.debug_controller_snapshot_public
    return snapshot if ready.call(snapshot)
    raise "App debugger did not reach the expected state: lifecycle=#{snapshot.state.lifecycle}, cleanup=#{snapshot.cleanup_pending}" if Time.monotonic >= deadline
    sleep 5.milliseconds
  end
end

private def await_fixture_marker(app : DebugAppSafetyTestApp, log_path : Path, marker : String,
                                 timeout : Time::Span = 3.seconds) : Nil
  deadline = Time.monotonic + timeout
  until File.file?(log_path.to_s) && File.read(log_path.to_s).includes?(marker)
    app.on_capture(Tui::WakeupEvent.new)
    raise "fixture did not emit #{marker}" if Time.monotonic >= deadline
    sleep 5.milliseconds
  end
end

private def start_safety_fixture(controller : DebugAppSafetyController, root : Path,
                                 mode : String, release_path : Path? = nil,
                                 source_path : Path? = nil) : Nil
  profile = safety_fixture_profile(root, mode, release_path, source_path)
  review = controller.prepare_launch(profile, root)
  raise "fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
  raise "fixture launch should be accepted" unless controller.start(review).accepted?
end

private def cleanup_debug_app(app : DebugAppSafetyTestApp?, controller : DebugAppSafetyController?,
                              release_path : Path? = nil) : Nil
  File.write(release_path.not_nil!.to_s, "release") if release_path
  if controller
    current = controller.not_nil!.snapshot
    if current.state.lifecycle.in?(Adamantine::DebugSessionState::Lifecycle::Starting,
         Adamantine::DebugSessionState::Lifecycle::Configuring,
         Adamantine::DebugSessionState::Lifecycle::Active,
         Adamantine::DebugSessionState::Lifecycle::Disconnecting)
      controller.not_nil!.stop
    end
    deadline = Time.monotonic + 4.seconds
    until !controller.not_nil!.cleanup_pending? || Time.monotonic >= deadline
      controller.not_nil!.poll
      sleep 5.milliseconds
    end
    controller.not_nil!.close
    20.times do
      break unless controller.not_nil!.cleanup_pending?
      controller.not_nil!.poll
      sleep 5.milliseconds
    end
  end
  if app
    app.not_nil!.poll_debug_public
    app.not_nil!.quit(force: true) unless app.not_nil!.app_input_closed_public?
  end
end

describe "debugger-aware App transitions" do
  it "keeps dirty root-change and Quit Cancel free of debugger and monitor side effects" do
    with_debug_app_safety_workspace("cancel") do |parent|
      root_a = parent / "project-a"
      root_b = parent / "project-b"
      Dir.mkdir_p(root_a.to_s)
      Dir.mkdir_p(root_b.to_s)
      root_a = Path.new(File.realpath(root_a.to_s))
      root_b = Path.new(File.realpath(root_b.to_s))
      source = root_a / "main.cr"
      File.write(source.to_s, "puts 1\n")

      factory_calls = [0]
      factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
        factory_calls[0] += 1
        Adamantine::Dap::Client.new(argv, cwd)
      end
      controller = DebugAppSafetyController.new(factory)
      app = DebugAppSafetyTestApp.new(
        project_root: root_a,
        lsp_command: "",
        keymap_path: safety_keymap_path(parent),
        recovery_root: parent / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      app.open_file_public(source).should be_true
      app.edit_buffer_public(source, "!")
      app.buffer_modified_public(source).should be_true
      tabs_before = app.editor_tab_paths_public
      buffers_before = app.buffer_paths_public
      active_before = app.current_buffer_path_public
      app.start_monitor_again_public.should be_true

      app.run_command_public("cd #{root_b}")
      app.close_review_open_public?.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.project_root_public.should eq(root_a.to_s)
      app.editor_tab_paths_public.should eq(tabs_before)
      app.buffer_paths_public.should eq(buffers_before)
      app.current_buffer_path_public.should eq(active_before)
      controller.stop_calls.should eq(0)
      factory_calls[0].should eq(0)
      app.start_monitor_again_public.should be_false

      app.run_command_public("quit")
      app.close_review_open_public?.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.app_input_closed_public?.should be_false
      app.project_root_public.should eq(root_a.to_s)
      app.editor_tab_paths_public.should eq(tabs_before)
      app.buffer_paths_public.should eq(buffers_before)
      app.current_buffer_path_public.should eq(active_before)
      controller.stop_calls.should eq(0)
      factory_calls[0].should eq(0)
      app.start_monitor_again_public.should be_false
    ensure
      cleanup_debug_app(app, controller)
    end
  end

  it "commits a clean :cd with a new debugger generation and accepts F9 in the new root" do
    with_debug_app_safety_workspace("root-commit") do |parent|
      root_a = parent / "project-a"
      root_b = parent / "project-b"
      Dir.mkdir_p(root_a.to_s)
      Dir.mkdir_p(root_b.to_s)
      root_a = Path.new(File.realpath(root_a.to_s))
      root_b = Path.new(File.realpath(root_b.to_s))
      source_b = root_b / "main.cr"
      File.write(source_b.to_s, "puts 2\n")
      factory_calls = [0]
      factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
        factory_calls[0] += 1
        Adamantine::Dap::Client.new(argv, cwd)
      end
      controller = DebugAppSafetyController.new(factory)
      app = DebugAppSafetyTestApp.new(
        project_root: root_a,
        lsp_command: "",
        keymap_path: safety_keymap_path(parent),
        recovery_root: parent / "recovery",
        session_enabled: false,
        debug_controller: controller
      )

      app.run_command_public("cd #{root_b}")
      app.project_root_public.should eq(root_b.to_s)
      app.project_generation_public.should eq(1_u64)
      controller.state.project_generation.should eq(1_u64)
      app.open_file_public(source_b).should be_true
      app.focus_editor_public.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::F9)).should be_true
      controller.snapshot.breakpoints.map(&.source_key).should contain(Adamantine::Debugging::DebugSourceKey.local(source_b.to_s))
      factory_calls[0].should eq(0)
    ensure
      cleanup_debug_app(app, controller)
    end
  end

  it "waits for a correlated Stop and adapter cleanup before committing :cd" do
    with_debug_app_safety_workspace("held-root-stop") do |parent|
      root_a = parent / "project-a"
      root_b = parent / "project-b"
      Dir.mkdir_p(root_a.to_s)
      Dir.mkdir_p(root_b.to_s)
      root_a = Path.new(File.realpath(root_a.to_s))
      root_b = Path.new(File.realpath(root_b.to_s))
      release = parent / "release-stop"
      factory_calls = [0]
      clients = [] of Adamantine::Dap::Client
      factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
        factory_calls[0] += 1
        client = Adamantine::Dap::Client.new(argv, cwd)
        clients << client
        client
      end
      controller = DebugAppSafetyController.new(factory)
      app = DebugAppSafetyTestApp.new(
        project_root: root_a,
        lsp_command: "",
        keymap_path: safety_keymap_path(parent),
        recovery_root: parent / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      start_safety_fixture(controller, root_a, "hold_disconnect", release)
      await_app_snapshot(app) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }
      app.run_command_public("cd #{root_b}")
      app.debug_transition_modal_open_public?.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      controller.stop_calls.should eq(1)
      await_fixture_marker(app, root_a / "adapter.jsonl", "disconnect_received")
      app.project_root_public.should eq(root_a.to_s)
      app.project_generation_public.should eq(0_u64)
      app.debug_transition_stop_requested_public?.should be_true
      app.debug_controller_snapshot_public.state.lifecycle.should eq(Adamantine::DebugSessionState::Lifecycle::Disconnecting)

      File.write(release.to_s, "release")
      await_app_snapshot(app, 5.seconds) do |snapshot|
        snapshot.state.lifecycle.in?(Adamantine::DebugSessionState::Lifecycle::Ended, Adamantine::DebugSessionState::Lifecycle::Failed) && !snapshot.cleanup_pending
      end
      app.project_root_public.should eq(root_b.to_s)
      app.project_generation_public.should eq(1_u64)
      controller.state.project_generation.should eq(1_u64)
      clients.size.should eq(1)
      clients.first.retired?.should be_true
      clients.first.owned_adapter_alive?.should be_false
      factory_calls[0].should eq(1)
    ensure
      cleanup_debug_app(app, controller, release)
    end
  end

  it "reopens dirty review when an approved buffer changes during held Stop" do
    with_debug_app_safety_workspace("stale-close-target") do |parent|
      root_a = parent / "project-a"
      root_b = parent / "project-b"
      Dir.mkdir_p(root_a.to_s)
      Dir.mkdir_p(root_b.to_s)
      root_a = Path.new(File.realpath(root_a.to_s))
      root_b = Path.new(File.realpath(root_b.to_s))
      source = root_a / "main.cr"
      File.write(source.to_s, "puts 1\n")
      release = parent / "release-stop"
      controller = DebugAppSafetyController.new(->(argv : Array(String), cwd : Path) {
        Adamantine::Dap::Client.new(argv, cwd)
      })
      app = DebugAppSafetyTestApp.new(
        project_root: root_a,
        lsp_command: "",
        keymap_path: safety_keymap_path(parent),
        recovery_root: parent / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      app.open_file_public(source).should be_true
      app.edit_buffer_public(source, "!")
      app.buffer_modified_public(source).should be_true
      start_safety_fixture(controller, root_a, "hold_disconnect", release)
      await_app_snapshot(app) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }

      app.run_command_public("cd #{root_b}")
      app.close_review_open_public?.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_transition_modal_open_public?.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      await_fixture_marker(app, root_a / "adapter.jsonl", "disconnect_received")

      approved_version = app.buffer_version_public(source)
      app.edit_buffer_public(source, "concurrent")
      app.buffer_version_public(source).should be > approved_version
      File.write(release.to_s, "release")
      await_app_snapshot(app, 5.seconds) do |snapshot|
        snapshot.state.lifecycle.in?(Adamantine::DebugSessionState::Lifecycle::Ended, Adamantine::DebugSessionState::Lifecycle::Failed) && !snapshot.cleanup_pending
      end
      app.project_root_public.should eq(root_a.to_s)
      app.project_generation_public.should eq(0_u64)
      app.close_review_open_public?.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.project_root_public.should eq(root_a.to_s)
      app.buffer_modified_public(source).should be_true
    ensure
      cleanup_debug_app(app, controller, release)
    end
  end

  it "does not commit Quit while approved Stop cleanup is held" do
    with_debug_app_safety_workspace("held-quit-stop") do |parent|
      root = Path.new(File.realpath(parent.to_s))
      release = parent / "release-stop"
      controller = DebugAppSafetyController.new(->(argv : Array(String), cwd : Path) {
        Adamantine::Dap::Client.new(argv, cwd)
      })
      app = DebugAppSafetyTestApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: safety_keymap_path(parent),
        recovery_root: parent / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      start_safety_fixture(controller, root, "hold_disconnect", release)
      await_app_snapshot(app) { |snapshot| snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active }
      app.run_command_public("quit")
      app.debug_transition_modal_open_public?.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      await_fixture_marker(app, root / "adapter.jsonl", "disconnect_received")
      app.app_input_closed_public?.should be_false
      app.debug_transition_stop_requested_public?.should be_true
      controller.state.lifecycle.should eq(Adamantine::DebugSessionState::Lifecycle::Disconnecting)

      File.write(release.to_s, "release")
      await_app_snapshot(app, 5.seconds) do |snapshot|
        snapshot.state.lifecycle.in?(Adamantine::DebugSessionState::Lifecycle::Ended, Adamantine::DebugSessionState::Lifecycle::Failed) && !snapshot.cleanup_pending
      end
      app.app_input_closed_public?.should be_true
    ensure
      cleanup_debug_app(app, controller, release)
    end
  end

  it "retires checksum-backed execution precision in every shared view after an edit" do
    with_debug_app_safety_workspace("shared-source-edit") do |root|
      project = root / "project"
      Dir.mkdir_p(project.to_s)
      project = Path.new(File.realpath(project.to_s))
      source = project / "main.cr"
      contents = (1..16).map { |line| "line #{line}\n" }.join
      File.write(source.to_s, contents)
      controller = DebugAppSafetyController.new(->(argv : Array(String), cwd : Path) {
        Adamantine::Dap::Client.new(argv, cwd)
      })
      app = DebugAppSafetyTestApp.new(
        project_root: project,
        lsp_command: "",
        keymap_path: safety_keymap_path(root),
        recovery_root: root / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      app.open_file_public(source).should be_true
      app.open_second_shared_view_public(source).should be_true
      app.debug_view_execution_lines_public(source).size.should eq(2)

      profile = safety_fixture_profile(project, "source_checksum", source_path: source)
      baseline = Adamantine::DebugController::SourceBaseline.new(source, contents)
      review = controller.prepare_launch(profile, project, [baseline])
      raise "checksum fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      raise "checksum fixture launch should be accepted" unless controller.start(review).accepted?
      active = await_app_snapshot(app) do |snapshot|
        snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          snapshot.frames.any?(&.selected) &&
          snapshot.sources.any? { |item| item.key == Adamantine::Debugging::DebugSourceKey.local(source.to_s) && item.checksum_status == Adamantine::Debugging::ChecksumStatus::Match }
      end
      selected_frame = active.frames.find(&.selected) || raise "fixture must select a source-backed frame"
      expected_line = selected_frame.editor_line || raise "checksum-matched fixture frame must resolve to an editor line"
      before_lines = app.debug_view_execution_lines_public(source)
      before_lines.should eq([expected_line, expected_line])

      app.edit_buffer_public(source, "!")
      app.poll_debug_public
      edited_source = controller.snapshot.sources.find { |item| item.key == Adamantine::Debugging::DebugSourceKey.local(source.to_s) }
      edited_source.should_not be_nil
      edited_source.not_nil!.checksum_status.should eq(Adamantine::Debugging::ChecksumStatus::Match)
      edited_source.not_nil!.outdated.should be_true
      app.debug_view_execution_lines_public(source).should eq([nil, nil])
    ensure
      cleanup_debug_app(app, controller)
    end
  end
end
