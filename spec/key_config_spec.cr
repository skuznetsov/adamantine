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
  it "offers F1 and the existing command shortcut without overriding a custom mapping" do
    Adamantine::KeyConfig.defaults["app.command_palette"].should eq(["f1", "ctrl+shift+p"])
    with_temp_workspace do |tmp_dir|
      path = tmp_dir / "custom.json"
      File.write(path, %({"keymap":{"app.command_palette":["ctrl+shift+o"]}}))
      Adamantine::KeyConfig.load(path.to_s)["app.command_palette"].should eq(["ctrl+shift+o"])
    end
  end

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
    payload = Adamantine::KeyConfig.serializable_overrides_payload({
      "plugin.zed"   => ["ctrl+z"],
      "plugin.alpha" => ["ctrl+a"],
    })
    data = JSON.parse(payload)
    actions = data["keymap"]?.try(&.as_h?) || raise "keymap missing"

    raise "action order must be stable" unless actions.keys == ["plugin.alpha", "plugin.zed"]
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

  it "loads explicit empty arrays as unbinds while inheriting omitted defaults" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "layers.json")
      File.write(path, {
        "keymap" => {
          "app.save"        => [] of String,
          "plugin.disabled" => [] of String,
        },
      }.to_json)

      layers = Adamantine::KeyConfig.load_layers(path.to_s)
      raise "explicit empty app.save must remain unbound" unless layers.effective["app.save"]? == [] of String
      raise "omitted app.undo must inherit its default" unless layers.effective["app.undo"]? == ["ctrl+z"]
      raise "empty unknown actions must be preserved" unless layers.effective["plugin.disabled"]? == [] of String
      raise "sparse overrides must retain explicit empties" unless layers.overrides == {
                                                                     "app.save"        => [] of String,
                                                                     "plugin.disabled" => [] of String,
                                                                   }
    end
  end

  it "warns for invalid empty or scalar values without unbinding defaults" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "invalid-overrides.json")
      File.write(path, {
        "keymap" => {
          "app.save" => "",
          "app.undo" => nil,
          "app.redo" => [" ", 42],
          "app.find" => ["ctrl+g"],
        },
      }.to_json)

      warnings = [] of String
      layers = Adamantine::KeyConfig.load_layers(path.to_s, ->(message : String) : Nil { warnings << message })
      raise "invalid values must produce warnings" if warnings.empty?
      raise "empty string must not unbind app.save" unless layers.effective["app.save"]? == ["ctrl+s"]
      raise "null must not unbind app.undo" unless layers.effective["app.undo"]? == ["ctrl+z"]
      raise "all-invalid arrays must not unbind app.redo" unless layers.effective["app.redo"]? == ["ctrl+shift+z", "ctrl+y"]
      raise "valid non-empty override must load" unless layers.effective["app.find"]? == ["ctrl+g"]
    end
  end

  it "saves only sparse deltas and round-trips unknown actions and explicit unbinds" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "sparse-save.json")
      File.write(path, {
        "plugin" => {"enabled" => true},
        "editor" => {"indent_width" => 4},
        "keymap" => {"app.quit" => ["alt+q"]},
      }.to_json)

      effective = Adamantine::KeyConfig.defaults
      effective["app.save"] = ["alt+s"]
      effective["app.undo"] = [] of String
      effective["plugin.special"] = ["ctrl+alt+x"]
      Adamantine::KeyConfig.save(path.to_s, effective)

      root = JSON.parse(File.read(path))
      keymap = root["keymap"].as_h
      raise "inherited defaults must not be serialized" if keymap.has_key?("app.find")
      raise "save override missing" unless keymap["app.save"].as_a.map(&.as_s) == ["alt+s"]
      raise "explicit unbind missing" unless keymap["app.undo"].as_a.empty?
      raise "unknown action missing" unless keymap["plugin.special"].as_a.map(&.as_s) == ["ctrl+alt+x"]
      raise "unrelated root section was changed" unless root["plugin"] == JSON.parse(%({"enabled":true}))
      raise "unrelated editor section was changed" unless root["editor"] == JSON.parse(%({"indent_width":4}))

      reloaded = Adamantine::KeyConfig.load_layers(path.to_s)
      raise "saved explicit unbind must reload" unless reloaded.effective["app.undo"]? == [] of String
      raise "saved unknown action must reload" unless reloaded.effective["plugin.special"]? == ["ctrl+alt+x"]
      raise "saved remap must reload" unless reloaded.effective["app.save"]? == ["alt+s"]
    end
  end

  it "save_overrides preserves exact provenance even when a value equals today's default" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "exact-overrides.json")
      exact = {
        "app.save"    => ["ctrl+s"],
        "app.undo"    => [] of String,
        "plugin.flag" => [] of String,
      }

      Adamantine::KeyConfig.save_overrides(path.to_s, exact)
      layers = Adamantine::KeyConfig.load_layers(path.to_s)
      raise "save_overrides must retain default-equal provenance" unless layers.overrides == exact
      raise "save_overrides must retain explicit app.undo unbind" unless layers.effective["app.undo"]? == [] of String
      raise "save_overrides must retain unknown empty action" unless layers.effective["plugin.flag"]? == [] of String
    end
  end

  it "lets omitted defaults evolve without changing sparse overrides" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "default-evolution.json")
      effective = Adamantine::KeyConfig.defaults
      effective["app.save"] = ["alt+s"]
      Adamantine::KeyConfig.save(path.to_s, effective)

      original_find = Adamantine::KeyConfig::DEFAULT_KEY_MAP["app.find"].dup
      begin
        Adamantine::KeyConfig::DEFAULT_KEY_MAP["app.find"] = ["alt+f"]
        layers = Adamantine::KeyConfig.load_layers(path.to_s)
        raise "sparse override must survive default evolution" unless layers.effective["app.save"]? == ["alt+s"]
        raise "omitted action must inherit the evolved default" unless layers.effective["app.find"]? == ["alt+f"]
      ensure
        Adamantine::KeyConfig::DEFAULT_KEY_MAP["app.find"] = original_find
      end
    end
  end

  it "reports every same-context owner without conflating modal contexts" do
    bindings = {
      "app.save"            => ["ctrl+x"],
      "app.undo"            => ["ctrl+x"],
      "app.redo"            => ["ctrl+x"],
      "app.menu_up"         => ["ctrl+x"],
      "app.menu_close"      => ["ctrl+q"],
      "app.quick_open_up"   => ["ctrl+x"],
      "app.quick_open_down" => ["ctrl+q"],
      "lsp.completion_up"   => ["ctrl+x"],
      "lsp.problems_up"     => ["ctrl+x"],
      "lsp.menu_definition" => ["ctrl+x"],
      "lsp.popup_close"     => ["ctrl+x"],
    }

    global = Adamantine::KeyConfig.actions_for_binding(bindings, "ctrl+x", Adamantine::KeyConfig::BindingContext::Global)
    raise "global context must include every global owner" unless global == ["app.redo", "app.save", "app.undo"]
    conflicts = Adamantine::KeyConfig.conflicting_actions(
      bindings,
      "app.save",
      "ctrl+x",
      Adamantine::KeyConfig::BindingContext::Global
    )
    raise "same-context conflicts must include every owner" unless conflicts == ["app.redo", "app.undo"]

    menu = Adamantine::KeyConfig.actions_for_binding(bindings, "ctrl+x", Adamantine::KeyConfig::BindingContext::Menu)
    quick_open = Adamantine::KeyConfig.actions_for_binding(bindings, "ctrl+x", Adamantine::KeyConfig::BindingContext::QuickOpen)
    raise "menu context owner missing" unless menu == ["app.menu_up"]
    raise "quick-open context owner missing" unless quick_open == ["app.quick_open_up"]
    raise "modal reuse must not be a global conflict" unless !global.includes?("app.menu_up") && !global.includes?("app.quick_open_up")
    shared_conflicts = Adamantine::KeyConfig.conflicting_actions(bindings, "app.menu_close", "ctrl+q")
    raise "shared menu action must conflict in every active context" unless shared_conflicts == ["app.quick_open_down"]

    action_conflicts = Adamantine::KeyConfig.conflicts_for_action(
      bindings,
      "app.save",
      Adamantine::KeyConfig::BindingContext::Global
    )
    raise "conflicts_for_action must retain the binding" unless action_conflicts == {"ctrl+x" => ["app.redo", "app.undo"]}

    warnings = Adamantine::KeyConfig.duplicate_binding_warnings(bindings)
    expected_warnings = [
      "Key ctrl+q is bound to app.menu_close, app.quick_open_down",
      "Key ctrl+x is bound to app.redo, app.save, app.undo",
    ]
    raise "duplicate warnings must follow actual overlapping contexts" unless warnings == expected_warnings

    default_warnings = Adamantine::KeyConfig.duplicate_binding_warnings(Adamantine::KeyConfig.defaults)
    raise "intentional cross-modal defaults must not warn: #{default_warnings.inspect}" unless default_warnings.empty?
  end
end
