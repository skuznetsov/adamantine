require "spec"
require "file_utils"
require "json"

require "../src/adamantine/editing_settings"
require "../src/adamantine/settings_config"
require "../src/adamantine/settings_state"

private def with_editing_settings_workspace(prefix : String = "editor-editing-settings", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::EditingSettings do
  it "uses bounded defaults and validates indentation width" do
    defaults = Adamantine::EditingSettings.new
    raise "default indent width should be 2" unless defaults.indent_width == 2
    raise "auto-indent should default to enabled" unless defaults.auto_indent

    settings = Adamantine::EditingSettings.new(indent_width: 8, auto_indent: false)
    raise "custom indent width should be retained" unless settings.indent_width == 8
    raise "custom auto-indent should be retained" if settings.auto_indent

    [0, 9, -1].each do |width|
      expect_raises(ArgumentError) { Adamantine::EditingSettings.new(indent_width: width) }
    end
  end
end

describe Adamantine::SettingsConfig do
  it "loads editing fields independently and warns with paths and F10 guidance" do
    with_editing_settings_workspace do |tmp|
      path = (tmp / "config.json").to_s
      File.write(path, {
        "editor" => {
          "indent_width"         => 6,
          "auto_indent"          => "yes",
          "plugin.editor_option" => "keep-me",
        },
      }.to_json)
      warnings = [] of String

      settings = Adamantine::SettingsConfig.load_editing(path, ->(message : String) : Nil { warnings << message })
      raise "valid indent_width should load" unless settings.indent_width == 6
      raise "invalid auto_indent should use its own default" unless settings.auto_indent
      raise "invalid field should warn" unless warnings.any? { |warning| warning.includes?("editor.auto_indent") }
      raise "warning should identify the config path" unless warnings.any? { |warning| warning.includes?(path) }
      raise "warning should point to F10 settings" unless warnings.any? { |warning| warning.includes?("F10") }
    end
  end

  it "keeps a valid false auto-indent value when indent width is invalid" do
    with_editing_settings_workspace do |tmp|
      path = (tmp / "invalid-indent.json").to_s
      [
        %({"editor":{"indent_width":null,"auto_indent":false}}),
        %({"editor":{"indent_width":0,"auto_indent":false}}),
        %({"editor":{"indent_width":9,"auto_indent":false}}),
        %({"editor":{"indent_width":1.5,"auto_indent":false}}),
        %({"editor":{"indent_width":2147483648,"auto_indent":false}}),
      ].each do |payload|
        File.write(path, payload)
        warnings = [] of String
        settings = Adamantine::SettingsConfig.load_editing(path, ->(message : String) : Nil { warnings << message })
        raise "invalid indent_width should use its default" unless settings.indent_width == 2
        raise "valid false auto_indent must not be replaced by true" if settings.auto_indent
        raise "invalid indent_width should warn" unless warnings.any? { |warning| warning.includes?("editor.indent_width") }
      end
    end
  end

  it "round-trips false auto-indent" do
    with_editing_settings_workspace do |tmp|
      path = (tmp / "false-auto-indent.json").to_s
      settings = Adamantine::EditingSettings.new(indent_width: 4, auto_indent: false)
      Adamantine::SettingsConfig.save_editing(path, settings)
      loaded = Adamantine::SettingsConfig.load_editing(path)
      raise "saved false auto_indent should load as false" if loaded.auto_indent
      raise "saved indent_width should load" unless loaded.indent_width == 4
    end
  end

  it "uses safe defaults for malformed and oversized reads" do
    with_editing_settings_workspace do |tmp|
      malformed_path = (tmp / "malformed.json").to_s
      File.write(malformed_path, %({"editor":))
      malformed_warnings = [] of String
      malformed = Adamantine::SettingsConfig.load_editing(malformed_path, ->(message : String) : Nil { malformed_warnings << message })
      raise "malformed config should use the default indent width" unless malformed.indent_width == 2
      raise "malformed config should use the default auto-indent" unless malformed.auto_indent
      raise "malformed config should warn" unless malformed_warnings.any? { |warning| warning.includes?(malformed_path) }

      oversized_path = (tmp / "oversized.json").to_s
      File.write(oversized_path, %({"editor":{"indent_width":4,"padding":"#{"x" * Adamantine::SettingsConfig::MAX_CONFIG_FILE_BYTES}"}}))
      oversized_warnings = [] of String
      oversized = Adamantine::SettingsConfig.load_editing(oversized_path, ->(message : String) : Nil { oversized_warnings << message })
      raise "oversized config should use safe defaults" unless oversized == Adamantine::EditingSettings.new
      raise "oversized config should warn" unless oversized_warnings.any? { |warning| warning.includes?(oversized_path) }
    end
  end

  it "preserves unknown editor, keymap, lsp, and root fields when saving" do
    with_editing_settings_workspace do |tmp|
      path = (tmp / "config.json").to_s
      original = {
        "plugin" => {"enabled" => true},
        "editor" => {"plugin.editor_option" => "keep-me", "indent_width" => 3, "auto_indent" => false},
        "keymap" => {"app.save" => ["ctrl+x"]},
        "lsp"    => {"other" => "keep-this", "max_response_mib" => 4},
      }
      File.write(path, original.to_json)

      settings = Adamantine::EditingSettings.new(indent_width: 7, auto_indent: true)
      Adamantine::SettingsConfig.save_editing(path, settings)
      after_editing = JSON.parse(File.read(path))
      raise "root fields must survive editing save" unless after_editing["plugin"] == JSON.parse(%({"enabled":true}))
      raise "unknown editor fields must survive editing save" unless after_editing["editor"]["plugin.editor_option"].as_s == "keep-me"
      raise "keymap must survive editing save" unless after_editing["keymap"]["app.save"].as_a.map(&.as_s) == ["ctrl+x"]
      raise "lsp fields must survive editing save" unless after_editing["lsp"]["other"].as_s == "keep-this"
      raise "indent_width should be saved" unless after_editing["editor"]["indent_width"].as_i == 7
      raise "auto_indent should be saved" unless after_editing["editor"]["auto_indent"].as_bool

      Adamantine::SettingsConfig.save(path, 16)
      after_lsp = JSON.parse(File.read(path))
      raise "editing fields must survive LSP save" unless after_lsp["editor"]["indent_width"].as_i == 7
      raise "unknown editor fields must survive LSP save" unless after_lsp["editor"]["plugin.editor_option"].as_s == "keep-me"
    end
  end

  it "preserves semantically malformed unrelated sections when saving editing settings" do
    with_editing_settings_workspace do |tmp|
      path = (tmp / "legacy-sections.json").to_s
      File.write(path, {
        "otherroot" => ["keep", {"raw" => true}],
        "editor"    => {"plugin.editor_option" => "keep-me"},
        "keymap"    => "legacy-keymap-shape",
        "lsp"       => ["legacy-lsp-shape"],
      }.to_json)

      Adamantine::SettingsConfig.save_editing(path, Adamantine::EditingSettings.new(indent_width: 5, auto_indent: false))
      saved = JSON.parse(File.read(path))
      raise "other root fields must survive" unless saved["otherroot"] == JSON.parse(%(["keep",{"raw":true}]))
      raise "unknown editor fields must survive" unless saved["editor"]["plugin.editor_option"].as_s == "keep-me"
      raise "malformed keymap section must survive" unless saved["keymap"].as_s == "legacy-keymap-shape"
      raise "malformed lsp section must survive" unless saved["lsp"] == JSON.parse(%(["legacy-lsp-shape"]))
    end
  end

  it "does not overwrite malformed or oversized files on save" do
    with_editing_settings_workspace do |tmp|
      malformed_path = (tmp / "malformed.json").to_s
      malformed_contents = %({"editor":)
      File.write(malformed_path, malformed_contents)
      expect_raises(Exception) do
        Adamantine::SettingsConfig.save_editing(malformed_path, Adamantine::EditingSettings.new(indent_width: 4))
      end
      raise "malformed config must remain untouched" unless File.read(malformed_path) == malformed_contents

      malformed_editor_path = (tmp / "malformed-editor.json").to_s
      malformed_editor_contents = %({"editor":"not-an-object","keymap":{"app.save":["ctrl+x"]}})
      File.write(malformed_editor_path, malformed_editor_contents)
      expect_raises(Exception) do
        Adamantine::SettingsConfig.save_editing(malformed_editor_path, Adamantine::EditingSettings.new(indent_width: 4))
      end
      raise "non-object editor config must remain untouched" unless File.read(malformed_editor_path) == malformed_editor_contents

      oversized_path = (tmp / "oversized.json").to_s
      oversized_contents = %({"plugin":"#{"x" * Adamantine::SettingsConfig::MAX_CONFIG_FILE_BYTES}"})
      File.write(oversized_path, oversized_contents)
      expect_raises(Exception) do
        Adamantine::SettingsConfig.save_editing(oversized_path, Adamantine::EditingSettings.new(indent_width: 4))
      end
      raise "oversized config must remain untouched" unless File.read(oversized_path) == oversized_contents
    end
  end
end

describe Adamantine::SettingsState do
  it "starts with editing settings defaults" do
    state = Adamantine::SettingsState.new
    raise "settings state indent width should default to 2" unless state.indent_width == 2
    raise "settings state auto-indent should default to enabled" unless state.auto_indent
  end
end
