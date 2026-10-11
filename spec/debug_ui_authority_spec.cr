require "spec"
require "file_utils"
require "json"
require "random/secure"
require "crystal_tui"
require "./support/debugger_fixture_support"

require "../src/adamantine/app"

private class DebugUiAuthorityTestApp < Adamantine::App
  def debug_panel_public : Adamantine::DebugPanel
    @debug_workspace.panel
  end

  def debug_panel_focused_public? : Bool
    Tui::Widget.focused_widget == @debug_workspace.panel
  end

  def show_debug_panel_public : Bool
    shown = debug_show_panel(true)
    refresh
    shown
  end

  def open_watch_form_public : Nil
    open_debug_watch_form
  end

  def open_profile_form_public : Nil
    open_debug_profile_form
  end

  def seed_profile_fields_public(adapter_argv : Array(String), program : String, cwd : String,
                                 target_argv : Array(String)) : Nil
    @debug_form_fields[0].value = adapter_argv.to_json
    @debug_form_fields[1].value = program
    @debug_form_fields[2].value = cwd
    @debug_form_fields[3].value = target_argv.to_json
  end

  def debug_screen_public(width : Int32 = 112, height : Int32 = 30) : String
    surface = Tui::Buffer.new(width, height)
    render(surface, Tui::Rect.new(0, 0, width, height))
    String.build do |output|
      height.times do |y|
        width.times { |x| output << surface.get(x, y).glyph }
        output << '\n'
      end
    end
  end

  def poll_debug_public : Nil
    debug_poll_and_project
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
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

  def close_debug_public : Nil
    close_debug_ui
  end
end

private def with_debug_ui_authority_root(label : String, &block : Path ->)
  candidate = Path.new(Dir.tempdir, "adamantine-debug-ui-authority-#{label}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(candidate.to_s)
  root = Path.new(File.realpath(candidate.to_s))
  yield root
ensure
  FileUtils.rm_rf(root.to_s) if root
end

private def debug_ui_authority_profile(root : Path, adapter : Path, log_path : Path,
                                       mode : String = "basic",
                                       source_path : Path? = nil) : Adamantine::Debugging::LaunchProfile
  ruby = DebuggerFixtureSupport.ruby_executable
  program = Process.find_executable("true") || "/usr/bin/true"
  argv = [ruby, adapter.to_s, log_path.to_s, mode]
  argv << source_path.not_nil!.to_s if source_path
  Adamantine::Debugging::LaunchProfile.new(
    id: "debug-ui-authority",
    name: "UI authority fixture",
    adapter_argv: argv,
    program: File.realpath(program),
    cwd: root.to_s
  )
end

private def debug_ui_authority_requests(path : Path) : Array(JSON::Any)
  return [] of JSON::Any unless File.file?(path.to_s)
  File.read(path.to_s).lines.compact_map do |line|
    JSON.parse(line)
  rescue JSON::ParseException
    nil
  end.compact
end

private def debug_ui_evaluate_requests(path : Path) : Array(JSON::Any)
  debug_ui_authority_requests(path).select do |item|
    item["type"]?.try(&.as_s?) == "request" && item["command"]?.try(&.as_s?) == "evaluate"
  end
end

private def wait_for_debug_ui_authority(app : DebugUiAuthorityTestApp,
                                        controller : Adamantine::DebugController,
                                        timeout : Time::Span = 5.seconds,
                                        &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  loop do
    app.on_capture(Tui::WakeupEvent.new)
    snapshot = controller.snapshot
    return snapshot if ready.call(snapshot)
    raise "debug UI fixture did not reach the expected state: lifecycle=#{snapshot.state.lifecycle}, execution=#{snapshot.state.execution}, cleanup=#{snapshot.cleanup_pending}" if Time.monotonic >= deadline
    sleep 5.milliseconds
  end
end

private def cleanup_debug_ui_authority(app : DebugUiAuthorityTestApp?,
                                       controller : Adamantine::DebugController?,
                                       client : Adamantine::Dap::Client?) : Nil
  if controller
    current = controller.not_nil!.snapshot
    if current.state.lifecycle.in?(
         Adamantine::DebugSessionState::Lifecycle::Starting,
         Adamantine::DebugSessionState::Lifecycle::Configuring,
         Adamantine::DebugSessionState::Lifecycle::Active,
         Adamantine::DebugSessionState::Lifecycle::Disconnecting
       )
      controller.not_nil!.stop
    end
    app.try(&.close_debug_public)
    controller.not_nil!.close
    deadline = Time.monotonic + 5.seconds
    loop do
      snapshot = controller.not_nil!.poll
      adapter_retired = client.nil? || client.not_nil!.retired?
      controller_terminal = if client.nil?
                              snapshot.state.lifecycle.in?(
                                Adamantine::DebugSessionState::Lifecycle::Idle,
                                Adamantine::DebugSessionState::Lifecycle::Ended,
                                Adamantine::DebugSessionState::Lifecycle::Failed
                              )
                            else
                              snapshot.state.lifecycle.in?(
                                Adamantine::DebugSessionState::Lifecycle::Ended,
                                Adamantine::DebugSessionState::Lifecycle::Failed
                              )
                            end
      break if adapter_retired && controller_terminal && !snapshot.cleanup_pending
      raise "fixture adapter did not reach terminal retirement before the cleanup deadline: lifecycle=#{snapshot.state.lifecycle}, cleanup=#{snapshot.cleanup_pending}, retired=#{adapter_retired}" if Time.monotonic >= deadline
      sleep 5.milliseconds
    end
    final = controller.not_nil!.snapshot
    raise "fixture controller cleanup remained pending" if final.cleanup_pending
    raise "fixture controller remained non-terminal: #{final.state.lifecycle}" unless final.state.lifecycle.in?(
                                                                                        Adamantine::DebugSessionState::Lifecycle::Idle,
                                                                                        Adamantine::DebugSessionState::Lifecycle::Ended,
                                                                                        Adamantine::DebugSessionState::Lifecycle::Failed
                                                                                      )
    raise "owned adapter was not retired" if client && !client.not_nil!.retired?
  end
end

describe "debugger App authority presentation" do
  it "requires visible confirmation before a Watch evaluation and sends it once for the selected frame" do
    with_debug_ui_authority_root("watch") do |root|
      adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
      log_path = root / "adapter.jsonl"
      client : Adamantine::Dap::Client? = nil
      factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
        client = Adamantine::Dap::Client.new(argv, cwd)
      end
      controller = Adamantine::DebugController.new(factory)
      app = DebugUiAuthorityTestApp.new(
        project_root: root,
        lsp_command: "",
        recovery_root: root / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      app.mount_headless(112, 30)

      review = controller.prepare_launch(debug_ui_authority_profile(root, adapter, log_path), root)
      raise "fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      raise "fixture launch should be accepted" unless controller.start(review).accepted?
      stopped = wait_for_debug_ui_authority(app, controller) do |snapshot|
        snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          snapshot.state.execution.stopped? &&
          !snapshot.frames.empty? && !snapshot.state.selected_frame_id.nil?
      end
      selected_frame_id = stopped.state.selected_frame_id || raise "fixture has no selected frame"

      app.open_watch_form_public
      app.on_capture(Tui::PasteEvent.new("local_value")).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.poll_debug_public
      added = controller.snapshot.watches.last? || raise "Watch form did not add the expression"
      added.expression.should eq("local_value")
      added.status.should eq(Adamantine::DebugController::WatchStatus::NotEvaluated)
      app.debug_panel_public.total_rows(Adamantine::DebugPanel::Pane::Watch).should eq(1)

      3.times do
        app.on_capture(Tui::WakeupEvent.new).should be_true
        app.debug_screen_public
      end
      debug_ui_evaluate_requests(log_path).size.should eq(0)

      app.show_debug_panel_public.should be_true
      panel = app.debug_panel_public
      panel.selected_pane = Adamantine::DebugPanel::Pane::Watch
      panel.focus
      panel.on_event(Tui::KeyEvent.new('e')).should be_true
      warning = app.debug_screen_public
      warning.should contain("Evaluation may execute code in the debuggee.")
      warning.should contain("Enter: Evaluate explicitly")
      debug_ui_evaluate_requests(log_path).size.should eq(0)

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      debug_ui_evaluate_requests(log_path).size.should eq(0)

      panel.focus
      panel.on_event(Tui::KeyEvent.new('e')).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      evaluated = wait_for_debug_ui_authority(app, controller) do |snapshot|
        requests = debug_ui_evaluate_requests(log_path)
        watch = snapshot.watches.find { |item| item.id == added.id }
        requests.size == 1 && watch.try(&.status) == Adamantine::DebugController::WatchStatus::Available
      end
      evaluated_watch = evaluated.watches.find { |item| item.id == added.id }.not_nil!
      evaluated_watch.result.should eq("fixture-result:local_value")
      requests = debug_ui_evaluate_requests(log_path)
      requests.size.should eq(1)
      args = requests.first["arguments"].as_h
      args["expression"].as_s.should eq("local_value")
      args["frameId"].as_i64.should eq(selected_frame_id)
      args["context"].as_s.should eq("watch")
    ensure
      cleanup_debug_ui_authority(app, controller, client)
    end
  end

  it "shows adapter argv as a literal JSON array in the explicit launch review" do
    with_debug_ui_authority_root("argv-review") do |root|
      executable = File.realpath(Process.find_executable("true") || "/usr/bin/true")
      argv = [executable, "--argument with spaces", "quoted\"value"]
      factory_calls = 0
      factory : Adamantine::DebugController::ClientFactory = ->(adapter_argv : Array(String), cwd : Path) do
        factory_calls += 1
        Adamantine::Dap::Client.new(adapter_argv, cwd)
      end
      controller = Adamantine::DebugController.new(factory)
      app = DebugUiAuthorityTestApp.new(
        project_root: root,
        lsp_command: "",
        recovery_root: root / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      app.mount_headless(112, 30)
      app.open_profile_form_public
      app.seed_profile_fields_public(argv, executable, root.to_s, ["target argument"])
      4.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab)) }
      app.debug_screen_public.should contain("> Values: Adapter (default)")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true

      review = app.debug_screen_public
      review.should contain("Review launch; Enter starts explicitly")
      review.should contain("Adapter argv: #{argv.to_json}")
      factory_calls.should eq(0)
    ensure
      cleanup_debug_ui_authority(app, controller, nil)
    end
  end

  it "keeps the execution marker at the top stopped frame while selecting the historical caller" do
    with_debug_ui_authority_root("historical-frame") do |root|
      adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
      source = root / "main.cr"
      contents = (1..16).map { |line| "line #{line}\n" }.join
      File.write(source.to_s, contents)
      source = Path.new(File.realpath(source.to_s))
      log_path = root / "adapter.jsonl"
      client : Adamantine::Dap::Client? = nil
      factory : Adamantine::DebugController::ClientFactory = ->(argv : Array(String), cwd : Path) do
        client = Adamantine::Dap::Client.new(argv, cwd)
      end
      controller = Adamantine::DebugController.new(factory)
      app = DebugUiAuthorityTestApp.new(
        project_root: root,
        lsp_command: "",
        recovery_root: root / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      app.mount_headless(112, 30)
      app.open_file_public(source).should be_true
      app.open_second_shared_view_public(source).should be_true
      app.debug_view_execution_lines_public(source).size.should eq(2)

      # The helper changes App.rect directly. Model the normal headless frame
      # lifecycle so the nested inspector has real geometry before it is shown.
      app.refresh
      app.debug_screen_public(180, 40)

      profile = debug_ui_authority_profile(root, adapter, log_path, "source_checksum", source)
      baseline = Adamantine::DebugController::SourceBaseline.new(source, contents)
      review = controller.prepare_launch(profile, root, [baseline])
      raise "checksum fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      raise "fixture launch should be accepted" unless controller.start(review).accepted?
      stopped = wait_for_debug_ui_authority(app, controller) do |snapshot|
        snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          snapshot.state.execution.stopped? && snapshot.frames.size >= 2 &&
          snapshot.sources.any? { |item| item.key == Adamantine::Debugging::DebugSourceKey.local(source.to_s) && item.checksum_status == Adamantine::Debugging::ChecksumStatus::Match }
      end
      top_frame = stopped.frames.first
      historical_frame = stopped.frames.last
      top_line = top_frame.editor_line || raise "top frame did not map to the retained source"
      historical_line = historical_frame.editor_line || raise "caller frame did not map to the retained source"
      top_line.should_not eq(historical_line)
      app.debug_view_execution_lines_public(source).should eq([top_line, top_line])

      app.show_debug_panel_public.should be_true
      app.debug_panel_focused_public?.should be_true
      panel = app.debug_panel_public
      panel.selected_pane.should eq(Adamantine::DebugPanel::Pane::Stack)
      panel.total_rows(Adamantine::DebugPanel::Pane::Stack).should eq(2)
      panel.on_event(Tui::KeyEvent.new('j')).should be_true
      app.poll_debug_public
      controller.snapshot.state.selected_frame_id.should eq(historical_frame.id)
      app.debug_view_execution_lines_public(source).should eq([top_line, top_line])
    ensure
      cleanup_debug_ui_authority(app, controller, client)
    end
  end
end
