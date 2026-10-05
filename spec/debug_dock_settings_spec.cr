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

describe Adamantine::SettingsConfig do
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
