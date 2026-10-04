require "spec"
require "file_utils"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private class DebugEditorIntegrationApp < Adamantine::App
  def panel_public : Adamantine::DebugPanel
    @debug_workspace.panel
  end

  def show_debug_panel_public : Bool
    shown = debug_show_panel(true)
    refresh
    shown
  end

  def layout_debug_panel_public : Nil
    refresh
    render(Tui::Buffer.new(100, 32), Tui::Rect.new(0, 0, 100, 32))
  end

  def debug_screen_public(width : Int32 = 112, height : Int32 = 26) : String
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

  def close_debug_public : Nil
    close_debug_ui
  end

  def debug_command_actions_public : Array(String)
    command_palette_entries.map(&.action)
  end

  def dispatch_debug_event_public(event : Tui::Event) : Bool
    handle_event(event)
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def open_second_shared_view_public(path : Path) : Bool
    self.rect = Tui::Rect.new(0, 0, 180, 40)
    split_editor_right
    open_file(path)
  end

  def project_debug_snapshot_public(snapshot : Adamantine::DebugController::Snapshot) : Nil
    @debug_snapshot = snapshot
    debug_project_gutters
  end

  def close_debug_split_public : Nil
    close_editor_split
    debug_project_gutters
  end

  def debug_gutter_callback_count_public : Int32
    @debug_gutter_callbacks.size
  end

  def preseed_current_view_gutter_callback_id_public(path : Path) : Nil
    buffer = @document_session.open_buffers[path.to_s] || raise "missing buffer #{path}"
    view = @document_session.views_for(buffer).last? || raise "missing editor view #{path}"
    @debug_gutter_callbacks << view.object_id
  end

  def click_current_view_breakpoint_lane_public(path : Path, line : Int32) : Bool
    buffer = @document_session.open_buffers[path.to_s] || raise "missing buffer #{path}"
    editor = @document_session.views_for(buffer).compact_map(&.as?(Adamantine::EditingTextEditor)).last? ||
             raise "missing editable view #{path}"
    editor.show_line_numbers = false
    editor.show_fold_gutter = false
    editor.show_scrollbar = false
    editor.rect = Tui::Rect.new(0, 0, 20, 4)
    editor.on_event(Tui::MouseEvent.new(0, line))
  end

  def projected_breakpoint_count_public : Int32
    @debug_snapshot.breakpoints.size
  end

  def debug_view_markers_public(path : Path) : Array(Tuple(Int32?, Int32?))
    buffer = @document_session.open_buffers[path.to_s] || raise "missing buffer #{path}"
    @document_session.views_for(buffer).compact_map(&.as?(Adamantine::EditingTextEditor)).map do |editor|
      {editor.debug_execution_line, editor.debug_inspection_line}
    end
  end

  def debug_view_breakpoint_sets_public(path : Path) : Array(Tuple(Set(Int32), Set(Int32)))
    buffer = @document_session.open_buffers[path.to_s] || raise "missing buffer #{path}"
    @document_session.views_for(buffer).compact_map(&.as?(Adamantine::EditingTextEditor)).map do |editor|
      {editor.debug_breakpoint_lines, editor.debug_inactive_breakpoint_lines}
    end
  end

  def debug_view_breakpoint_glyphs_public(path : Path, line_count : Int32) : Array(Array(String))
    buffer = @document_session.open_buffers[path.to_s] || raise "missing buffer #{path}"
    @document_session.views_for(buffer).compact_map(&.as?(Adamantine::EditingTextEditor)).map do |editor|
      editor.show_fold_gutter = false
      editor.show_line_numbers = false
      editor.rect = Tui::Rect.new(0, 0, 20, line_count)
      surface = Tui::Buffer.new(20, line_count)
      editor.render(surface, Tui::Rect.new(0, 0, 20, line_count))
      Array.new(line_count) { |line| surface.get(0, line).glyph }
    end
  end

  def set_debug_rows_public(pane : Adamantine::DebugPanel::Pane, rows : Array(String)) : Nil
    @debug_workspace.panel.set_lines(pane, rows)
  end

  def debug_selected_pane_public : Adamantine::DebugPanel::Pane
    @debug_workspace.panel.selected_pane
  end

  def debug_selected_row_public : Int32
    @debug_workspace.panel.selected_row
  end

  def debug_panel_focused_public : Bool
    @debug_workspace.panel.focused?
  end

  def active_editor_focused_public? : Bool
    active_editor_internal.try(&.focused?) == true
  end

  def refresh_debug_projection_public : Nil
    @debug_projected_generation = UInt64::MAX
    debug_poll_and_project
  end

  def debug_panel_rows_public : Int32
    @debug_workspace.panel.total_rows(@debug_workspace.panel.selected_pane)
  end

  def debug_modal_active_public : Bool
    debug_modal_active?
  end

  def debug_candidate_profile_public : Adamantine::Debugging::LaunchProfile?
    @debug_candidate_profile
  end

  def seed_debug_profile_public(profile : Adamantine::Debugging::LaunchProfile) : Nil
    result = @debug_profile_store.save(@project_root, [profile], profile.id)
    raise "could not seed the inert test profile: #{result.warnings.join("; ")}" unless result.saved?
  end

  def document_text_public(path : Path) : String
    @document_session.open_buffers[path.to_s].not_nil!.editor.document.buffer.text
  end

  def show_help_public : Array(String)
    show_help
    @status_log.entries.map(&.message)
  end

  def set_key_hint_public(action : String, binding : String) : Nil
    @key_bindings[action] = [binding]
  end

  def dirty_buffer_public(path : Path) : Nil
    buffer = @document_session.open_buffers[path.to_s] || raise "missing buffer #{path}"
    buffer.editor.insert_text("changed")
  end

  def request_root_change_public(root : Path) : Nil
    request_reviewed_project_root_change(root)
  end

  def render_close_confirmation_public(width : Int32, height : Int32) : String
    self.rect = Tui::Rect.new(0, 0, width, height)
    screen = Tui::Buffer.new(width, height)
    render_close_confirmation(screen, Tui::Rect.new(0, 0, width, height))
    String.build do |output|
      height.times do |y|
        width.times { |x| output << screen.get(x, y).glyph }
        output << '\n'
      end
    end
  end

  def debug_dock_visible_public? : Bool
    @debug_dock_visible
  end
end

private def with_debug_editor_integration_root(&block : Path ->)
  Tui::App.clear_overlays
  candidate = Path.new(Dir.tempdir, "adamantine-debug-editor-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(candidate.to_s)
  root = Path.new(File.realpath(candidate.to_s))
  yield root
ensure
  Tui::App.clear_overlays
  FileUtils.rm_rf(root.to_s) if root
end

private def wait_for_debug_editor_panel(app : DebugEditorIntegrationApp,
                                        timeout : Time::Span = 4.seconds,
                                        &ready : -> Bool) : Nil
  deadline = Time.monotonic + timeout
  until ready.call
    app.on_capture(Tui::WakeupEvent.new)
    raise "debug editor UI did not reach its expected state" if Time.monotonic >= deadline
    sleep 5.milliseconds
  end
end

private def debug_marker_snapshot(path : Path,
                                  checksum_status : Adamantine::Debugging::ChecksumStatus = Adamantine::Debugging::ChecksumStatus::Match,
                                  outdated : Bool = false,
                                  running : Bool = false,
                                  breakpoints : Array(Adamantine::DebugController::SourceBreakpointView) = [] of Adamantine::DebugController::SourceBreakpointView) : Adamantine::DebugController::Snapshot
  key = Adamantine::Debugging::DebugSourceKey.local(path)
  state = Adamantine::DebugSessionState.initial
    .begin_session("debug-marker-adapter", "debug-marker-client")
  stamp = state.session_stamp || raise "marker state has no session stamp"
  state = state.activate.thread_seen(stamp, 7).stopped(stamp, 7, true).select_thread(7).select_frame(20)
  state = state.continued(stamp) if running

  frames = [
    Adamantine::DebugController::FrameView.new(
      10, "stopped frame", 1, 1, 0, 0, nil, key, "main.cr", path.to_s
    ),
    Adamantine::DebugController::FrameView.new(
      20, "caller frame", 2, 1, 1, 0, nil, key, "main.cr", path.to_s, nil, true
    ),
  ]
  threads = [Adamantine::DebugController::ThreadView.new(
    7, Adamantine::DebugSessionState::ThreadExecution::Stopped, "main"
  )]
  sources = [Adamantine::DebugController::SourceView.new(
    key, Adamantine::Debugging::SourceOrigin::LaunchBaseline, checksum_status,
    outdated, File.read(path)
  )]
  variables = Adamantine::Debugging::DebugVariableSnapshot.new(
    [] of Adamantine::Debugging::DebugVariableNode,
    [] of Adamantine::Debugging::DebugVariableNode,
    0, 0_i64
  )
  Adamantine::DebugController::Snapshot.new(
    state, Adamantine::DebugController::Capabilities.new, 0_i64, false, nil,
    1_u64, 1_u64, 1_u64, 1_u64, variables, frames, threads,
    breakpoints,
    [] of Adamantine::DebugController::OutputEntry, sources,
    [] of Adamantine::DebugController::WatchView, nil,
    Hash(Adamantine::DebugController::Action, Adamantine::DebugController::ActionAvailability).new
  )
end

describe "debugger App integration" do
  it "exposes debugger controls and navigation through F1 command discovery" do
    app = DebugEditorIntegrationApp.new(project_root: Path.new(Dir.tempdir), lsp_command: "")
    actions = app.debug_command_actions_public
    [
      "debug-start", "debug-stop", "debug-pause", "debug-over", "debug-into", "debug-out",
      "debug-breakpoint", "debug-configure", "debug-location", "debug-panel", "debug-toggle-panel",
      "debug-variables", "debug-sources", "debug-watch",
    ].each do |action|
      actions.should contain(action)
    end
  ensure
    app.try(&.close_debug_public)
  end

  it "uses effective keymap hints for debugger actions in Help" do
    app = DebugEditorIntegrationApp.new(project_root: Path.new(Dir.tempdir), lsp_command: "")
    {
      "debug.start_continue"    => "ctrl+alt+d",
      "debug.stop"              => "ctrl+alt+x",
      "debug.toggle_breakpoint" => "ctrl+alt+b",
      "debug.step_over"         => "ctrl+alt+o",
      "debug.step_into"         => "ctrl+alt+i",
      "debug.step_out"          => "ctrl+alt+u",
      "debug.pause"             => "unbound",
      "app.command_palette"     => "ctrl+alt+p",
    }.each do |action, binding|
      app.set_key_hint_public(action, binding)
    end

    help = app.show_help_public
    debug_line = help.find(&.starts_with?("Debug:")) || raise "Help omitted debugger shortcuts"
    ["ctrl+alt+d", "ctrl+alt+x", "ctrl+alt+b", "ctrl+alt+o", "ctrl+alt+i", "ctrl+alt+u", "unbound", "ctrl+alt+p"].each do |binding|
      debug_line.should contain(binding)
    end
    debug_line.should_not contain("F5")
    debug_line.should_not contain("F9")
  ensure
    app.try(&.close_debug_public)
  end

  it "uses truthful retained-tab copy for root-change dirty review at normal and narrow sizes" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path.to_s, "original\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(100, 20)
      app.open_file_public(path).should be_true
      app.dirty_buffer_public(path)
      app.request_root_change_public(root / "next-project")

      normal = app.render_close_confirmation_public(100, 20)
      normal.should contain("Change project root")
      normal.should contain("Save before changing project root?")
      normal.should contain("Continue without saving")
      normal.should contain("keeps this tab open")
      normal.should_not contain("Discard")
      normal.should_not contain("Save changes before closing?")

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Left)).should be_true
      narrow = app.render_close_confirmation_public(42, 7)
      narrow.should contain("Continue without saving")
      narrow.should contain("Tabs stay open; Save writes disk.")
      narrow.should_not contain("Discard")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.document_text_public(path).should contain("changed")
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "keeps the execution arrow on the top frame and marks a verified selected caller in every shared view" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path.to_s, "stopped\ncaller\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(180, 40)
      app.open_file_public(path).should be_true
      app.open_second_shared_view_public(path).should be_true

      app.project_debug_snapshot_public(debug_marker_snapshot(path))
      app.debug_view_markers_public(path).should eq([{0, 1}, {0, 1}])

      # Outdated source evidence suppresses both precision markers in all
      # views, even though the same integer frame IDs remain in the snapshot.
      app.project_debug_snapshot_public(debug_marker_snapshot(path, outdated: true))
      app.debug_view_markers_public(path).should eq([{nil, nil}, {nil, nil}])

      # Running execution cannot retain either the current arrow or caller
      # inspection marker from the previous stop.
      app.project_debug_snapshot_public(debug_marker_snapshot(path, running: true))
      app.debug_view_markers_public(path).should eq([{nil, nil}, {nil, nil}])
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "projects only accepted breakpoints as solid markers across every shared view" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path.to_s, "stopped\ncaller\npending\noutdated\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(180, 40)
      app.open_file_public(path).should be_true
      app.open_second_shared_view_public(path).should be_true

      key = Adamantine::Debugging::DebugSourceKey.local(path)
      bp = ->(id : String, line : Int32, enabled : Bool, status : Adamantine::Debugging::BreakpointStatus) {
        view = Adamantine::Debugging::DebugBreakpointView.new(id, line, nil, enabled, status)
        Adamantine::DebugController::SourceBreakpointView.new(key, view)
      }
      rows = [
        bp.call("verified", 0, true, Adamantine::Debugging::BreakpointStatus::Verified),
        bp.call("disabled", 1, false, Adamantine::Debugging::BreakpointStatus::Disabled),
        bp.call("pending", 2, true, Adamantine::Debugging::BreakpointStatus::Pending),
        bp.call("outdated", 3, true, Adamantine::Debugging::BreakpointStatus::Outdated),
      ]
      app.project_debug_snapshot_public(debug_marker_snapshot(path, breakpoints: rows))

      expected = {Set{0}, Set{1, 2, 3}}
      app.debug_view_breakpoint_sets_public(path).should eq([expected, expected])
      glyphs = ["●", "o", "o", "o"]
      app.debug_view_breakpoint_glyphs_public(path, 4).should eq([glyphs, glyphs])
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "prunes gutter callbacks when shared editor views are retired" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path.to_s, "source\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(180, 40)
      app.open_file_public(path).should be_true
      app.open_second_shared_view_public(path).should be_true
      app.project_debug_snapshot_public(debug_marker_snapshot(path))
      app.debug_gutter_callback_count_public.should eq(2)

      app.close_debug_split_public
      app.debug_gutter_callback_count_public.should eq(1)

      app.open_second_shared_view_public(path).should be_true
      # This new widget has never received a callback. Simulate an allocator
      # reusing an ID still in the bookkeeping set before projection runs.
      app.preseed_current_view_gutter_callback_id_public(path)
      app.project_debug_snapshot_public(debug_marker_snapshot(path))
      app.debug_gutter_callback_count_public.should eq(2)
      app.click_current_view_breakpoint_lane_public(path, 0).should be_true
      app.projected_breakpoint_count_public.should eq(1)
      app.close_debug_split_public
      app.debug_gutter_callback_count_public.should eq(1)
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "loads scopes explicitly and projects the returned sentinel into Variables" do
    with_debug_editor_integration_root do |root|
      adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
      ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
      target = Process.find_executable("true") || "/usr/bin/true"
      log_path = root / "adapter.jsonl"
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "debug-editor-integration",
        name: "UI fixture",
        adapter_argv: [ruby, adapter.to_s, log_path.to_s, "basic"],
        program: File.realpath(target),
        cwd: root.to_s
      )
      controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
        Adamantine::Dap::Client.new(argv, cwd)
      })
      private_state = root / "private-state"
      Dir.mkdir(private_state.to_s)
      File.chmod(private_state.to_s, 0o700)
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_root: private_state,
        session_enabled: false,
        debug_controller: controller
      )
      app.mount_headless(112, 26)
      review = controller.prepare_launch(profile, root)
      raise "fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      app.seed_debug_profile_public(profile)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      4.times { app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true }
      app.debug_modal_active_public.should be_true
      candidate = app.debug_candidate_profile_public || raise "launch review was not prepared"
      candidate.id.should eq(profile.id)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_modal_active_public.should be_false

      wait_for_debug_editor_panel(app) do
        app.poll_debug_public
        snapshot = controller.snapshot
        snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          snapshot.state.execution.stopped? && !snapshot.threads.empty? && !snapshot.frames.empty?
      end
      app.debug_dock_visible_public?.should be_true
      app.debug_panel_focused_public.should be_true
      app.layout_debug_panel_public
      debug_screen = app.debug_screen_public
      debug_screen.should contain("DEBUG")
      debug_screen.should contain("STACK")
      debug_screen.should contain("fixture_main")
      panel = app.panel_public
      panel.selected_pane = Adamantine::DebugPanel::Pane::Variables

      unless panel.total_rows(Adamantine::DebugPanel::Pane::Variables) == 1
        state = controller.snapshot.state
        raise "expected a Variables placeholder row: lifecycle=#{state.lifecycle}, execution=#{state.execution}, thread=#{state.selected_thread_id}, frame=#{state.selected_frame_id}, frames=#{controller.snapshot.frames.size}, panel=#{panel.total_rows(Adamantine::DebugPanel::Pane::Variables)}"
      end
      panel.activate_selected_row("activate").should be_true
      wait_for_debug_editor_panel(app) do
        app.poll_debug_public
        File.file?(log_path.to_s) && File.read(log_path.to_s).includes?("\"command\":\"scopes\"") &&
          File.read(log_path.to_s).includes?("\"command\":\"variables\"") &&
          panel.lines_for(Adamantine::DebugPanel::Pane::Variables).any?(&.includes?("sentinel = 271828"))
      end

      # Expanding the adapter-owned Record is an explicit user action. Its
      # asynchronous response enters the ID-backed projection; moving to the
      # newly inserted child then scrolls only when it reaches the viewport edge.
      panel.move_selection(2).should be_true
      panel.selected_row.should eq(2)
      panel.lines_for(Adamantine::DebugPanel::Pane::Variables).any?(&.includes?("record = Record")).should be_true
      panel.activate_selected_row("expand").should be_true
      wait_for_debug_editor_panel(app, 4.seconds) do
        app.poll_debug_public
        requested_child = File.read(log_path.to_s).includes?("\"variablesReference\":701")
        controller.snapshot.variables.nodes.any? { |node| node.name == "value" && node.value == "31" } && requested_child
      end
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
      panel.selected_row.should eq(3)
      panel.lines_for(Adamantine::DebugPanel::Pane::Variables).any?(&.includes?("value = 31")).should be_true
    ensure
      if controller
        controller.stop if controller.snapshot.state.lifecycle.in?(
                             Adamantine::DebugSessionState::Lifecycle::Starting,
                             Adamantine::DebugSessionState::Lifecycle::Configuring,
                             Adamantine::DebugSessionState::Lifecycle::Active,
                             Adamantine::DebugSessionState::Lifecycle::Disconnecting
                           )
      end
      app.try(&.close_debug_public)
      controller.try(&.close)
      if controller
        deadline = Time.instant + 3.seconds
        while controller.not_nil!.poll.cleanup_pending && Time.instant < deadline
          sleep 5.milliseconds
        end
        raise "fixture adapter cleanup exceeded the test bound" if controller.not_nil!.snapshot.cleanup_pending
      end
    end
  end

  it "preserves the selected launch profile identity and source maps through review without starting an adapter" do
    with_debug_editor_integration_root do |root|
      session_root = root / "state"
      target = Process.find_executable("true") || "/usr/bin/true"
      target = File.realpath(target)
      source_map = Adamantine::Debugging::DebugSourceMap.new("/adapter/project/src", root.to_s)
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "crystal-custom-profile",
        name: "Crystal with mapped sources",
        adapter_argv: [target, "--adapter argument with spaces"],
        program: target,
        cwd: File.realpath(root.to_s),
        target_argv: ["two words", "quoted\\\"argument"],
        source_maps: [source_map]
      )
      store = Adamantine::Debugging::DebugProfileStore.new(session_root)
      store.save(root, [profile], profile.id).saved?.should be_true

      factory_calls = 0
      controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
        factory_calls += 1
        Adamantine::Dap::Client.new(argv, cwd)
      })
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_root: session_root,
        session_enabled: false,
        debug_controller: controller
      )
      app.mount_headless(112, 26)

      # This exercises the user's F5 -> unchanged profile form -> Review path.
      # Review construction and source-map validation are local and inert.
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      app.debug_modal_active_public.should be_true
      4.times { app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true }
      app.debug_modal_active_public.should be_true
      candidate = app.debug_candidate_profile_public || raise "review did not retain a candidate profile"
      candidate.id.should eq("crystal-custom-profile")
      candidate.name.should eq("Crystal with mapped sources")
      candidate.adapter_argv.should eq([target, "--adapter argument with spaces"])
      candidate.target_argv.should eq(["two words", "quoted\\\"argument"])
      candidate.source_maps.size.should eq(1)
      candidate.source_maps.first.adapter_prefix.should eq("/adapter/project/src")
      candidate.source_maps.first.local_prefix.should eq(File.realpath(root.to_s))
      factory_calls.should eq(0)
    ensure
      app.try(&.close_debug_public)
      controller.try(&.close)
    end
  end

  it "opens explicit bounded Summary, local JSON, and adapter Hex detail from Variables" do
    with_debug_editor_integration_root do |root|
      adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
      ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
      target = Process.find_executable("true") || "/usr/bin/true"
      log_path = root / "adapter.jsonl"
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "debug-editor-value-detail",
        name: "UI value detail fixture",
        adapter_argv: [ruby, adapter.to_s, log_path.to_s, "value_format"],
        program: File.realpath(target),
        cwd: root.to_s
      )
      controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
        Adamantine::Dap::Client.new(argv, cwd)
      })
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false,
        debug_controller: controller
      )
      app.mount_headless(112, 26)
      review = controller.prepare_launch(profile, root)
      raise "value-detail fixture should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      raise "value-detail fixture launch should be accepted" unless controller.start(review).accepted?
      wait_for_debug_editor_panel(app) do
        app.poll_debug_public
        controller.snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          controller.snapshot.state.execution.stopped? && !controller.snapshot.frames.empty?
      end

      app.show_debug_panel_public.should be_true
      panel = app.panel_public
      panel.selected_pane = Adamantine::DebugPanel::Pane::Variables
      panel.activate_selected_row("activate").should be_true
      wait_for_debug_editor_panel(app) do
        app.poll_debug_public
        controller.snapshot.variables.nodes.count { |node| node.name == "duplicate" } == 2
      end
      panel.move_selection(2).should be_true
      selected = controller.snapshot.variables.nodes.find { |node| node.name == "duplicate" && node.value == "11" } ||
                 raise "expected second duplicate variable"

      # Enter on a leaf opens local Summary detail and must issue no DAP
      # request. `z` selects local JSON interpretation, also without I/O.
      requests_before_detail = File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
        .count { |record| record["type"]?.try(&.as_s?) == "request" }
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_modal_active_public.should be_true
      screen = app.debug_screen_public
      screen.should contain("Adapter summary")
      screen.should contain("11")
      File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
        .count { |record| record["type"]?.try(&.as_s?) == "request" }.should eq(requests_before_detail)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new('z')).should be_true
      screen = app.debug_screen_public
      screen.should contain("JSON interpretation (local display)")
      screen.should contain("11")
      File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
        .count { |record| record["type"]?.try(&.as_s?) == "request" }.should eq(requests_before_detail)

      before_hex = File.read(log_path.to_s)
      before_hex_records = before_hex.lines.compact_map { |line| JSON.parse(line) }
      before_hex_records.count do |record|
        record["type"]?.try(&.as_s?) == "request" &&
          record["command"]?.try(&.as_s?) == "variables" &&
          record.dig?("arguments", "format", "hex") == JSON::Any.new(true)
      end.should eq(0)
      before_hex.includes?("\"command\":\"evaluate\"").should be_false
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true

      # Hex is an explicit adapter request, not a render-time conversion. The
      # selected duplicate must retain its originating page identity.
      app.dispatch_debug_event_public(Tui::KeyEvent.new('x')).should be_true
      app.debug_modal_active_public.should be_true
      wait_for_debug_editor_panel(app) do
        app.poll_debug_public
        controller.render_value(selected.id, Adamantine::Debugging::DebugValueFormat::Hex).available?
      end
      screen = app.debug_screen_public
      screen.should contain("Adapter-provided hexadecimal")
      screen.should contain("0x0b")
      records = File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
      format_requests = records.select do |record|
        record["type"]?.try(&.as_s?) == "request" &&
          record["command"]?.try(&.as_s?) == "variables" &&
          record.dig?("arguments", "format", "hex") == JSON::Any.new(true)
      end
      format_requests.size.should eq(1)
      format_requests.first.dig("arguments", "variablesReference").as_i.should eq(700)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      controller.poll
      controller.render_value(selected.id, Adamantine::Debugging::DebugValueFormat::Hex).available?.should be_false
      final_records = File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
      final_records.count do |record|
        record["type"]?.try(&.as_s?) == "request" &&
          record["command"]?.try(&.as_s?) == "variables" &&
          record.dig?("arguments", "format", "hex") == JSON::Any.new(true)
      end.should eq(1)
    ensure
      controller.try(&.stop)
      app.try(&.close_debug_public)
      controller.try(&.close)
      if controller
        deadline = Time.instant + 3.seconds
        while controller.not_nil!.poll.cleanup_pending && Time.instant < deadline
          sleep 5.milliseconds
        end
        raise "fixture adapter cleanup exceeded the test bound" if controller.not_nil!.snapshot.cleanup_pending
      end
    end
  end

  it "routes a focused dock without mutating the editor behind it" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path.to_s, "original\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(100, 24)
      app.open_file_public(path).should be_true
      app.set_debug_rows_public(Adamantine::DebugPanel::Pane::Stack, ["one", "two", "three"] of String)
      app.show_debug_panel_public.should be_true
      before = app.document_text_public(path)

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.debug_selected_pane_public.should eq(Adamantine::DebugPanel::Pane::Threads)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift)).should be_true
      app.debug_selected_pane_public.should eq(Adamantine::DebugPanel::Pane::Stack)
      app.debug_panel_focused_public.should be_true
      # Pane changes refresh from the real (empty) controller snapshot in this
      # UI-isolation test. Restore the row fixture after exercising traversal.
      app.set_debug_rows_public(Adamantine::DebugPanel::Pane::Stack, ["one", "two", "three"] of String)
      app.debug_panel_rows_public.should eq(3)

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
      app.debug_selected_row_public.should eq(1)
      # A focused dock consumes action-shaped printable keys even when the
      # current fixture row has no backing frame; they never leak to editing.
      app.dispatch_debug_event_public(Tui::KeyEvent.new('x')).should be_true
      app.dispatch_debug_event_public(Tui::PasteEvent.new("must not reach the editor")).should be_false
      app.document_text_public(path).should eq(before)

      # App-level debugger bindings remain routable while the dock has focus.
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      app.debug_modal_active_public.should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.debug_modal_active_public.should be_false
      app.document_text_public(path).should eq(before)

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.debug_dock_visible_public?.should be_false
      app.debug_panel_focused_public.should be_false
      app.active_editor_focused_public?.should be_true
      app.document_text_public(path).should eq(before)

      # A fresh asynchronous projection after hiding updates the dock state
      # without stealing focus back from the active editor.
      app.refresh_debug_projection_public
      app.debug_dock_visible_public?.should be_false
      app.active_editor_focused_public?.should be_true
      app.document_text_public(path).should eq(before)
    ensure
      app.try(&.close_debug_public)
    end
  end
end
