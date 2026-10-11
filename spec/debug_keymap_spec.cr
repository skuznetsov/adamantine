require "spec"
require "file_utils"
require "json"

require "../src/adamantine/key_config"

private def with_debug_keymap_workspace(&)
  root = Path.new(Dir.tempdir, "adamantine-debug-keymap-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe "debug key profile" do
  it "uses VS Code debug owners without stealing F6 Hover or saving over Ctrl+S" do
    defaults = Adamantine::KeyConfig.defaults
    {
      "debug.start_continue"    => "f5",
      "debug.stop"              => "shift+f5",
      "debug.toggle_breakpoint" => "f9",
      "debug.step_over"         => "f10",
      "debug.step_into"         => "f11",
      "debug.step_out"          => "shift+f11",
      "lsp.hover"               => "f6",
      "app.save"                => "ctrl+s",
    }.each do |action, binding|
      defaults[action]?.should eq([binding])
      Adamantine::KeyConfig.actions_for_binding(defaults, binding).should eq([action])
    end

    # These actions remain available from F1 discovery, not colliding
    # function-key aliases.
    ["app.help", "app.settings", "app.reload_theme", "lsp.context_menu"].each do |action|
      defaults[action]?.should eq([] of String)
    end
  end

  it "preserves sparse user overrides and explicit empty unbinds" do
    with_debug_keymap_workspace do |root|
      path = root / "keymap.json"
      File.write(path, %({"keymap":{"app.help":["ctrl+alt+h"],"debug.step_over":[]}}))

      layers = Adamantine::KeyConfig.load_layers(path.to_s)
      layers.effective["app.help"].should eq(["ctrl+alt+h"])
      layers.effective["debug.start_continue"]?.should eq(["f5"])
      layers.effective["debug.step_over"]?.should eq([] of String)
      layers.overrides["app.help"].should eq(["ctrl+alt+h"])
      layers.overrides["debug.step_over"].should eq([] of String)
    end
  end
end
