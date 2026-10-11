require "spec"
require "file_utils"
require "json"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private def with_debug_dock_settings_workspace(prefix : String = "adamantine-debug-dock-settings", &)
  root = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  initial_overlays = Tui.overlays.dup
  initial_focus = Tui::Widget.focused_widget
  initial_app = Tui.current_app
  Dir.mkdir_p(root)
  yield root
ensure
  Tui.overlays.replace(initial_overlays) if initial_overlays
  if focused = Tui::Widget.focused_widget
    focused.focused = false unless initial_focus && focused.same?(initial_focus)
  end
  Tui::Widget.focused_widget = nil
  initial_focus.try(&.focus)
  Tui.current_app = initial_app
  FileUtils.rm_rf(root) if root
end

private class DebugDockSettingsTestApp < Adamantine::App
  def settings_actions_public : Array(String)
    @settings.actions
  end

  def settings_open_public? : Bool
    @settings.open
  end

  def close_settings_for_test : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape)) if @settings.open
  end

  def settings_debug_dock_public : Adamantine::DebugInspectorDock
    @settings.debug_dock
  end

  def debug_layout_dock_public : Adamantine::DebugInspectorDock
    @inspector_layout.debug_dock
  end

  def activity_rail_padding_public : Bool
    @settings.activity_rail_padding
  end

  def layout_activity_rail_padding_public : Bool
    @inspector_layout.activity_rail_padding
  end

  def rail_columns_public : Int32
    @inspector_layout.rail_columns
  end

  def estimated_editor_width_public(width : Int32) : Int32
    estimated_editor_width(width)
  end

  def minimum_split_window_width_public : Int32
    minimum_split_window_width
  end

  def projected_editor_width_public(padding : Bool) : Int32
    @inspector_layout.geometry_for_activity_rail_padding(padding).editor.width
  end

  def split_editor_right_public : Bool
    split_editor_right
  end

  def right_editor_group_open_public? : Bool
    !@right_editor_tabs.nil?
  end

  def active_editor_group_public : Int32
    @active_editor_group
  end

  def focused_widget_public : Tui::Widget?
    Tui::Widget.focused_widget
  end

  def left_tab_ids_public : Array(String)
    @editor_tabs.tabs.map(&.id)
  end

  def right_tab_ids_public : Array(String)
    if panel = @right_editor_tabs
      panel.tabs.map(&.id)
    else
      [] of String
    end
  end

  def settings_display_name_public(action : String) : String
    settings_display_name(action)
  end

  def settings_display_value_public(action : String) : String
    settings_display_value(action)
  end

  def status_messages_public : Array(String)
    @status_log.entries.map(&.message)
  end

  def debug_modal_open_public? : Bool
    debug_modal_active?
  end

  def activity_rail_action_name_public(action : String) : String
    settings_display_name(action)
  end

  def activity_rail_action_value_public(action : String) : String
    settings_display_value(action)
  end

  def debug_lifecycle_public : Adamantine::DebugSessionState::Lifecycle
    @debug_controller.snapshot.state.lifecycle
  end

  def debug_breakpoint_count_public : Int32
    @debug_controller.snapshot.breakpoints.size
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def prepare_debug_surface_public(width : Int32 = 100, height : Int32 = 32) : Bool
    @inspector_layout.rect = Tui::Rect.new(0, 0, width, height)
    @inspector_layout.select_section(Adamantine::DebugInspectorSection::Debug)
  end

  def hide_files_public : Bool
    @inspector_layout.hide_files_inspector
  end

  def select_bottom_debug_public : Nil
    @settings.debug_dock = Adamantine::DebugInspectorDock::Bottom
    @inspector_layout.debug_dock = Adamantine::DebugInspectorDock::Bottom
    @inspector_layout.select_section(Adamantine::DebugInspectorSection::Debug)
  end

  def debug_geometry_public : Adamantine::DebugInspectorGeometry
    @inspector_layout.geometry
  end

  def settings_screen_public(width : Int32 = 100, height : Int32 = 32) : String
    self.rect = Tui::Rect.new(0, 0, width, height)
    surface = Tui::Buffer.new(width, height)
    render(surface, Tui::Rect.new(0, 0, width, height))
    String.build do |output|
      height.times do |y|
        width.times { |x| output << surface.get(x, y).glyph }
        output << '\n'
      end
    end
  end
end

private def open_debug_dock_settings_through_f1(app : DebugDockSettingsTestApp) : Nil
  app.on_capture(Tui::KeyEvent.new(Tui::Key::F1)).should be_true
  "settings".each_char do |char|
    app.on_capture(Tui::KeyEvent.new(char)).should be_true
  end
  app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
  app.settings_open_public?.should be_true
end

private def select_debug_dock_setting(app : DebugDockSettingsTestApp) : Nil
  action = "setting:debug.dock"
  index = app.settings_actions_public.index(action) || raise "Settings does not expose #{action}"
  index.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)).should be_true }
end

private def select_activity_rail_padding_setting(app : DebugDockSettingsTestApp) : Nil
  action = "setting:ui.activity_rail_padding"
  index = app.settings_actions_public.index(action) || raise "Settings does not expose #{action}"
  index.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)).should be_true }
end

private def assert_debug_dock_geometry(app : DebugDockSettingsTestApp, expected : Adamantine::DebugInspectorDock) : Nil
  geometry = app.debug_geometry_public
  geometry.dock.should eq(expected)
  geometry.effective_dock.should eq(expected)
  inspector = geometry.inspector || raise "Debug inspector is missing for #{expected} dock"

  case expected
  when .left?
    inspector.x.should be < geometry.editor.x
    geometry.inspector_separator_x.should_not be_nil
  when .right?
    inspector.x.should be > geometry.editor.x
    geometry.inspector_separator_x.should_not be_nil
  when .bottom?
    inspector.y.should be > geometry.editor.y
    geometry.inspector_separator_y.should_not be_nil
  end
end

describe "Debug dock Settings UI" do
  it "uses the F1 Settings route, shows the current value and hint, isolates F5/F9, and cycles and reloads the saved dock" do
    with_debug_dock_settings_workspace do |root|
      path = (root / "config.json").to_s
      File.write(path, {
        "plugin" => {"enabled" => true, "custom" => "keep"},
        "keymap" => {"app.save" => ["ctrl+alt+s"], "custom.action" => ["f12"]},
        "lsp"    => {"max_response_mib" => 8, "custom" => "keep"},
        "debug"  => {"max_message_mib" => 32, "dock" => "left", "custom" => "keep"},
      }.to_json)
      source = root / "sample.cr"
      File.write(source, "puts 1\n")

      app_ref : DebugDockSettingsTestApp? = nil
      reloaded_ref : DebugDockSettingsTestApp? = nil
      begin
        app = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
        app_ref = app
        app.settings_debug_dock_public.should eq(Adamantine::DebugInspectorDock::Left)
        app.open_file_public(source).should be_true
        app.prepare_debug_surface_public.should be_true
        assert_debug_dock_geometry(app, Adamantine::DebugInspectorDock::Left)

        open_debug_dock_settings_through_f1(app)
        action = "setting:debug.dock"
        app.settings_actions_public.includes?(action).should be_true
        app.settings_display_name_public(action).should eq("Debug dock position")
        app.settings_display_value_public(action).should eq("Left")
        select_debug_dock_setting(app)
        screen = app.settings_screen_public
        screen.should contain("Debug dock position")
        screen.should contain("Left")
        screen.should contain("Enter cycles Debug dock: Left, Right, Bottom; Files stays left")

        app.on_capture(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
        app.on_capture(Tui::KeyEvent.new(Tui::Key::F9)).should be_true
        app.settings_open_public?.should be_true
        app.debug_modal_open_public?.should be_false
        app.debug_lifecycle_public.should eq(Adamantine::DebugSessionState::Lifecycle::Idle)
        app.debug_breakpoint_count_public.should eq(0)
        app.settings_debug_dock_public.should eq(Adamantine::DebugInspectorDock::Left)

        [
          {Adamantine::DebugInspectorDock::Right, "right"},
          {Adamantine::DebugInspectorDock::Bottom, "bottom"},
          {Adamantine::DebugInspectorDock::Left, "left"},
          {Adamantine::DebugInspectorDock::Right, "right"},
        ].each do |dock, serialized|
          app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
          app.settings_debug_dock_public.should eq(dock)
          app.debug_layout_dock_public.should eq(dock)
          assert_debug_dock_geometry(app, dock)
          JSON.parse(File.read(path))["debug"]["dock"].as_s.should eq(serialized)
          app.status_messages_public.any? { |message| message == "Debug dock: #{dock.to_s} (saved)" }.should be_true
        end

        app.close_settings_for_test
        app.settings_open_public?.should be_false
        app.quit(force: true)
        app_ref = nil
        reloaded = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
        reloaded_ref = reloaded
        reloaded.settings_debug_dock_public.should eq(Adamantine::DebugInspectorDock::Right)
        reloaded.debug_layout_dock_public.should eq(Adamantine::DebugInspectorDock::Right)
        reloaded.prepare_debug_surface_public.should be_true
        assert_debug_dock_geometry(reloaded, Adamantine::DebugInspectorDock::Right)
      ensure
        app_ref.try do |app|
          app.close_settings_for_test
          app.quit(force: true)
        end
        reloaded_ref.try(&.quit(force: true))
      end
    end
  end

  it "keeps a changed dock in memory and reports the failed save" do
    with_debug_dock_settings_workspace do |root|
      blocker = root / "not-a-directory"
      File.write(blocker, "preserve")
      path = (blocker / "config.json").to_s

      app = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
      begin
        app.prepare_debug_surface_public.should be_true
        open_debug_dock_settings_through_f1(app)
        select_debug_dock_setting(app)
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true

        app.settings_debug_dock_public.should eq(Adamantine::DebugInspectorDock::Right)
        app.debug_layout_dock_public.should eq(Adamantine::DebugInspectorDock::Right)
        assert_debug_dock_geometry(app, Adamantine::DebugInspectorDock::Right)
        app.status_messages_public.any? { |message| message == "Debug dock: Right (not saved; using in memory)" }.should be_true
        File.read(blocker).should eq("preserve")
        Adamantine::SettingsConfig.load_debug_dock(path).should eq(Adamantine::DebugInspectorDock::Left)
      ensure
        app.close_settings_for_test
        app.quit(force: true)
      end
    end
  end
end

describe "Activity rail padding Settings UI" do
  it "rejects padding at 78 columns without changing config, split, or Settings focus, then accepts at 80" do
    with_debug_dock_settings_workspace("adamantine-activity-rail-split-boundary") do |root|
      path = root / "config.json"
      File.write(path, {"ui" => {"activity_rail_padding" => false, "keep" => "exact bytes"}}.to_json)
      left = root / "left.cr"
      right = root / "right.cr"
      File.write(left, "left = 1\n")
      File.write(right, "right = 2\n")

      app_ref : DebugDockSettingsTestApp? = nil
      begin
        app = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path.to_s, session_enabled: false)
        app_ref = app
        app.mount_headless(78, 32)
        app.activity_rail_padding_public.should be_false
        app.minimum_split_window_width_public.should eq(78)
        app.open_file_public(left).should be_true
        app.split_editor_right_public.should be_true
        app.open_file_public(right).should be_true
        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(1)
        left_tabs = app.left_tab_ids_public
        right_tabs = app.right_tab_ids_public

        open_debug_dock_settings_through_f1(app)
        select_activity_rail_padding_setting(app)
        app.settings_screen_public(78, 32)
        focused_before_toggle = app.focused_widget_public || raise "settings transition left no focused widget"
        config_before_toggle = File.read(path)

        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.activity_rail_padding_public.should be_false
        app.layout_activity_rail_padding_public.should be_false
        app.rail_columns_public.should eq(2)
        File.read(path).should eq(config_before_toggle)
        app.settings_open_public?.should be_true
        app.settings_screen_public(78, 32).should contain("Cannot enable: shrink/hide Files or widen to 80 columns")
        app.refresh
        app.settings_screen_public(78, 32)

        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(1)
        app.left_tab_ids_public.should eq(left_tabs)
        app.right_tab_ids_public.should eq(right_tabs)
        app.focused_widget_public.should be(focused_before_toggle)

        app.rect = Tui::Rect.new(0, 0, 80, 32)
        app.refresh
        app.projected_editor_width_public(true).should eq(51)
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.activity_rail_padding_public.should be_true
        app.layout_activity_rail_padding_public.should be_true
        app.rail_columns_public.should eq(4)
        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(1)
        app.left_tab_ids_public.should eq(left_tabs)
        app.right_tab_ids_public.should eq(right_tabs)
        app.focused_widget_public.should be(focused_before_toggle)
        JSON.parse(File.read(path))["ui"]["activity_rail_padding"].as_bool.should be_true

        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.activity_rail_padding_public.should be_false
        app.layout_activity_rail_padding_public.should be_false
        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(1)
        app.left_tab_ids_public.should eq(left_tabs)
        app.right_tab_ids_public.should eq(right_tabs)
        app.focused_widget_public.should be(focused_before_toggle)
        JSON.parse(File.read(path))["ui"]["activity_rail_padding"].as_bool.should be_false
      ensure
        app_ref.try do |app|
          app.close_settings_for_test
          app.quit(force: true)
        end
      end
    end
  end

  it "uses hidden Files geometry for the padding guard and permits retry at 55 columns" do
    with_debug_dock_settings_workspace("adamantine-activity-rail-hidden-files-boundary") do |root|
      path = root / "config.json"
      File.write(path, {"ui" => {"activity_rail_padding" => false}}.to_json)
      left = root / "left.cr"
      right = root / "right.cr"
      File.write(left, "left = 1\n")
      File.write(right, "right = 2\n")

      app_ref : DebugDockSettingsTestApp? = nil
      begin
        app = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path.to_s, session_enabled: false)
        app_ref = app
        app.mount_headless(53, 32)
        app.hide_files_public.should be_true
        app.refresh
        app.open_file_public(left).should be_true
        app.split_editor_right_public.should be_true
        app.open_file_public(right).should be_true
        app.right_editor_group_open_public?.should be_true

        open_debug_dock_settings_through_f1(app)
        select_activity_rail_padding_setting(app)
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.activity_rail_padding_public.should be_false
        app.settings_screen_public(53, 32).should contain("Cannot enable: widen to 55 columns")
        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(1)

        app.rect = Tui::Rect.new(0, 0, 55, 32)
        app.refresh
        app.projected_editor_width_public(true).should eq(51)
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.activity_rail_padding_public.should be_true
        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(1)
      ensure
        app_ref.try do |app|
          app.close_settings_for_test
          app.quit(force: true)
        end
      end
    end
  end

  it "uses Bottom Debug geometry for the padding guard without a side-inspector hint" do
    with_debug_dock_settings_workspace("adamantine-activity-rail-bottom-debug-boundary") do |root|
      path = root / "config.json"
      File.write(path, {"ui" => {"activity_rail_padding" => false}}.to_json)
      left = root / "left.cr"
      right = root / "right.cr"
      File.write(left, "left = 1\n")
      File.write(right, "right = 2\n")

      app_ref : DebugDockSettingsTestApp? = nil
      begin
        app = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path.to_s, session_enabled: false)
        app_ref = app
        app.mount_headless(53, 32)
        app.select_bottom_debug_public
        app.refresh
        app.open_file_public(left).should be_true
        app.split_editor_right_public.should be_true
        app.open_file_public(right).should be_true
        app.right_editor_group_open_public?.should be_true

        open_debug_dock_settings_through_f1(app)
        select_activity_rail_padding_setting(app)
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.activity_rail_padding_public.should be_false
        screen = app.settings_screen_public(53, 32)
        screen.should contain("Cannot enable: widen to 55 columns")
        screen.should_not contain("shrink/hide Debug")
        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(1)

        app.rect = Tui::Rect.new(0, 0, 55, 32)
        app.refresh
        app.projected_editor_width_public(true).should eq(51)
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.activity_rail_padding_public.should be_true
        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(1)
        app.debug_geometry_public.effective_dock.should eq(Adamantine::DebugInspectorDock::Bottom)
      ensure
        app_ref.try do |app|
          app.close_settings_for_test
          app.quit(force: true)
        end
      end
    end
  end

  it "toggles live geometry, preserves modal/editor/debug state, and reloads the saved preference" do
    with_debug_dock_settings_workspace("adamantine-activity-rail-settings") do |root|
      path = (root / "config.json").to_s
      File.write(path, {
        "plugin" => {"custom" => "preserve"},
        "keymap" => {"app.save" => ["ctrl+alt+s"]},
        "ui"     => {"activity_rail_padding" => true, "unknown" => 17},
        "debug"  => {"max_message_mib" => 16, "dock" => "left"},
      }.to_json)
      source_left = root / "left.cr"
      source_right = root / "right.cr"
      File.write(source_left, "left = 1\n")
      File.write(source_right, "right = 2\n")

      app_ref : DebugDockSettingsTestApp? = nil
      reloaded_ref : DebugDockSettingsTestApp? = nil
      begin
        app = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
        app_ref = app
        app.settings_screen_public(100, 32)
        app.prepare_debug_surface_public(100, 32).should be_true
        app.open_file_public(source_left).should be_true
        app.split_editor_right_public.should be_true
        app.open_file_public(source_right).should be_true

        app.activity_rail_padding_public.should be_true
        app.layout_activity_rail_padding_public.should be_true
        app.rail_columns_public.should eq(4)
        old_editor_width = app.estimated_editor_width_public(100)
        old_minimum_width = app.minimum_split_window_width_public
        left_tabs = app.left_tab_ids_public
        right_tabs = app.right_tab_ids_public
        active_group = app.active_editor_group_public
        app.right_editor_group_open_public?.should be_true

        open_debug_dock_settings_through_f1(app)
        action = "setting:ui.activity_rail_padding"
        app.settings_actions_public.includes?(action).should be_true
        app.activity_rail_action_name_public(action).should eq("Activity rail padding")
        app.activity_rail_action_value_public(action).should eq("on")
        select_activity_rail_padding_setting(app)
        app.settings_screen_public.should contain("Activity rail padding")
        app.settings_screen_public.should contain("Enter toggles activity rail padding")

        app.on_capture(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
        app.on_capture(Tui::KeyEvent.new(Tui::Key::F9)).should be_true
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true

        app.settings_open_public?.should be_true
        app.activity_rail_padding_public.should be_false
        app.layout_activity_rail_padding_public.should be_false
        app.rail_columns_public.should eq(2)
        app.estimated_editor_width_public(100).should eq(old_editor_width + 2)
        app.minimum_split_window_width_public.should eq(old_minimum_width - 2)
        app.right_editor_group_open_public?.should be_true
        app.active_editor_group_public.should eq(active_group)
        app.left_tab_ids_public.should eq(left_tabs)
        app.right_tab_ids_public.should eq(right_tabs)
        app.debug_lifecycle_public.should eq(Adamantine::DebugSessionState::Lifecycle::Idle)
        app.debug_breakpoint_count_public.should eq(0)
        app.debug_modal_open_public?.should be_false

        saved = JSON.parse(File.read(path))
        saved["ui"]["activity_rail_padding"].as_bool.should be_false
        saved["ui"]["unknown"].as_i.should eq(17)
        saved["plugin"]["custom"].as_s.should eq("preserve")
        saved["keymap"]["app.save"][0].as_s.should eq("ctrl+alt+s")
        app.status_messages_public.any? { |message| message == "Activity rail padding: off (saved)" }.should be_true

        app.close_settings_for_test
        app.quit(force: true)
        app_ref = nil
        reloaded = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
        reloaded_ref = reloaded
        reloaded.activity_rail_padding_public.should be_false
        reloaded.layout_activity_rail_padding_public.should be_false
        reloaded.rail_columns_public.should eq(2)
      ensure
        app_ref.try do |app|
          app.close_settings_for_test
          app.quit(force: true)
        end
        reloaded_ref.try(&.quit(force: true))
      end
    end
  end

  it "keeps a compact choice in memory and reports a failed save" do
    with_debug_dock_settings_workspace("adamantine-activity-rail-save-failure") do |root|
      blocker = root / "not-a-directory"
      File.write(blocker, "preserve")
      path = (blocker / "config.json").to_s
      app = DebugDockSettingsTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
      begin
        app.prepare_debug_surface_public.should be_true
        open_debug_dock_settings_through_f1(app)
        select_activity_rail_padding_setting(app)
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.activity_rail_padding_public.should be_false
        app.layout_activity_rail_padding_public.should be_false
        app.rail_columns_public.should eq(2)
        app.status_messages_public.any? { |message| message == "Activity rail padding: off (not saved; using in memory)" }.should be_true
        File.read(blocker).should eq("preserve")
        Adamantine::SettingsConfig.load_activity_rail_padding(path).should be_true
      ensure
        app.close_settings_for_test
        app.quit(force: true)
      end
    end
  end
end

describe Adamantine::SettingsConfig do
  it "strictly loads and safely saves the activity rail padding preference" do
    with_debug_dock_settings_workspace("adamantine-activity-rail-config") do |root|
      path = (root / "config.json").to_s
      warnings = [] of String
      callback = ->(message : String) : Nil { warnings << message }

      Adamantine::SettingsConfig.load_activity_rail_padding(path, callback).should be_true
      File.write(path, %({"keymap":{},"unknown":"keep"}))
      warnings.clear
      Adamantine::SettingsConfig.load_activity_rail_padding(path, callback).should be_true
      warnings.should be_empty

      [true, false].each do |value|
        warnings.clear
        File.write(path, {"ui" => {"activity_rail_padding" => value}}.to_json)
        Adamantine::SettingsConfig.load_activity_rail_padding(path, callback).should eq(value)
        warnings.should be_empty
      end

      [
        %({"ui":"not-an-object"}),
        %({"ui":{"activity_rail_padding":"yes"}}),
        %({"ui":{"activity_rail_padding":1}}),
        %({"ui":{"activity_rail_padding":null}}),
      ].each do |contents|
        warnings.clear
        File.write(path, contents)
        Adamantine::SettingsConfig.load_activity_rail_padding(path, callback).should be_true
        warnings.any? { |warning| warning.includes?(path) && warning.includes?("ui.activity_rail_padding") }.should be_true
      end

      File.write(path, {
        "plugin" => {"opaque" => [1, true]},
        "keymap" => {"app.save" => ["ctrl+x"]},
        "ui"     => {"activity_rail_padding" => true, "unknown" => "keep"},
        "debug"  => {"dock" => "right"},
      }.to_json)
      Adamantine::SettingsConfig.save_activity_rail_padding(path, false)
      saved = JSON.parse(File.read(path))
      saved["ui"]["activity_rail_padding"].as_bool.should be_false
      saved["ui"]["unknown"].as_s.should eq("keep")
      saved["plugin"].should eq(JSON.parse(%({"opaque":[1,true]})))
      saved["keymap"]["app.save"][0].as_s.should eq("ctrl+x")
      saved["debug"]["dock"].as_s.should eq("right")

      [
        %({"ui":"not-an-object"}),
        %({"malformed":),
        %(["not a root object"]),
      ].each do |contents|
        File.write(path, contents)
        expect_raises(Exception) { Adamantine::SettingsConfig.save_activity_rail_padding(path, false) }
        File.read(path).should eq(contents)
      end
    end
  end

  it "defaults a missing dock to Left, accepts the three exact strings, and warns for invalid objects and values" do
    with_debug_dock_settings_workspace("adamantine-debug-dock-config") do |root|
      path = (root / "config.json").to_s
      warnings = [] of String
      callback = ->(message : String) : Nil { warnings << message }

      Adamantine::SettingsConfig.load_debug_dock(path, callback).should eq(Adamantine::DebugInspectorDock::Left)
      File.write(path, %({"keymap":{}}))
      Adamantine::SettingsConfig.load_debug_dock(path, callback).should eq(Adamantine::DebugInspectorDock::Left)
      File.write(path, %({"debug":{"other":"keep"}}))
      Adamantine::SettingsConfig.load_debug_dock(path, callback).should eq(Adamantine::DebugInspectorDock::Left)
      warnings.should be_empty

      {
        "left"   => Adamantine::DebugInspectorDock::Left,
        "right"  => Adamantine::DebugInspectorDock::Right,
        "bottom" => Adamantine::DebugInspectorDock::Bottom,
      }.each do |value, expected|
        warnings.clear
        File.write(path, {"debug" => {"dock" => value}}.to_json)
        Adamantine::SettingsConfig.load_debug_dock(path, callback).should eq(expected)
        warnings.should be_empty
      end

      invalid_configs = [
        %({"debug":"not an object"}),
        %({"debug":null}),
        %({"debug":[]}),
        %({"debug":{"dock":"Left"}}),
        %({"debug":{"dock":"diagonal"}}),
        %({"debug":{"dock":1}}),
        %({"debug":{"dock":1.5}}),
        %({"debug":{"dock":true}}),
        %({"debug":{"dock":null}}),
      ]
      invalid_configs.each do |contents|
        warnings.clear
        File.write(path, contents)
        Adamantine::SettingsConfig.load_debug_dock(path, callback).should eq(Adamantine::DebugInspectorDock::Left)
        warnings.any? { |warning| warning.includes?(path) && warning.includes?("Invalid debug dock setting") && warning.includes?("left") }.should be_true
      end
    end
  end

  it "saves the dock privately while preserving unknown settings and keymap fields" do
    with_debug_dock_settings_workspace("adamantine-debug-dock-save") do |root|
      path = (root / "config.json").to_s
      File.write(path, {
        "plugin" => {"enabled" => true, "opaque" => "keep"},
        "keymap" => {"app.save" => ["ctrl+x"], "custom.action" => ["f12"]},
        "lsp"    => {"max_response_mib" => 8, "unknown" => "keep"},
        "debug"  => {"max_message_mib" => 16, "dock" => "left", "unknown" => "keep"},
      }.to_json)
      File.chmod(path, 0o644)

      Adamantine::SettingsConfig.save_debug_dock(path, Adamantine::DebugInspectorDock::Right)
      (File.info(path).permissions.value & 0o777).should eq(0o600)
      saved = JSON.parse(File.read(path))
      saved["debug"]["dock"].as_s.should eq("right")
      saved["debug"]["max_message_mib"].as_i.should eq(16)
      saved["debug"]["unknown"].as_s.should eq("keep")
      saved["lsp"]["max_response_mib"].as_i.should eq(8)
      saved["lsp"]["unknown"].as_s.should eq("keep")
      saved["keymap"]["app.save"][0].as_s.should eq("ctrl+x")
      saved["keymap"]["custom.action"][0].as_s.should eq("f12")
      saved["plugin"]["opaque"].as_s.should eq("keep")

      {
        {Adamantine::DebugInspectorDock::Bottom, "bottom"},
        {Adamantine::DebugInspectorDock::Left, "left"},
      }.each do |dock, serialized|
        Adamantine::SettingsConfig.save_debug_dock(path, dock)
        JSON.parse(File.read(path))["debug"]["dock"].as_s.should eq(serialized)
        Adamantine::SettingsConfig.load_debug_dock(path).should eq(dock)
      end
    end
  end
end
