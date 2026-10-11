require "spec"
require "file_utils"
require "json"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private class DebugFooterTestApp < Adamantine::App
  getter quit_attempts : Int32 = 0
  getter debug_steps : Array(Adamantine::DebugController::Action) = [] of Adamantine::DebugController::Action

  def layout_public : Nil
    mount_headless(100, 30)
    render(Tui::Buffer.new(100, 30), Tui::Rect.new(0, 0, 100, 30))
  end

  def footer_binding_public(key : Int32) : Tui::Footer::Binding?
    @footer.bindings.find { |binding| binding.key == key }
  end

  def click_footer_public(key : Int32) : Bool
    width_per_key = @footer.rect.width // 10
    x = @footer.rect.x + ((key - 1) * width_per_key) + (width_per_key // 2)
    handle_event(Tui::MouseEvent.new(x, @footer.rect.y))
  end

  def command_palette_open_public? : Bool
    @command_palette.open
  end

  def shutdown_public : Nil
    quit(force: true)
  end

  def quit(force : Bool = false) : Nil
    unless force
      @quit_attempts += 1
      return
    end
    super(force: true)
  end

  private def debug_step(action : Adamantine::DebugController::Action) : Bool
    @debug_steps << action
    true
  end
end

private def with_debug_footer_root(&)
  Tui::App.clear_overlays
  candidate = Path.new(Dir.tempdir, "adamantine-debug-footer-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(candidate.to_s)
  yield Path.new(File.realpath(candidate.to_s))
ensure
  FileUtils.rm_rf(candidate.to_s) if candidate
  Tui::App.clear_overlays
end

private def debug_footer_label(app : DebugFooterTestApp, key : Int32) : String
  app.footer_binding_public(key).try(&.label) || ""
end

private def debug_footer_default_config(root : Path) : Path
  config = root / "config.json"
  File.write(config, "{}")
  config
end

describe "Debugger footer authority" do
  it "labels default debugger function keys and clicks the same action as the key route" do
    with_debug_footer_root do |root|
      app = DebugFooterTestApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: debug_footer_default_config(root).to_s,
        session_enabled: false
      )
      app.layout_public

      debug_footer_label(app, 5).downcase.should contain("debug")
      debug_footer_label(app, 9).downcase.should contain("break")
      debug_footer_label(app, 10).should eq("Over")

      app.on_capture(Tui::KeyEvent.new(Tui::Key::F10)).should be_true
      app.debug_steps.should eq([Adamantine::DebugController::Action::StepOver])
      app.debug_steps.clear

      app.click_footer_public(10).should be_true
      app.debug_steps.should eq([Adamantine::DebugController::Action::StepOver])
      app.quit_attempts.should eq(0)
    ensure
      app.try(&.shutdown_public)
    end
  end

  it "shows an effective remap and leaves an explicitly unbound function slot unclaimed" do
    with_debug_footer_root do |root|
      config = root / "config.json"
      File.write(config, {"keymap" => {
        "debug.step_over"         => ["f9"],
        "debug.toggle_breakpoint" => [] of String,
      }}.to_json)

      app = DebugFooterTestApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: config.to_s,
        session_enabled: false
      )
      app.layout_public

      debug_footer_label(app, 9).should eq("Over")
      debug_footer_label(app, 10).should eq("")

      app.on_capture(Tui::KeyEvent.new(Tui::Key::F9)).should be_true
      app.debug_steps.should eq([Adamantine::DebugController::Action::StepOver])
      app.debug_steps.clear
      app.click_footer_public(9).should be_true
      app.debug_steps.should eq([Adamantine::DebugController::Action::StepOver])

      app.click_footer_public(10).should be_true
      app.quit_attempts.should eq(0)
    ensure
      app.try(&.shutdown_public)
    end
  end

  it "keeps footer clicks inside an active modal capture boundary" do
    with_debug_footer_root do |root|
      app = DebugFooterTestApp.new(
        project_root: root,
        lsp_command: "",
        keymap_path: debug_footer_default_config(root).to_s,
        session_enabled: false
      )
      app.layout_public
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1)).should be_true
      app.command_palette_open_public?.should be_true

      app.click_footer_public(10).should be_true
      app.command_palette_open_public?.should be_true
      app.quit_attempts.should eq(0)
      app.debug_steps.should be_empty
    ensure
      app.try(&.shutdown_public)
    end
  end
end
