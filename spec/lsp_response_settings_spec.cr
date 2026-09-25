require "spec"
require "file_utils"
require "json"
require "crystal_tui"

require "../src/adamantine/app"

private def with_lsp_response_settings_workspace(prefix : String = "editor-lsp-response-settings", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private class LspResponseSettingsTestApp < Adamantine::App
  def open_settings_public : Nil
    open_settings_dialog
  end

  def select_response_limit_public : Nil
    index = @settings.actions.index("setting:lsp.max_response_mib")
    raise "LSP response limit row is missing" unless index
    set_settings_selection(index)
  end

  def activate_selected_setting_public : Bool
    execute_selected_settings_action
  end

  def settings_actions_public : Array(String)
    @settings.actions
  end

  def settings_display_name_public(action : String) : String
    settings_display_name(action)
  end

  def settings_display_value_public(action : String) : String
    settings_display_value(action)
  end

  def max_response_mib_public : Int32
    @settings.max_response_mib
  end

  def set_max_response_mib_public(value : Int32) : Nil
    @settings.max_response_mib = value
  end

  def set_lsp_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def configure_lsp_callbacks_public(client : Adamantine::Lsp::Client) : Nil
    configure_lsp_callbacks(client)
  end

  def warnings_public : Array(String)
    @status_log.entries.select { |entry| entry.level == Tui::Log::Level::Warning }.map(&.message)
  end
end

describe Adamantine::SettingsConfig do
  it "uses a 16 MiB default and accepts only integer values from 1 through 64" do
    with_lsp_response_settings_workspace do |tmp|
      path = (tmp / "config.json").to_s
      warnings = [] of String
      callback = ->(message : String) : Nil { warnings << message }

      raise "missing setting should default to 16" unless Adamantine::SettingsConfig.load(path, callback) == 16
      File.write(path, %({"keymap":{}}))
      raise "legacy config should use the default" unless Adamantine::SettingsConfig.load(path, callback) == 16
      raise "missing settings must not warn" unless warnings.empty?

      [1, 64].each do |value|
        File.write(path, {"lsp" => {"max_response_mib" => value}}.to_json)
        raise "#{value} MiB should be accepted" unless Adamantine::SettingsConfig.load(path, callback) == value
      end
    end
  end

  it "warns with the config path and F10 guidance before falling back for invalid values" do
    with_lsp_response_settings_workspace do |tmp|
      path = (tmp / "invalid-config.json").to_s
      [0, 65, "16", 16.5].each do |value|
        File.write(path, {"lsp" => {"max_response_mib" => value}}.to_json)
        warnings = [] of String
        value_read = Adamantine::SettingsConfig.load(path, ->(message : String) : Nil { warnings << message })

        raise "invalid #{value.inspect} should use the safe default" unless value_read == 16
        raise "invalid #{value.inspect} should identify the config path" unless warnings.any? { |warning| warning.includes?(path) }
        raise "warning should identify response size" unless warnings.any? { |warning| warning.includes?("response size") }
        raise "warning should point to F10 settings" unless warnings.any? { |warning| warning.includes?("F10") }
        raise "warning must not describe source-file size" if warnings.any? { |warning| warning.includes?("source file") }
      end
    end
  end

  it "preserves unrelated config fields when saving settings and keybindings" do
    with_lsp_response_settings_workspace do |tmp|
      path = (tmp / "config.json").to_s
      File.write(path, {
        "plugin" => {"enabled" => true, "name" => "keep-me"},
        "keymap" => {"app.save" => ["ctrl+x"]},
        "lsp"    => {"other" => "keep-this", "max_response_mib" => 4},
      }.to_json)

      Adamantine::SettingsConfig.save(path, 8)
      raise "saved config must stay private" unless File.info(path).permissions.value & 0o077 == 0
      raise "new config should be private by default" unless (File.info(path).permissions.value & 0o777) == 0o600
      after_settings = JSON.parse(File.read(path))
      raise "settings save must preserve plugin fields" unless after_settings["plugin"] == JSON.parse(%({"enabled":true,"name":"keep-me"}))
      raise "settings save must preserve keymap" unless after_settings["keymap"]["app.save"].as_a.map(&.as_s) == ["ctrl+x"]
      raise "settings save must preserve unrelated lsp fields" unless after_settings["lsp"]["other"].as_s == "keep-this"
      raise "settings save must update max_response_mib" unless after_settings["lsp"]["max_response_mib"].as_i == 8

      bindings = Adamantine::KeyConfig.defaults
      bindings["app.save"] = ["ctrl+shift+s"]
      Adamantine::KeyConfig.save(path, bindings)
      after_keymap = JSON.parse(File.read(path))
      raise "keymap save must preserve plugin fields" unless after_keymap["plugin"] == after_settings["plugin"]
      raise "keymap save must preserve lsp settings" unless after_keymap["lsp"]["max_response_mib"].as_i == 8
      raise "keymap save must update key bindings" unless after_keymap["keymap"]["app.save"].as_a.map(&.as_s) == ["ctrl+shift+s"]
    end
  end

  it "refuses malformed or oversized config updates without overwriting the file" do
    with_lsp_response_settings_workspace do |tmp|
      path = (tmp / "malformed.json").to_s
      malformed = "{\"lsp\":"
      File.write(path, malformed)
      expect_raises(Exception) { Adamantine::SettingsConfig.save(path, 8) }
      raise "malformed config must remain untouched" unless File.read(path) == malformed

      oversized_path = (tmp / "oversized.json").to_s
      oversized = "{\"plugin\":\"#{"x" * Adamantine::SettingsConfig::MAX_CONFIG_FILE_BYTES}\"}"
      File.write(oversized_path, oversized)
      expect_raises(Exception) { Adamantine::SettingsConfig.save(oversized_path, 8) }
      raise "oversized config must remain untouched" unless File.read(oversized_path) == oversized
    end
  end
end

describe Adamantine::Lsp::Client do
  it "exposes a validated byte response cap with a 16 MiB default" do
    client = Adamantine::Lsp::Client.new("", Path.new(Dir.current))
    raise "default response cap should be 16 MiB" unless client.max_response_bytes == 16 * 1024 * 1024

    client.max_response_bytes = 1 * 1024 * 1024
    raise "response cap setter should use bytes" unless client.max_response_bytes == 1 * 1024 * 1024
    client.max_response_bytes = 64 * 1024 * 1024
    raise "maximum response cap should be 64 MiB" unless client.max_response_bytes == 64 * 1024 * 1024

    expect_raises(ArgumentError) { client.max_response_bytes = 0 }
    expect_raises(ArgumentError) { client.max_response_bytes = 65 * 1024 * 1024 }
    raise "invalid response cap must not replace the last valid value" unless client.max_response_bytes == 64 * 1024 * 1024
  end
end

describe Adamantine::App do
  it "shows and cycles the persisted LSP response limit in F10 settings" do
    with_lsp_response_settings_workspace do |tmp|
      path = (tmp / "config.json").to_s
      File.write(path, {"lsp" => {"max_response_mib" => 16}}.to_json)
      app = LspResponseSettingsTestApp.new(project_root: tmp, lsp_command: "", keymap_path: path)
      app.open_settings_public

      action = "setting:lsp.max_response_mib"
      raise "F10 settings should include the LSP response row" unless app.settings_actions_public.includes?(action)
      raise "row label should identify response limit" unless app.settings_display_name_public(action) == "LSP response limit"
      raise "row should show the current MiB value" unless app.settings_display_value_public(action) == "16 MiB"

      app.select_response_limit_public
      raise "response limit row should be actionable" unless app.activate_selected_setting_public
      raise "Enter should cycle to the next explicit preset" unless app.max_response_mib_public == 32
      raise "response limit change should persist" unless JSON.parse(File.read(path))["lsp"]["max_response_mib"].as_i == 32

      app.set_max_response_mib_public(24)
      app.select_response_limit_public
      app.activate_selected_setting_public
      raise "custom response limit should advance to the next larger preset" unless app.max_response_mib_public == 32
    end
  end

  it "applies a changed response limit to the active client and drops stale warnings" do
    with_lsp_response_settings_workspace do |tmp|
      path = (tmp / "config.json").to_s
      app = LspResponseSettingsTestApp.new(project_root: tmp, lsp_command: "", keymap_path: path)
      client = Adamantine::Lsp::Client.new("", tmp)
      app.set_lsp_client_public(client)
      app.configure_lsp_callbacks_public(client)
      app.open_settings_public
      app.select_response_limit_public
      app.activate_selected_setting_public

      raise "settings should apply immediately to the active client" unless client.max_response_bytes == 32 * 1024 * 1024

      warning_callback = client.on_warning || raise "client warning callback should be wired"
      warning_callback.call("LSP response size 40 MiB exceeds 32 MiB")
      raise "current client warning should reach status" unless app.warnings_public.any? { |message| message.includes?("40 MiB") }

      replacement = Adamantine::Lsp::Client.new("", tmp)
      app.set_lsp_client_public(replacement)
      warning_callback.call("stale LSP response warning")
      raise "stale client warning must not reach status" if app.warnings_public.any? { |message| message.includes?("stale LSP") }
    end
  end
end
