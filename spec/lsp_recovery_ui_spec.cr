require "spec"
require "file_utils"
require "../src/adamantine/app"

private class RecoveryUiProbeApp < Adamantine::App
  getter restart_calls = 0

  def lsp_health_label : String
    "retrying 2/3"
  end

  def restart_lsp : Nil
    @restart_calls += 1
  end

  def header_text : String
    update_header
    @header.subtitle
  end

  def command(text : String) : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    text.each_char { |char| on_capture(Tui::KeyEvent.new(char)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end
end

describe "LSP recovery UI routing" do
  it "shows health even without an open document and routes explicit restart only" do
    root = Path.new(Dir.tempdir, "adamantine-recovery-ui-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    File.write(root / "config.json", "{}")
    app = RecoveryUiProbeApp.new(
      project_root: root, lsp_command: "", keymap_path: (root / "config.json").to_s,
      clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
      recovery_root: root / "recovery", session_enabled: false,
    )
    app.header_text.starts_with?("[LSP retrying 2/3]").should be_true
    app.command("lsp")
    app.restart_calls.should eq(0)
    app.command("lsp restart")
    app.restart_calls.should eq(1)
    app.command("lsp typo")
    app.restart_calls.should eq(1)
  ensure
    app.try(&.quit(force: true))
    FileUtils.rm_rf(root) if root
  end
end
