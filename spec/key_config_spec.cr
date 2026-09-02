require "spec"
require "file_utils"
require "json"

require "../src/adamantine/key_config"

def with_temp_workspace(prefix : String = "editor-keyconfig-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::KeyConfig do
  it "normalizes modifier order and spacing" do
    raw = " Shift + Ctrl + Enter "
    normalized = Adamantine::KeyConfig.normalize_binding(raw)
    raise "wrong normalization" unless normalized == "ctrl+shift+enter"
  end

  it "normalizes binding arrays with deduplication" do
    raw = ["Ctrl+S", "ctrl+s", "shift+ctrl+S", "  ", "alt+ 1", "ctrl", "ctrl+"]
    normalized = Adamantine::KeyConfig.normalize_bindings(raw)
    expected = ["ctrl+s", "ctrl+shift+s", "alt+1"]
    raise "unexpected normalized list" unless normalized == expected
  end

  it "finds action for normalized binding" do
    bindings = {
      "app.save"         => ["ctrl+s"],
      "app.jump_back"    => ["ctrl+["],
      "app.jump_forward" => ["ctrl+]"],
    }
    action = Adamantine::KeyConfig.find_action_for_binding(bindings, "CTRL+S")
    raise "expected app.save" unless action == "app.save"
    action = Adamantine::KeyConfig.find_action_for_binding(bindings, "ctrl+[")
    raise "expected app.jump_back" unless action == "app.jump_back"
    action = Adamantine::KeyConfig.find_action_for_binding(Adamantine::KeyConfig.defaults, "alt+[")
    raise "expected default alt+[ jump_back" unless action == "app.jump_back"
    action = Adamantine::KeyConfig.find_action_for_binding(Adamantine::KeyConfig.defaults, "ctrl+z")
    raise "expected default ctrl+z undo" unless action == "app.undo"
    action = Adamantine::KeyConfig.find_action_for_binding(Adamantine::KeyConfig.defaults, "ctrl+y")
    raise "expected default ctrl+y redo" unless action == "app.redo"
    action = Adamantine::KeyConfig.find_action_for_binding(Adamantine::KeyConfig.defaults, "ctrl+shift+z")
    raise "expected default ctrl+shift+z redo" unless action == "app.redo"
    action = Adamantine::KeyConfig.find_action_for_binding(Adamantine::KeyConfig.defaults, "ctrl+f")
    raise "expected default ctrl+f find" unless action == "app.find"
    action = Adamantine::KeyConfig.find_action_for_binding(Adamantine::KeyConfig.defaults, "alt+f")
    raise "expected default alt+f find_in_project" unless action == "app.find_in_project"
    action = Adamantine::KeyConfig.find_action_for_binding(Adamantine::KeyConfig.defaults, "option+f")
    raise "expected option+f to alias alt+f find_in_project" unless action == "app.find_in_project"
    action = Adamantine::KeyConfig.find_action_for_binding(Adamantine::KeyConfig.defaults, "ctrl+shift+f")
    raise "expected default ctrl+shift+f find_in_project" unless action == "app.find_in_project"
  end

  it "returns serialized payload with stable action order" do
    payload = Adamantine::KeyConfig.serializable_payload(Adamantine::KeyConfig.defaults)
    data = JSON.parse(payload)
    actions = data["keymap"]?.try(&.as_h?) || raise "keymap missing"

    expected_actions = actions.keys.sort
    raise "action order must be stable" unless actions.keys == expected_actions
  end

  it "keeps keymap.example.json in sync with the defaults" do
    example_path = Path.new(__DIR__).parent / "keymap.example.json"
    example = JSON.parse(File.read(example_path))["keymap"].as_h.keys.sort
    defaults = Adamantine::KeyConfig.defaults.keys.sort

    raise "keymap.example.json must match KeyConfig.defaults" unless example == defaults
  end

  it "loads existing keymap and falls back to defaults for missing path" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "missing.json")
      loaded = Adamantine::KeyConfig.load(path.to_s)
      defaults = Adamantine::KeyConfig.defaults
      raise "missing file should fallback to defaults" unless loaded == defaults
    end
  end

  it "loads custom keymap and keeps unknown actions" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "custom.json")
      File.write(path, %({
        "keymap": {
          "app.save": ["ctrl+z"],
          "plugin.special": ["ctrl+alt+x"]
        }
      }))

      loaded = Adamantine::KeyConfig.load(path.to_s)
      raise "custom action should be loaded" unless loaded["app.save"] == ["ctrl+z"]
      raise "unknown action should be preserved" unless loaded["plugin.special"] == ["ctrl+alt+x"]
      warnings = Adamantine::KeyConfig.duplicate_binding_warnings(loaded)
      unless warnings.any? { |warning| warning.includes?("ctrl+z") && warning.includes?("app.save") && warning.includes?("app.undo") }
        raise "ctrl+z collision with default undo should be reported, got #{warnings.inspect}"
      end
    end
  end

  it "uses the Adamantine config directory for new installations" do
    with_temp_workspace do |tmp_dir|
      previous_home = ENV["HOME"]?
      previous_config = ENV["ADAMANTINE_CONFIG"]?
      previous_legacy_config = ENV["CRYSTAL_EDITOR_CONFIG"]?

      begin
        ENV["HOME"] = tmp_dir.to_s
        ENV.delete("ADAMANTINE_CONFIG")
        ENV.delete("CRYSTAL_EDITOR_CONFIG")

        expected = Path.new(tmp_dir, ".config", "adamantine", "config.json").to_s
        raise "expected Adamantine config path" unless Adamantine::KeyConfig.default_save_path == expected
      ensure
        if previous_home
          ENV["HOME"] = previous_home
        else
          ENV.delete("HOME")
        end
        if previous_config
          ENV["ADAMANTINE_CONFIG"] = previous_config
        else
          ENV.delete("ADAMANTINE_CONFIG")
        end
        if previous_legacy_config
          ENV["CRYSTAL_EDITOR_CONFIG"] = previous_legacy_config
        else
          ENV.delete("CRYSTAL_EDITOR_CONFIG")
        end
      end
    end
  end

  it "loads a legacy Crystal Editor config when no Adamantine config exists" do
    with_temp_workspace do |tmp_dir|
      previous_home = ENV["HOME"]?
      previous_config = ENV["ADAMANTINE_CONFIG"]?
      previous_legacy_config = ENV["CRYSTAL_EDITOR_CONFIG"]?

      begin
        ENV["HOME"] = tmp_dir.to_s
        ENV.delete("ADAMANTINE_CONFIG")
        ENV.delete("CRYSTAL_EDITOR_CONFIG")
        legacy_path = Path.new(tmp_dir, ".config", "crystal_editor", "config.json")
        Dir.mkdir_p(legacy_path.parent)
        File.write(legacy_path, %({"keymap": {}}))

        raise "expected legacy config fallback" unless Adamantine::KeyConfig.resolve_default_path == legacy_path.to_s
      ensure
        if previous_home
          ENV["HOME"] = previous_home
        else
          ENV.delete("HOME")
        end
        if previous_config
          ENV["ADAMANTINE_CONFIG"] = previous_config
        else
          ENV.delete("ADAMANTINE_CONFIG")
        end
        if previous_legacy_config
          ENV["CRYSTAL_EDITOR_CONFIG"] = previous_legacy_config
        else
          ENV.delete("CRYSTAL_EDITOR_CONFIG")
        end
      end
    end
  end

  it "falls back to defaults for oversized keymap" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "big-keymap.json")
      payload = %({"keymap":{"app.save":["ctrl+z"]}})
      padding = " " * (Adamantine::KeyConfig::MAX_KEYMAP_FILE_BYTES + 1 - payload.bytesize)
      File.write(path, payload + padding)

      loaded = Adamantine::KeyConfig.load(path.to_s)
      raise "oversized keymap should fallback to defaults" unless loaded == Adamantine::KeyConfig.defaults
    end
  end
end
