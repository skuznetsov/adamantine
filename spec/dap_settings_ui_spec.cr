require "spec"
require "file_utils"
require "json"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private def with_dap_settings_workspace(prefix : String = "adamantine-dap-settings", &)
  root = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private class DapSettingsUiTestApp < Adamantine::App
  def debug_message_mib_public : Int32
    @settings.max_debug_message_mib
  end

  def settings_actions_public : Array(String)
    @settings.actions
  end

  def settings_open_public? : Bool
    @settings.open
  end

  def settings_display_name_public(action : String) : String
    settings_display_name(action)
  end

  def settings_display_value_public(action : String) : String
    settings_display_value(action)
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

  def status_messages_public : Array(String)
    @status_log.entries.map(&.message)
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
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

private def open_settings_through_commands(app : DapSettingsUiTestApp) : Nil
  app.on_capture(Tui::KeyEvent.new(Tui::Key::F1)).should be_true
  "settings".each_char do |char|
    app.on_capture(Tui::KeyEvent.new(char)).should be_true
  end
  app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
end

private def select_and_activate_setting(app : DapSettingsUiTestApp, action : String) : Nil
  index = app.settings_actions_public.index(action) || raise "Settings does not expose #{action}"
  index.times do
    app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
  end
  app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
end

private def await_dap_controller(controller : Adamantine::DebugController,
                                 timeout : Time::Span = 3.seconds,
                                 &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.instant + timeout
  latest = controller.poll
  until ready.call(latest)
    if Time.instant >= deadline
      raise "debug controller did not reach the expected state: lifecycle=#{latest.state.lifecycle}, execution=#{latest.state.execution}, last_error=#{latest.last_error}"
    end
    sleep 5.milliseconds
    latest = controller.poll
  end
  latest
end

private def dap_settings_launch_profile(root : Path) : Adamantine::Debugging::LaunchProfile
  ruby = Process.find_executable("ruby") || raise "Ruby is required for the DAP settings sampling spec"
  adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
  canonical_root = Path.new(File.realpath(root.to_s))
  Adamantine::Debugging::LaunchProfile.new(
    id: "settings-sampling",
    name: "Settings sampling fixture",
    adapter_argv: [ruby, adapter.to_s, (root / "adapter.jsonl").to_s, "stop_before_launch_response"],
    program: Process.find_executable("true") || "/usr/bin/true",
    cwd: canonical_root.to_s
  )
end

describe "DAP message limit Settings UI" do
  it "shows the limit, isolates F5/F9, cycles within bounds, and persists for the next Start" do
    with_dap_settings_workspace do |root|
      path = (root / "config.json").to_s
      original = {
        "plugin" => {"enabled" => true},
        "keymap" => {"app.save" => ["ctrl+alt+s"]},
        "lsp"    => {"max_response_mib" => 8, "custom" => "preserve"},
        "debug"  => {"max_message_mib" => 64, "custom" => "preserve"},
      }
      File.write(path, original.to_json)
      source = root / "sample.cr"
      File.write(source, "puts 1\n")

      app_ref : DapSettingsUiTestApp? = nil
      reloaded_ref : DapSettingsUiTestApp? = nil
      begin
        app = DapSettingsUiTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
        app_ref = app
        app.debug_message_mib_public.should eq(64)
        app.open_file_public(source).should be_true
        open_settings_through_commands(app)

        action = "setting:debug.max_message_mib"
        app.settings_actions_public.includes?(action).should be_true
        app.settings_display_name_public(action).should eq("DAP message limit")
        app.settings_display_value_public(action).should eq("64 MiB")

        index = app.settings_actions_public.index(action) || raise "DAP row disappeared"
        index.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)).should be_true }
        screen = app.settings_screen_public
        screen.should contain("DAP message limit")
        screen.should contain("64 MiB")
        screen.should contain("next Start")
        screen.should contain("not current session")

        app.on_capture(Tui::KeyEvent.new(Tui::Key::F5)).should be_true
        app.on_capture(Tui::KeyEvent.new(Tui::Key::F9)).should be_true
        app.settings_open_public?.should be_true
        app.debug_modal_open_public?.should be_false
        app.debug_lifecycle_public.should eq(Adamantine::DebugSessionState::Lifecycle::Idle)
        app.debug_breakpoint_count_public.should eq(0)

        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
        app.debug_message_mib_public.should eq(1)
        persisted = JSON.parse(File.read(path))
        persisted["debug"]["max_message_mib"].as_i.should eq(1)
        persisted["debug"]["custom"].as_s.should eq("preserve")
        persisted["lsp"]["max_response_mib"].as_i.should eq(8)
        persisted["lsp"]["custom"].as_s.should eq("preserve")
        persisted["keymap"]["app.save"][0].as_s.should eq("ctrl+alt+s")
        persisted["plugin"]["enabled"].as_bool.should be_true

        app.quit(force: true)
        app_ref = nil
        reloaded = DapSettingsUiTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
        reloaded_ref = reloaded
        reloaded.debug_message_mib_public.should eq(1)
      ensure
        app_ref.try(&.quit(force: true))
        reloaded_ref.try(&.quit(force: true))
      end
    end
  end

  it "reports a failed write and keeps the on-disk configuration unchanged" do
    with_dap_settings_workspace do |root|
      blocker = root / "not-a-directory"
      File.write(blocker, "preserve")
      path = (blocker / "config.json").to_s

      app = DapSettingsUiTestApp.new(project_root: root, lsp_command: "", keymap_path: path, session_enabled: false)
      begin
        open_settings_through_commands(app)
        select_and_activate_setting(app, "setting:debug.max_message_mib")

        app.debug_message_mib_public.should eq(32)
        app.status_messages_public.any? { |message| message.includes?("DAP message limit: 32 MiB (not saved; using in memory; applies at next Start)") }.should be_true
        File.read(blocker).should eq("preserve")
        Adamantine::SettingsConfig.load_debug_message_mib(path).should eq(16)
      ensure
        app.quit(force: true)
      end
    end
  end
end

describe Adamantine::SettingsConfig do
  it "loads defaults and strictly bounds DAP message limits to 1 through 64 MiB" do
    with_dap_settings_workspace("adamantine-dap-config") do |root|
      path = (root / "config.json").to_s
      warnings = [] of String
      callback = ->(message : String) : Nil { warnings << message }

      Adamantine::SettingsConfig.load_debug_message_mib(path, callback).should eq(16)
      [1, 64].each do |value|
        File.write(path, {"debug" => {"max_message_mib" => value}}.to_json)
        Adamantine::SettingsConfig.load_debug_message_mib(path, callback).should eq(value)
      end
      warnings.should be_empty

      [0, 65, "16", 16.5].each do |value|
        warnings.clear
        File.write(path, {"debug" => {"max_message_mib" => value}}.to_json)
        Adamantine::SettingsConfig.load_debug_message_mib(path, callback).should eq(16)
        warnings.any? { |warning| warning.includes?("debug.max_message_mib") }.should be_true
        warnings.any? { |warning| warning.includes?("1–64 MiB") }.should be_true
        warnings.any? { |warning| warning.includes?("F1 Commands > Settings") }.should be_true
      end
    end
  end

  it "saves bounded DAP limits privately while preserving unknown config and keymap fields" do
    with_dap_settings_workspace("adamantine-dap-save") do |root|
      path = (root / "config.json").to_s
      original = {
        "plugin" => {"enabled" => true, "opaque" => "keep"},
        "keymap" => {"app.save" => ["ctrl+alt+s"], "custom.action" => ["f12"]},
        "lsp"    => {"max_response_mib" => 8, "unknown" => "keep"},
        "debug"  => {"max_message_mib" => 16, "unknown" => "keep"},
      }
      File.write(path, original.to_json)
      File.chmod(path, 0o644)

      Adamantine::SettingsConfig.save_debug_message_mib(path, 64)
      (File.info(path).permissions.value & 0o777).should eq(0o600)
      saved = JSON.parse(File.read(path))
      saved["debug"]["max_message_mib"].as_i.should eq(64)
      saved["debug"]["unknown"].as_s.should eq("keep")
      saved["lsp"]["unknown"].as_s.should eq("keep")
      saved["keymap"]["app.save"][0].as_s.should eq("ctrl+alt+s")
      saved["keymap"]["custom.action"][0].as_s.should eq("f12")
      saved["plugin"]["opaque"].as_s.should eq("keep")

      [0, 65].each do |value|
        expect_raises(ArgumentError) { Adamantine::SettingsConfig.save_debug_message_mib(path, value) }
        JSON.parse(File.read(path))["debug"]["max_message_mib"].as_i.should eq(64)
      end
    end
  end
end

describe Adamantine::DebugController do
  it "samples DAP limits once per explicit Start, not again for an active session" do
    with_dap_settings_workspace("adamantine-dap-sampling") do |root|
      configured_limit = 1
      sampled_limits = [] of Int32
      provider = -> do
        sampled_limits << configured_limit
        configured_limit
      end
      controller = Adamantine::DebugController.default(max_message_mib_provider: provider)
      profile = dap_settings_launch_profile(root)

      begin
        first_review = controller.prepare_launch(profile, root)
        first_review.valid?.should be_true
        controller.start(first_review).accepted?.should be_true
        first = await_dap_controller(controller) do |snapshot|
          snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
            snapshot.state.execution == Adamantine::DebugSessionState::Execution::Stopped
        end
        first.state.lifecycle.should eq(Adamantine::DebugSessionState::Lifecycle::Active)
        sampled_limits.should eq([1])

        configured_limit = 4
        3.times { controller.poll; sleep 5.milliseconds }
        sampled_limits.should eq([1])

        controller.stop.accepted?.should be_true
        await_dap_controller(controller) do |snapshot|
          snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended && !snapshot.cleanup_pending
        end

        second_review = controller.prepare_launch(profile, root)
        second_review.valid?.should be_true
        controller.start(second_review).accepted?.should be_true
        sampled_limits.should eq([1, 4])
        second = await_dap_controller(controller) do |snapshot|
          snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
            snapshot.state.execution == Adamantine::DebugSessionState::Execution::Stopped
        end
        second.state.lifecycle.should eq(Adamantine::DebugSessionState::Lifecycle::Active)
      ensure
        controller.close
      end
    end
  end
end
