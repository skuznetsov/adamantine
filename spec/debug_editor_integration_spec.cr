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
    # App focus repair intentionally refuses to target an inspector with no
    # resolved screen geometry. Render the mounted frame before simulating the
    # user's request, as the live app does on its first frame.
    debug_screen_public
    shown = debug_show_panel(true)
    refresh
    debug_screen_public
    shown
  end

  def layout_debug_panel_public : Nil
    debug_screen_public
  end

  def debug_screen_public(width : Int32 = 112, height : Int32 = 26) : String
    surface = debug_buffer_public(width, height)
    String.build do |output|
      height.times do |y|
        width.times { |x| output << surface.get(x, y).glyph }
        output << '\n'
      end
    end
  end

  def debug_buffer_public(width : Int32, height : Int32) : Tui::Buffer
    surface = Tui::Buffer.new(width, height)
    render(surface, Tui::Rect.new(0, 0, width, height))
    surface
  end

  def debug_screen_resized_public(width : Int32, height : Int32) : String
    self.rect = Tui::Rect.new(0, 0, width, height)
    # The live TUI refreshes App layout after terminal resize. Headless App
    # rendering does not, so mirror that boundary before rendering the frame.
    refresh
    surface = Tui::Buffer.new(width, height)
    render(surface, Tui::Rect.new(0, 0, width, height))
    String.build do |output|
      height.times do |y|
        width.times { |x| output << surface.get(x, y).glyph }
        output << '\n'
      end
    end
  end

  def terminal_resize_before_paint_public(width : Int32, height : Int32) : Nil
    # Tui::App#check_resize updates the root rect and dispatches this event,
    # then marks the tree dirty; child layout is deferred until the next paint.
    self.rect = Tui::Rect.new(0, 0, width, height)
    dispatch_debug_event_public(Tui::ResizeEvent.new(width, height))
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

  def project_debug_variables_public(snapshot : Adamantine::DebugController::Snapshot,
                                     width : Int32, height : Int32) : String
    @debug_snapshot = snapshot
    @debug_variable_projected_generation = UInt64::MAX
    # Accepted scope replies auto-expand roots in the App; mirror that state
    # while feeding a synthetic retained tree through the real projection.
    snapshot.variables.roots.each { |root| @debug_variable_expanded_ids << root.id }
    @debug_workspace.panel.rect = Tui::Rect.new(0, 0, width, height)
    @debug_workspace.panel.selected_pane = Adamantine::DebugPanel::Pane::Variables
    debug_project_panel_page(Adamantine::DebugPanel::Pane::Variables, 0,
      [@debug_workspace.panel.viewport_capacity, Adamantine::DebugPanel::MAX_PAGE_LINES].min)
    surface = Tui::Buffer.new(width, height)
    @debug_workspace.panel.render(surface, Tui::Rect.new(0, 0, width, height))
    String.build do |output|
      height.times do |y|
        width.times { |x| output << surface.get(x, y).glyph }
        output << '\n'
      end
    end
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

  def debug_panel_rect_public : Tui::Rect
    @debug_workspace.panel.rect
  end

  def inspector_has_visible_public? : Bool
    !@inspector_layout.geometry.inspector.nil?
  end

  def command_palette_open_public? : Bool
    @command_palette.open
  end

  def open_quick_open_public : Nil
    open_quick_open
  end

  def quick_open_open_public? : Bool
    @quick_open.open
  end

  def file_panel_focused_public : Bool
    @file_panel.focused?
  end

  def inspector_section_public : Adamantine::DebugInspectorSection
    @inspector_layout.selected_section
  end

  def files_inspector_hidden_public? : Bool
    @inspector_layout.files_inspector_hidden?
  end

  def select_files_inspector_public(focus : Bool = false) : Bool
    select_files_inspector(focus)
  end

  def set_debug_dock_public(dock : Adamantine::DebugInspectorDock) : Nil
    @settings.debug_dock = dock
    @inspector_layout.debug_dock = dock
  end

  def set_activity_rail_padding_public(padding : Bool) : Nil
    @settings.activity_rail_padding = padding
    @inspector_layout.activity_rail_padding = padding
  end

  def debug_geometry_public : Adamantine::DebugInspectorGeometry
    @inspector_layout.geometry
  end

  def debug_dock_public : Adamantine::DebugInspectorDock
    @settings.debug_dock
  end

  def status_rect_public : Tui::Rect
    @status_log.rect
  end

  def inspector_rect_public : Tui::Rect
    @inspector_layout.rect
  end

  def files_panel_rect_public : Tui::Rect
    @file_panel.rect
  end

  def editor_split_parented_public? : Bool
    split = @editor_group_split
    split != nil && @editor_tabs.parent == split && @inspector_layout.editor.same?(split.not_nil!)
  end

  def split_editor_right_public : Bool
    split_editor_right
  end

  def editor_split_open_public? : Bool
    !@editor_group_split.nil?
  end

  def active_editor_focused_public? : Bool
    active_editor_internal.try(&.focused?) == true
  end

  def focus_active_editor_public : Nil
    active_editor_internal.try(&.focus)
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

  def debug_value_detail_lines_public : Array(String)
    @debug_value_detail_lines
  end

  def debug_value_detail_scroll_public : Int32
    @debug_value_detail_scroll
  end

  def refresh_value_detail_snapshot_public(snapshot : Adamantine::DebugController::Snapshot) : Nil
    @debug_snapshot = snapshot
    debug_refresh_value_detail
  end

  def project_debug_snapshot_with_panel_public(snapshot : Adamantine::DebugController::Snapshot) : Nil
    @debug_snapshot = snapshot
    debug_project_summary
    panel = @debug_workspace.panel
    debug_project_panel_page(panel.selected_pane, panel.first_visible_row(panel.selected_pane),
      [panel.viewport_capacity, Adamantine::DebugPanel::MAX_PAGE_LINES].min)
  end

  def debug_scope_placeholder_public(width : Int32) : String
    debug_variable_placeholder(width)
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

private def debug_variable_presentation_snapshot : Adamantine::DebugController::Snapshot
  scope = Adamantine::Debugging::DebugVariableNode.new("scope-1", nil, "Locals", "", nil, 700, 1, nil, 0,
    Adamantine::Debugging::DebugVariableLoadState::Partial, ["child-1"] of String)
  value = Adamantine::Debugging::DebugVariableNode.new("child-1", "scope-1", "x" * 100, "42", "Int32", 0, nil, nil, 1,
    Adamantine::Debugging::DebugVariableLoadState::Loaded, [] of String)
  variables = Adamantine::Debugging::DebugVariableSnapshot.new([scope, value], [scope], 2, 128_i64)
  state = Adamantine::DebugSessionState.initial
    .begin_session("presentation-adapter", "presentation-client")
  stamp = state.session_stamp || raise "presentation state has no session stamp"
  state = state.activate.thread_seen(stamp, 7).stopped(stamp, 7, true).select_thread(7).select_frame(20)
  Adamantine::DebugController::Snapshot.new(
    state, Adamantine::DebugController::Capabilities.new, 0_i64, false, nil,
    1_u64, 1_u64, 1_u64, 1_u64, variables,
    [] of Adamantine::DebugController::FrameView,
    [] of Adamantine::DebugController::ThreadView,
    [] of Adamantine::DebugController::SourceBreakpointView,
    [] of Adamantine::DebugController::OutputEntry,
    [] of Adamantine::DebugController::SourceView,
    [] of Adamantine::DebugController::WatchView,
    nil,
    Hash(Adamantine::DebugController::Action, Adamantine::DebugController::ActionAvailability).new
  )
end

private def copy_debug_snapshot(snapshot : Adamantine::DebugController::Snapshot,
                                state : Adamantine::DebugSessionState,
                                generation : UInt64,
                                output : Array(Adamantine::DebugController::OutputEntry),
                                *, last_error : String? = snapshot.last_error) : Adamantine::DebugController::Snapshot
  Adamantine::DebugController::Snapshot.new(
    state, snapshot.capabilities, snapshot.output_dropped, snapshot.cleanup_pending,
    snapshot.target_exit_code, generation, snapshot.variable_generation, snapshot.source_generation,
    snapshot.breakpoint_generation, snapshot.variables, snapshot.frames, snapshot.threads,
    snapshot.breakpoints, output, snapshot.sources, snapshot.watches, last_error,
    Hash(Adamantine::DebugController::Action, Adamantine::DebugController::ActionAvailability).new,
    snapshot.scopes_loaded, snapshot.scopes_request_pending, snapshot.scopes_error,
    snapshot.value_format_generation, snapshot.value_format_status
  )
end

private def debug_snapshot_with_global_error(snapshot : Adamantine::DebugController::Snapshot,
                                             error : String) : Adamantine::DebugController::Snapshot
  availability = Hash(Adamantine::DebugController::Action,
                      Adamantine::DebugController::ActionAvailability).new
  availability[Adamantine::DebugController::Action::OpenScopes] =
    snapshot.availability(Adamantine::DebugController::Action::OpenScopes)
  Adamantine::DebugController::Snapshot.new(
    snapshot.state, snapshot.capabilities, snapshot.output_dropped, snapshot.cleanup_pending,
    snapshot.target_exit_code, snapshot.generation + 1_u64, snapshot.variable_generation,
    snapshot.source_generation, snapshot.breakpoint_generation, snapshot.variables,
    snapshot.frames, snapshot.threads, snapshot.breakpoints, snapshot.output, snapshot.sources,
    snapshot.watches, error, availability, snapshot.scopes_loaded, snapshot.scopes_request_pending,
    snapshot.scopes_error, snapshot.value_format_generation, snapshot.value_format_status
  )
end

private def debug_snapshot_with_unrelated_output(snapshot : Adamantine::DebugController::Snapshot) : Adamantine::DebugController::Snapshot
  output = snapshot.output
  output << Adamantine::DebugController::OutputEntry.new("console", Time.utc, "unrelated output update")
  copy_debug_snapshot(snapshot, snapshot.state, snapshot.generation + 1_u64, output)
end

private def debug_snapshot_continued(snapshot : Adamantine::DebugController::Snapshot) : Adamantine::DebugController::Snapshot
  stamp = snapshot.state.session_stamp || raise "debug snapshot has no session stamp"
  continued = snapshot.state.continued(stamp)
  copy_debug_snapshot(snapshot, continued, snapshot.generation + 1_u64, snapshot.output)
end

describe "debugger App integration" do
  it "projects scope headings and value fields without letting long names hide data or paging state" do
    with_debug_editor_integration_root do |root|
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_root: root / "state",
        session_enabled: false
      )
      app.mount_headless(52, 12)

      screen = app.project_debug_variables_public(debug_variable_presentation_snapshot, 48, 8)
      screen.should contain("Locals")
      screen.should_not contain("Locals =")
      screen.should contain("m:")
      screen.should contain("Partial")
      screen.should contain("42")
      screen.should contain("Int32")
      screen.should contain("…")
    ensure
      app.try(&.close_debug_public)
    end
  end

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
      app.debug_screen_public
      review = controller.prepare_launch(profile, root)
      raise "fixture launch should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      app.seed_debug_profile_public(profile)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      5.times { app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true }
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
      app.debug_dock_public.should eq(Adamantine::DebugInspectorDock::Left)
      app.layout_debug_panel_public
      debug_screen = app.debug_screen_public
      debug_screen.should contain("DEBUG")
      debug_screen.should contain("STACK")
      debug_screen.should contain("main.cr:12")
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
          panel.lines_for(Adamantine::DebugPanel::Pane::Variables).any?(&.includes?("271828"))
      end
      variable_rows = panel.lines_for(Adamantine::DebugPanel::Pane::Variables)
      variable_rows.any?(&.includes?("Locals")).should be_true
      variable_rows.any?(&.includes?("Locals =")).should be_false
      app.layout_debug_panel_public
      app.debug_screen_public.should contain("271828")

      # Expanding the adapter-owned Record is an explicit user action. Its
      # asynchronous response enters the ID-backed projection; moving to the
      # newly inserted child then scrolls only when it reaches the viewport edge.
      panel.move_selection(2).should be_true
      panel.selected_row.should eq(2)
      panel.lines_for(Adamantine::DebugPanel::Pane::Variables).any?(&.includes?("Reco")).should be_true
      panel.activate_selected_row("expand").should be_true
      wait_for_debug_editor_panel(app, 4.seconds) do
        app.poll_debug_public
        requested_child = File.read(log_path.to_s).includes?("\"variablesReference\":701")
        controller.snapshot.variables.nodes.any? { |node| node.name == "value" && node.value == "31" } && requested_child
      end
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
      panel.selected_row.should eq(3)
      panel.lines_for(Adamantine::DebugPanel::Pane::Variables).any?(&.includes?("value = 31")).should be_true

      # Docking and rail selection are presentation-only: retain the stopped
      # frame/thread and expanded Variables projection without issuing DAP
      # requests while the panel is relocated or hidden.
      before_layout = controller.snapshot
      before_commands = File.read(log_path.to_s)
      before_rows = panel.lines_for(Adamantine::DebugPanel::Pane::Variables)
      before_nodes = before_layout.variables.nodes.map { |node| {node.id, node.name, node.value} }
      before_frame = before_layout.state.selected_frame_id
      before_thread = before_layout.state.selected_thread_id
      before_row = panel.selected_row
      {Adamantine::DebugInspectorDock::Right, Adamantine::DebugInspectorDock::Bottom,
       Adamantine::DebugInspectorDock::Left}.each do |dock|
        app.set_debug_dock_public(dock)
        app.debug_screen_public
      end
      app.dispatch_debug_event_public(Tui::MouseEvent.new(0, 2)).should be_true
      app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Files)
      app.debug_screen_public
      app.dispatch_debug_event_public(Tui::MouseEvent.new(0, 8)).should be_true
      app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Debug)
      app.debug_screen_public
      after_layout = controller.snapshot
      after_layout.state.lifecycle.should eq(before_layout.state.lifecycle)
      after_layout.state.execution.stopped?.should be_true
      after_layout.state.selected_frame_id.should eq(before_frame)
      after_layout.state.selected_thread_id.should eq(before_thread)
      after_layout.variables.nodes.map { |node| {node.id, node.name, node.value} }.should eq(before_nodes)
      panel.selected_pane.should eq(Adamantine::DebugPanel::Pane::Variables)
      panel.selected_row.should eq(before_row)
      panel.lines_for(Adamantine::DebugPanel::Pane::Variables).should eq(before_rows)
      File.read(log_path.to_s).should eq(before_commands)

      # A genuine DAP frame remains source-addressable when the whole App is
      # resized to the compact width used by the sidebar fallback.
      panel.selected_pane = Adamantine::DebugPanel::Pane::Stack
      app.debug_screen_resized_public(34, 26).should contain("main.cr:12")
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

  it "keeps an accepted empty scope response distinct and does not fetch it repeatedly" do
    with_debug_editor_integration_root do |root|
      adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
      ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
      target = Process.find_executable("true") || "/usr/bin/true"
      log_path = root / "adapter.jsonl"
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "debug-editor-empty-scopes",
        name: "UI empty-scope fixture",
        adapter_argv: [ruby, adapter.to_s, log_path.to_s, "empty_scopes"],
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
      raise "empty-scope fixture should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      raise "empty-scope fixture launch should be accepted" unless controller.start(review).accepted?
      wait_for_debug_editor_panel(app) do
        app.poll_debug_public
        snapshot = controller.snapshot
        snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
          snapshot.state.execution.stopped? && !snapshot.frames.empty?
      end

      app.show_debug_panel_public.should be_true
      panel = app.panel_public
      panel.selected_pane = Adamantine::DebugPanel::Pane::Variables
      panel.total_rows(Adamantine::DebugPanel::Pane::Variables).should eq(1)
      panel.activate_selected_row("activate").should be_true
      wait_for_debug_editor_panel(app) do
        app.poll_debug_public
        controller.snapshot.scopes_loaded
      end

      app.layout_debug_panel_public
      panel.lines_for(Adamantine::DebugPanel::Pane::Variables).join.should contain("No scopes or variables reported")
      panel.activate_selected_row("activate").should be_true
      app.poll_debug_public
      controller.snapshot.scopes_loaded.should be_true
      panel.refresh_viewport
      panel.lines_for(Adamantine::DebugPanel::Pane::Variables).join.should contain("No scopes or variables reported")
      File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
        .count { |record| record["type"]?.try(&.as_s?) == "request" && record["command"]?.try(&.as_s?) == "scopes" }
        .should eq(1)
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

  [{"reject_scopes", "fixture rejected scopes"},
   {"malformed_scopes", "malformed scopes response"}].each do |mode, expected_error|
    it "renders #{mode} as a completed scope error with an explicit retry affordance" do
      with_debug_editor_integration_root do |root|
        adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
        ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
        target = Process.find_executable("true") || "/usr/bin/true"
        log_path = root / "adapter.jsonl"
        profile = Adamantine::Debugging::LaunchProfile.new(
          id: "debug-editor-#{mode}",
          name: "UI #{mode} fixture",
          adapter_argv: [ruby, adapter.to_s, log_path.to_s, mode],
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
        # This case validates the complete error/retry copy, which is
        # intentionally kept at the legacy full-width placement. Other
        # integration coverage exercises the new default sidebar.
        app.set_debug_dock_public(Adamantine::DebugInspectorDock::Bottom)
        review = controller.prepare_launch(profile, root)
        raise "scope-error fixture should be reviewable: #{review.errors.join("; ")}" unless review.valid?
        raise "scope-error fixture launch should be accepted" unless controller.start(review).accepted?
        wait_for_debug_editor_panel(app) do
          app.poll_debug_public
          snapshot = controller.snapshot
          snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
            snapshot.state.execution.stopped? && !snapshot.frames.empty?
        end

        app.show_debug_panel_public.should be_true
        panel = app.panel_public
        panel.selected_pane = Adamantine::DebugPanel::Pane::Variables
        panel.activate_selected_row("activate").should be_true
        wait_for_debug_editor_panel(app) do
          app.poll_debug_public
          snapshot = controller.snapshot
          !snapshot.scopes_request_pending && snapshot.scopes_error.try(&.includes?(expected_error)) == true
        end
        app.layout_debug_panel_public
        panel.refresh_viewport
        panel.lines_for(Adamantine::DebugPanel::Pane::Variables).join.should contain("Scopes unavailable")
        panel.lines_for(Adamantine::DebugPanel::Pane::Variables).join.should contain(expected_error)
        panel.lines_for(Adamantine::DebugPanel::Pane::Variables).join.should contain("Enter: retry")
        panel.error.should_not be_nil
        panel.error.not_nil!.should contain(expected_error)

        # A later Watch/Source failure replaces last_error, but the distinct
        # scopes_error remains the explanation attached to this placeholder.
        later_error = "later unrelated watch failure"
        app.project_debug_snapshot_with_panel_public(debug_snapshot_with_global_error(controller.snapshot, later_error))
        scope_row = panel.lines_for(Adamantine::DebugPanel::Pane::Variables).join
        scope_row.should contain(expected_error)
        scope_row.should contain("Enter: retry")
        panel.error.not_nil!.should contain(later_error)
        app.debug_scope_placeholder_public(12).should eq("Enter: retry")
        app.debug_scope_placeholder_public(1).should eq("…")
        records = File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
        records.count { |record| record["type"]?.try(&.as_s?) == "request" && record["command"]?.try(&.as_s?) == "scopes" }
          .should eq(1)

        panel.activate_selected_row("activate").should be_true
        wait_for_debug_editor_panel(app) do
          app.poll_debug_public
          File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
            .count { |record| record["type"]?.try(&.as_s?) == "request" && record["command"]?.try(&.as_s?) == "scopes" } == 2
        end
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
      5.times { app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true }
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

  it "selects and discloses the optional Stock Crystal value provider without treating the selector as text" do
    with_debug_editor_integration_root do |root|
      target = File.realpath(Process.find_executable("true") || "/usr/bin/true")
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "stock-crystal-selector",
        name: "Selector fixture",
        adapter_argv: [target, "--no-lldbinit"],
        program: target,
        cwd: File.realpath(root.to_s)
      )
      factory_calls = 0
      controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
        factory_calls += 1
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
      app.seed_debug_profile_public(profile)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      app.debug_screen_public.should contain("Values: Adapter (default)")
      4.times { app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true }
      app.debug_screen_public.should contain("> Values: Adapter (default)")

      # A too-short profile modal must not draw its provider selector over a
      # field or accept invisible edits/approval.
      short_profile = app.debug_screen_resized_public(112, 9)
      short_profile.should contain("Resize to 10 rows to edit profile")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Right)).should be_true
      app.dispatch_debug_event_public(Tui::PasteEvent.new("StockCrystal")).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_candidate_profile_public.should be_nil
      app.debug_screen_public(112, 9).should contain("Resize to 10 rows to edit profile")
      app.debug_screen_resized_public(112, 26).should contain("> Values: Adapter (default)")

      app.dispatch_debug_event_public(Tui::KeyEvent.new('x')).should be_true
      app.dispatch_debug_event_public(Tui::PasteEvent.new("StockCrystal")).should be_true
      app.debug_screen_public.should_not contain("Stock Crystal (LLDB)")

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Right)).should be_true
      app.debug_screen_public.should contain("> Values: Stock Crystal (LLDB)")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Left)).should be_true
      app.debug_screen_public.should contain("> Values: Adapter (default)")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Space)).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true

      candidate = app.debug_candidate_profile_public || raise "provider review was not prepared"
      candidate.native_values.should eq(Adamantine::Debugging::NativeValueProvider::StockCrystal)
      candidate.adapter_argv.should eq([target, "--no-lldbinit"])
      screen = app.debug_screen_public
      screen.should contain("Values: Stock Crystal (LLDB)")
      screen.should contain("Bundled LLDB provider; bounded passive String/integer Array previews.")
      screen.should contain("bounded passive String/integer Array previews")
      screen.should contain("Stock Crystal only; not Adamas")
      factory_calls.should eq(0)
    ensure
      app.try(&.close_debug_public)
      controller.try(&.close)
    end
  end

  it "keeps provider selection visible at height 14 and blocks an undisclosed short review" do
    with_debug_editor_integration_root do |root|
      target = root / "lldb-dap"
      FileUtils.cp(Process.find_executable("true") || "/usr/bin/true", target.to_s)
      File.chmod(target.to_s, 0o700)
      target = File.realpath(target.to_s)
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "stock-crystal-short-terminal",
        name: "Short terminal fixture",
        adapter_argv: [target, "--no-lldbinit"],
        program: target,
        cwd: File.realpath(root.to_s)
      )
      factory_calls = 0
      controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
        factory_calls += 1
        raise "Stock Crystal launch factory reached before review fit" if argv[1]? == "--no-lldbinit"
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
      app.mount_headless(112, 14)
      app.seed_debug_profile_public(profile)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      4.times { app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true }
      app.debug_screen_public(112, 14).should contain("> Values: Adapter (default)")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Right)).should be_true
      app.debug_screen_public(112, 14).should contain("> Values: Stock Crystal (LLDB)")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      review = app.debug_screen_public(112, 14)
      review.should contain("Values: Stock Crystal (LLDB)")
      review.should contain("Bundled LLDB provider; bounded passive String/integer Array previews.")
      review.should contain("Stock Crystal only; not Adamas")
      factory_calls.should eq(0)

      # At the exact minimum width, the full stock-provider disclosure must
      # still be readable before approval is possible.
      boundary = app.debug_screen_resized_public(77, 14)
      boundary.should contain("Bundled LLDB provider; bounded passive String/integer Array previews.")
      boundary.should contain("Stock Crystal only; not Adamas.")
      boundary.should contain("--no-lldbinit must be first argument after lldb-dap.")
      factory_calls.should eq(0)

      # At a shorter height, the compact disclosure remains visible but Enter
      # cannot approve a Stock Crystal launch until the full review fits.
      compact = app.debug_screen_resized_public(112, 10)
      compact.should contain("Values: Stock Crystal (LLDB)")
      compact.should contain("runs inside LLDB")
      compact.should contain("Stock Crystal only; not Adamas")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_screen_resized_public(112, 10).should contain("Resize to 14 rows")
      short_candidate = app.debug_candidate_profile_public || raise "short review lost the prepared profile"
      short_candidate.review_errors(root).should be_empty
      factory_calls.should eq(0)

      # The stock-provider effect needs 69 display cells. A narrow terminal
      # must request a width increase instead of approving this valid profile.
      narrow = app.debug_screen_resized_public(20, 26)
      narrow.should contain("Need 77 cols")
      narrow.should_not contain("bounded passive")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_screen_public(20, 26).should contain("Need 77 cols")
      app.debug_candidate_profile_public.not_nil!.review_errors(root).should be_empty
      factory_calls.should eq(0)
    ensure
      app.try(&.close_debug_public)
      controller.try(&.close)
    end
  end

  it "requires an explicit no-lldbinit argv edit for Stock Crystal and preserves the entered argv" do
    with_debug_editor_integration_root do |root|
      target = File.realpath(Process.find_executable("true") || "/usr/bin/true")
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "stock-crystal-guard",
        name: "Selector guard fixture",
        adapter_argv: [target],
        program: target,
        cwd: File.realpath(root.to_s)
      )
      factory_calls = 0
      controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
        factory_calls += 1
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
      app.seed_debug_profile_public(profile)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      4.times { app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true }
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Space)).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true

      app.debug_modal_active_public.should be_true
      app.debug_candidate_profile_public.should be_nil
      screen = app.debug_screen_public
      screen.should contain("Stock Crystal values require --no-lldbinit immediately after lldb-dap")
      screen.should contain("[\"#{target}\"]")
      screen.should_not contain("[\"#{target}\", \"--no-lldbinit\"]")
      factory_calls.should eq(0)

      # The user can back out of the opt-in without having their argv rewritten.
      4.times { app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true }
      app.debug_screen_public.should contain("> Values: Stock Crystal (LLDB)")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Space)).should be_true
      app.debug_screen_public.should contain("> Values: Adapter (default)")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      candidate = app.debug_candidate_profile_public || raise "Adapter review recovery failed"
      candidate.native_values.should eq(Adamantine::Debugging::NativeValueProvider::Generic)
      candidate.adapter_argv.should eq([target])
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
        adapter_argv: [ruby, adapter.to_s, log_path.to_s, "value_format_late"],
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
      screen.should contain("duplicate")
      screen.should contain("Int32")
      cached_summary_lines = app.debug_value_detail_lines_public
      snapshot_with_output = debug_snapshot_with_unrelated_output(controller.snapshot)
      app.refresh_value_detail_snapshot_public(snapshot_with_output)
      app.debug_value_detail_lines_public.object_id.should eq(cached_summary_lines.object_id)
      File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
        .count { |record| record["type"]?.try(&.as_s?) == "request" }.should eq(requests_before_detail)
      app.dispatch_debug_event_public(Tui::KeyEvent.new('z')).should be_true
      json_modal_lines = app.debug_value_detail_lines_public
      json_modal_lines.object_id.should_not eq(cached_summary_lines.object_id)
      app.debug_screen_public.should contain("JSON interpretation (local display)")
      app.dispatch_debug_event_public(Tui::KeyEvent.new('s')).should be_true
      summary_again_lines = app.debug_value_detail_lines_public
      summary_again_lines.object_id.should_not eq(json_modal_lines.object_id)
      app.debug_screen_public.should contain("Adapter summary")
      File.read_lines(log_path.to_s).compact_map { |line| JSON.parse(line) }
        .count { |record| record["type"]?.try(&.as_s?) == "request" }.should eq(requests_before_detail)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new('z')).should be_true
      screen = app.debug_screen_public
      screen.should contain("JSON interpretation (local display)")
      screen.should contain("11")
      app.debug_value_detail_lines_public.object_id.should_not eq(cached_summary_lines.object_id)
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
        File.read(log_path.to_s).includes?("value_format_held")
      end
      pending_snapshot = controller.snapshot
      pending_snapshot.value_format_status.should eq(Adamantine::DebugController::ValueFormatStatus::Pending)
      app.refresh_value_detail_snapshot_public(pending_snapshot)
      pending_lines = app.debug_value_detail_lines_public
      pending_lines.join.should contain("pending")
      pending_generation = pending_snapshot.value_format_generation
      File.write("#{log_path}.format-release", "release")
      wait_for_debug_editor_panel(app) do
        app.poll_debug_public
        controller.render_value(selected.id, Adamantine::Debugging::DebugValueFormat::Hex).available?
      end
      available_snapshot = controller.snapshot
      available_snapshot.value_format_status.should eq(Adamantine::DebugController::ValueFormatStatus::Available)
      available_snapshot.value_format_generation.should eq(pending_generation)
      app.refresh_value_detail_snapshot_public(available_snapshot)
      available_lines = app.debug_value_detail_lines_public
      available_lines.object_id.should_not eq(pending_lines.object_id)
      available_lines.join.should contain("0x0b")
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

  it "keeps unavailable detail status and a close gesture visible in a narrow modal" do
    with_debug_editor_integration_root do |root|
      adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
      ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
      target = Process.find_executable("true") || "/usr/bin/true"
      log_path = root / "adapter.jsonl"
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "debug-editor-value-detail-no-format",
        name: "UI value detail without formatting support",
        adapter_argv: [ruby, adapter.to_s, log_path.to_s, "value_format_no_capability"],
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
      raise "no-format fixture should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      raise "no-format fixture launch should be accepted" unless controller.start(review).accepted?
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
        controller.snapshot.variables.nodes.any? { |node| node.name == "duplicate" }
      end
      panel.move_selection(2).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_screen_public.should contain("duplicate")

      # A rejected Hex request has no adapter detail, but its status and the
      # rejection cause must survive the modal's single bounded status row.
      app.dispatch_debug_event_public(Tui::KeyEvent.new('x')).should be_true
      narrow = app.debug_screen_resized_public(20, 26)
      narrow.should contain("Esc close")
      app.debug_screen_resized_public(112, 26)
      unavailable = app.debug_screen_public
      unavailable.should contain("Unavailable")
      unavailable.should contain("adapter did not advertise value-formatting support")

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.debug_modal_active_public.should be_false
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

  it "wraps and scrolls a clipped long value while retaining its identity and truncation state" do
    with_debug_editor_integration_root do |root|
      adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
      ruby = Process.find_executable("ruby") || raise "Ruby is required for the local DAP fixture"
      target = Process.find_executable("true") || "/usr/bin/true"
      log_path = root / "adapter.jsonl"
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "debug-editor-long-value-detail",
        name: "UI long value fixture",
        adapter_argv: [ruby, adapter.to_s, log_path.to_s, "value_json_provenance"],
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
      app.set_debug_dock_public(Adamantine::DebugInspectorDock::Bottom)
      review = controller.prepare_launch(profile, root)
      raise "long-value fixture should be reviewable: #{review.errors.join("; ")}" unless review.valid?
      raise "long-value fixture launch should be accepted" unless controller.start(review).accepted?
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
        controller.snapshot.variables.nodes.any? { |node| node.name == "prefix_json" }
      end
      panel.move_selection(3).should be_true
      selected = controller.snapshot.variables.nodes.find { |node| node.name == "prefix_json" } ||
                 raise "expected long prefix variable"
      selected.value_truncated.should be_true

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_modal_active_public.should be_true
      screen = app.debug_screen_public
      screen.should contain("prefix_json")
      screen.should contain("String")
      screen.should contain("display clipped")
      screen.should contain("value lines 1-")
      screen.should contain("[0]")
      initial_lines = app.debug_value_detail_lines_public

      # An unrelated output-generation update must reuse the cached wrapped
      # text rather than copying/re-wrapping the retained 64 KiB summary.
      app.refresh_value_detail_snapshot_public(debug_snapshot_with_unrelated_output(controller.snapshot))
      app.debug_value_detail_lines_public.object_id.should eq(initial_lines.object_id)

      # Width is part of the cache identity, so a resize rebuilds the wrapped
      # rows once while retaining the same authoritative variable identity.
      resized = app.debug_screen_resized_public(72, 26)
      resized.should contain("prefix_json")
      resized.should contain("display clipped")
      resized_lines = app.debug_value_detail_lines_public
      resized_lines.object_id.should_not eq(initial_lines.object_id)

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::PageDown)).should be_true
      scrolled = app.debug_screen_public
      scrolled.should contain("value lines 6-")
      scrolled.should_not contain("[0]")

      # A height-only resize reuses wrapped lines but clamps an End position
      # to the larger viewport's new maximum rather than stranding old rows.
      app.debug_screen_resized_public(72, 12)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::End)).should be_true
      small_view_scroll = app.debug_value_detail_scroll_public
      small_view_scroll.should be > 0
      line_cache_before_height_growth = app.debug_value_detail_lines_public
      app.debug_screen_resized_public(72, 26)
      grown_view_scroll = app.debug_value_detail_scroll_public
      grown_view_scroll.should eq(small_view_scroll - 2)
      app.debug_value_detail_lines_public.object_id.should eq(line_cache_before_height_growth.object_id)

      # At a ten-row terminal the single content row remains the value rather
      # than being overwritten by the status line; height-only resize still
      # reuses the cached wrapped rows.
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Home)).should be_true
      lines_before_short_view = app.debug_value_detail_lines_public
      short_view = app.debug_screen_resized_public(72, 10)
      short_view.should contain("[0]")
      short_view.should contain("value lines 1-1/")
      app.debug_value_detail_lines_public.object_id.should eq(lines_before_short_view.object_id)
      tiny_view = app.debug_screen_resized_public(72, 9)
      tiny_view.should contain("Resize to 10 rows to read detail")
      tiny_view.should_not contain("value lines 1-")

      # A stop/frame retirement invalidates the modal's source value instead
      # of leaving a stale pre-resume summary visible.
      app.refresh_value_detail_snapshot_public(debug_snapshot_continued(controller.snapshot))
      app.debug_screen_resized_public(72, 10)
      retired = app.debug_screen_public
      retired.should contain("Value unavailable; reopen detail")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
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
      app.debug_screen_public.should_not be_empty
      app.debug_dock_public.should eq(Adamantine::DebugInspectorDock::Left)
      files_rect = app.files_panel_rect_public
      rail_separator_x = app.debug_geometry_public.rail_separator_x.not_nil!
      files_rect.x.should eq(rail_separator_x + 1)
      files_rect.width.should eq(Adamantine::DebugInspectorLayout::DEFAULT_FILES_INSPECTOR_WIDTH)
      app.status_rect_public.x.should eq(0)
      app.status_rect_public.width.should eq(100)
      file_screen = app.debug_buffer_public(100, 24)
      file_screen.get(rail_separator_x, files_rect.y).glyph.should eq('│'.to_s)
      file_screen.get(files_rect.x, files_rect.y).glyph.should eq(" ")
      file_header = String.build do |header|
        (files_rect.x + 1...files_rect.right - 1).each do |x|
          header << file_screen.get(x, files_rect.y).glyph
        end
      end
      file_header.should contain(root.basename[-4, 4])
      files_rect.height.times do |offset|
        y = files_rect.y + offset
        file_screen.get(rail_separator_x, y).glyph.should eq('│'.to_s)
        file_screen.get(files_rect.right, y).glyph.should eq('│'.to_s)
        file_screen.get(files_rect.x, y).glyph.should eq(" ")
        file_screen.get(files_rect.right - 1, y).glyph.should eq(" ")
      end
      files_rect.width.times do |offset|
        x = files_rect.x + offset
        file_screen.get(x, files_rect.bottom - 1).glyph.should_not eq('─'.to_s)
      end

      app.set_activity_rail_padding_public(false)
      compact_files_rect = app.files_panel_rect_public
      compact_geometry = app.debug_geometry_public
      compact_separator_x = compact_geometry.rail_separator_x.not_nil!
      compact_files_rect.x.should eq(compact_separator_x + 1)
      compact_files_rect.x.should eq(2)
      compact_screen = app.debug_buffer_public(100, 24)
      compact_screen.get(compact_separator_x, compact_files_rect.y).glyph.should eq('│'.to_s)
      compact_screen.get(compact_files_rect.right, compact_files_rect.y).glyph.should eq('│'.to_s)
      app.set_activity_rail_padding_public(true)
      files_rect = app.files_panel_rect_public

      app.set_debug_rows_public(Adamantine::DebugPanel::Pane::Stack, ["one", "two", "three"] of String)

      # F2 is show/focus from the editor, then collapse only when Files itself
      # is focused. Ctrl+O remains an explicit show/focus action and never
      # inherits the F2 collapse behavior.
      app.focus_active_editor_public
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F2)).should be_true
      app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Files)
      app.file_panel_focused_public.should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F2)).should be_true
      app.files_inspector_hidden_public?.should be_true
      app.active_editor_focused_public?.should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new('o', Tui::Modifiers::Ctrl)).should be_true
      app.files_inspector_hidden_public?.should be_false
      app.file_panel_focused_public.should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new('o', Tui::Modifiers::Ctrl)).should be_true
      app.file_panel_focused_public.should be_true

      # The rail changes panels without selecting an editor document; clicking
      # Files again restores the retained tree state.
      app.dispatch_debug_event_public(Tui::MouseEvent.new(0, 8)).should be_true
      app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Debug)
      app.dispatch_debug_event_public(Tui::MouseEvent.new(0, 2)).should be_true
      app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Files)
      app.files_inspector_hidden_public?.should be_false

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

      # A modal blocks even a same-section request that would otherwise focus
      # the already selected Files widget behind it.
      app.dispatch_debug_event_public(Tui::MouseEvent.new(0, 2)).should be_true
      app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Files)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      app.debug_modal_active_public.should be_true
      app.select_files_inspector_public(true).should be_false
      app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Files)
      app.file_panel_focused_public.should be_false
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.debug_modal_active_public.should be_false
      app.document_text_public(path).should eq(before)

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

  it "reclaims hidden Files width before deciding whether an editor split fits" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path, "split width remains usable\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(65, 24)
      app.open_file_public(path).should be_true
      app.debug_screen_public(65, 24)
      app.focus_active_editor_public
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F2)).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F2)).should be_true
      app.files_inspector_hidden_public?.should be_true
      app.debug_screen_resized_public(65, 24)
      app.inspector_rect_public.width.should eq(65)

      app.split_editor_right_public.should be_true
      app.editor_split_open_public?.should be_true
      app.editor_split_parented_public?.should be_true
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "repairs inspector focus before input after a modal closes at an unusable size" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path, "modal resize must not route into a hidden inspector\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(112, 26)
      app.open_file_public(path).should be_true
      app.debug_screen_public
      app.show_debug_panel_public.should be_true
      app.debug_panel_focused_public.should be_true
      app.set_debug_rows_public(Adamantine::DebugPanel::Pane::Stack, ["frame one", "frame two"] of String)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      app.debug_modal_active_public.should be_true

      # The overlay remains active while the selected dock is resized out of
      # existence. Closing it must repair the saved underlying focus before
      # the next normal input event can reach the now-empty DebugPanel.
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F1))
      app.command_palette_open_public?.should be_false
      app.debug_modal_active_public.should be_true

      app.debug_screen_resized_public(24, 7)
      app.inspector_has_visible_public?.should be_false
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.debug_modal_active_public.should be_false
      app.debug_panel_focused_public.should be_false
      app.active_editor_focused_public?.should be_true

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
      app.debug_selected_row_public.should eq(0)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_selected_row_public.should eq(0)
      app.active_editor_focused_public?.should be_true
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "repairs modal-retained Debug focus on terminal resize before the first repaint" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      original = "resize before paint must not route into a stale inspector\n"
      File.write(path, original)
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(112, 26)
      app.open_file_public(path).should be_true
      app.debug_screen_public
      app.show_debug_panel_public.should be_true
      app.debug_panel_focused_public.should be_true
      app.set_debug_rows_public(Adamantine::DebugPanel::Pane::Stack, ["frame one", "frame two"] of String)
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
      app.debug_modal_active_public.should be_true

      # Model check_resize's root rect + ResizeEvent boundary, without letting
      # the throttled layout/render phase run before the modal closes.
      app.terminal_resize_before_paint_public(24, 7)
      app.rect.width.should eq(24)
      app.debug_modal_active_public.should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.debug_modal_active_public.should be_false
      app.document_text_public(path).should eq(original)

      # These are the first ordinary inputs after the modal closes. Neither
      # may reach the stale DebugPanel or alter the source under the editor.
      app.dispatch_debug_event_public(Tui::KeyEvent.new('j')).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_selected_row_public.should eq(0)
      app.debug_panel_focused_public.should be_false
      app.active_editor_focused_public?.should be_true
      app.document_text_public(path).should eq("j\n#{original}")
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "repairs focused Debug geometry on terminal resize before the first repaint" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      original = "resize before paint must not route into a stale inspector\n"
      File.write(path, original)
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(112, 26)
      app.open_file_public(path).should be_true
      app.debug_screen_public
      app.show_debug_panel_public.should be_true
      app.debug_panel_focused_public.should be_true
      app.set_debug_rows_public(Adamantine::DebugPanel::Pane::Stack, ["frame one", "frame two"] of String)

      # Input may arrive after check_resize but before the next paint has
      # propagated the new rect through the split and inspector widgets.
      app.terminal_resize_before_paint_public(24, 7)
      app.rect.width.should eq(24)
      app.document_text_public(path).should eq(original)
      app.dispatch_debug_event_public(Tui::KeyEvent.new('j')).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_selected_row_public.should eq(0)
      app.debug_panel_focused_public.should be_false
      app.active_editor_focused_public?.should be_true
      app.document_text_public(path).should eq("j\n#{original}")
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "repairs hidden Debug focus when F1 closes after an unusable resize" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path, "palette resize must not route into an invisible inspector\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(112, 26)
      app.open_file_public(path).should be_true
      app.debug_screen_public
      app.show_debug_panel_public.should be_true
      app.debug_panel_focused_public.should be_true
      app.set_debug_rows_public(Adamantine::DebugPanel::Pane::Stack, ["frame one", "frame two"] of String)
      app.set_key_hint_public("app.command_palette", "f1")
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F1)).should be_true
      app.command_palette_open_public?.should be_true

      app.debug_screen_resized_public(24, 7)
      app.inspector_has_visible_public?.should be_false
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.command_palette_open_public?.should be_false
      app.debug_panel_focused_public.should be_false
      app.active_editor_focused_public?.should be_true

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_selected_row_public.should eq(0)
      app.active_editor_focused_public?.should be_true
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "repairs hidden Debug focus after Quick Open closes at an unusable size" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path, "quick open resize must not route into an invisible inspector\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(112, 26)
      app.open_file_public(path).should be_true
      app.debug_screen_public
      app.show_debug_panel_public.should be_true
      app.debug_panel_focused_public.should be_true
      app.set_debug_rows_public(Adamantine::DebugPanel::Pane::Stack, ["frame one", "frame two"] of String)
      app.open_quick_open_public
      app.quick_open_open_public?.should be_true

      app.debug_screen_resized_public(24, 7)
      app.inspector_has_visible_public?.should be_false
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.quick_open_open_public?.should be_false
      app.debug_panel_focused_public.should be_false
      app.active_editor_focused_public?.should be_true

      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
      app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.debug_selected_row_public.should eq(0)
      app.active_editor_focused_public?.should be_true
    ensure
      app.try(&.close_debug_public)
    end
  end

  it "closes F1 discovery before presenting Files or Debug pane actions" do
    with_debug_editor_integration_root do |root|
      path = root / "main.cr"
      File.write(path, "palette presentations must leave modal routing first\n")
      app = DebugEditorIntegrationApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: nil,
        recovery_root: root / "recovery",
        session_enabled: false
      )
      app.mount_headless(112, 26)
      app.open_file_public(path).should be_true
      app.debug_screen_public
      app.focus_active_editor_public
      app.set_key_hint_public("app.command_palette", "f1")

      ["tree", "debug-panel", "debug-variables", "debug-toggle-panel"].each do |query|
        app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::F1))
        app.command_palette_open_public?.should be_true
        query.each_char do |char|
          app.dispatch_debug_event_public(Tui::KeyEvent.new(char)).should be_true
        end
        app.dispatch_debug_event_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.command_palette_open_public?.should be_false
        case query
        when "tree"
          app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Files)
          app.file_panel_focused_public.should be_true
        when "debug-panel"
          app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Debug)
          app.debug_panel_focused_public.should be_true
        when "debug-variables"
          app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Debug)
          app.debug_selected_pane_public.should eq(Adamantine::DebugPanel::Pane::Variables)
          app.debug_panel_focused_public.should be_true
        when "debug-toggle-panel"
          app.inspector_section_public.should eq(Adamantine::DebugInspectorSection::Files)
          app.debug_panel_focused_public.should be_false
          app.active_editor_focused_public?.should be_true
        end
        app.focus_active_editor_public
      end
    ensure
      app.try(&.close_debug_public)
    end
  end
end
