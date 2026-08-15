require "spec"
require "file_utils"
require "json"

require "../src/editor/key_config"

def with_temp_workspace(prefix : String = "editor-keyconfig-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::KeyConfig do
  it "normalizes modifier order and spacing" do
    raw = " Shift + Ctrl + Enter "
    normalized = CrystalEditor::KeyConfig.normalize_binding(raw)
    raise "wrong normalization" unless normalized == "ctrl+shift+enter"
  end

  it "normalizes binding arrays with deduplication" do
    raw = ["Ctrl+S", "ctrl+s", "shift+ctrl+S", "  ", "alt+ 1", "ctrl", "ctrl+"]
    normalized = CrystalEditor::KeyConfig.normalize_bindings(raw)
    expected = ["ctrl+s", "ctrl+shift+s", "alt+1"]
    raise "unexpected normalized list" unless normalized == expected
  end

  it "finds action for normalized binding" do
    bindings = {
      "app.save"         => ["ctrl+s"],
      "app.jump_back"    => ["ctrl+["],
      "app.jump_forward" => ["ctrl+]"],
    }
    action = CrystalEditor::KeyConfig.find_action_for_binding(bindings, "CTRL+S")
    raise "expected app.save" unless action == "app.save"
    action = CrystalEditor::KeyConfig.find_action_for_binding(bindings, "ctrl+[")
    raise "expected app.jump_back" unless action == "app.jump_back"
    action = CrystalEditor::KeyConfig.find_action_for_binding(CrystalEditor::KeyConfig.defaults, "alt+[")
    raise "expected default alt+[ jump_back" unless action == "app.jump_back"
  end

  it "returns serialized payload with stable action order" do
    payload = CrystalEditor::KeyConfig.serializable_payload(CrystalEditor::KeyConfig.defaults)
    data = JSON.parse(payload)
    actions = data["keymap"]?.try(&.as_h?) || raise "keymap missing"

    expected_actions = actions.keys.sort
    raise "action order must be stable" unless actions.keys == expected_actions
  end

  it "loads existing keymap and falls back to defaults for missing path" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "missing.json")
      loaded = CrystalEditor::KeyConfig.load(path.to_s)
      defaults = CrystalEditor::KeyConfig.defaults
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

      loaded = CrystalEditor::KeyConfig.load(path.to_s)
      raise "custom action should be loaded" unless loaded["app.save"] == ["ctrl+z"]
      raise "unknown action should be preserved" unless loaded["plugin.special"] == ["ctrl+alt+x"]
    end
  end

  it "falls back to defaults for oversized keymap" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "big-keymap.json")
      payload = %({"keymap":{"app.save":["ctrl+z"]}})
      padding = " " * (CrystalEditor::KeyConfig::MAX_KEYMAP_FILE_BYTES + 1 - payload.bytesize)
      File.write(path, payload + padding)

      loaded = CrystalEditor::KeyConfig.load(path.to_s)
      raise "oversized keymap should fallback to defaults" unless loaded == CrystalEditor::KeyConfig.defaults
    end
  end
end
