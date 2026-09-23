require "spec"
require "file_utils"
require "../src/adamantine/app"

private class RecoveryUiProbeApp < Adamantine::App
  getter restart_calls = 0

  def set_lsp_state(
    phase : String,
    reason : String? = nil,
    configured : Bool = true,
    configured_command : String? = nil,
  ) : Nil
    state = lsp_recovery_state
    state.mutex.synchronize do
      state.command = configured ? (configured_command || "test-lsp") : nil
      state.phase = phase
      state.retry_count = 2 if phase == "retrying"
      state.failure_reason = reason
    end
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

  def status_messages : Array(String)
    @status_log.entries.map(&.message)
  end

  def show_status : Nil
    show_lsp_status
  end

  def restart_entry : Adamantine::CommandEntry?
    command_palette_entries.find { |entry| entry.title == "Restart LSP" }
  end

  def restart_disabled_reason : String?
    entry = restart_entry
    entry ? command_disabled_reason(entry) : nil
  end

  def invoke_restart_from_f1 : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::F1))
    "restart".each_char { |char| on_capture(Tui::KeyEvent.new(char)) }
    index = @command_palette.candidates.index { |entry| entry.title == "Restart LSP" }
    raise "F1 did not discover Restart LSP" unless index

    index.not_nil!.times { on_capture(Tui::KeyEvent.new(Tui::Key::Down)) }
    selected = @command_palette.candidates[@command_palette.selected_index]?
    raise "F1 search did not select Restart LSP" unless selected.try(&.title) == "Restart LSP"
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
    app.set_lsp_state("retrying")
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

  it "shows an initial launch failure with a recovery path" do
    root = Path.new(Dir.tempdir, "adamantine-lsp-launch-ui-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    File.write(root / "config.json", "{}")
    app = RecoveryUiProbeApp.new(
      project_root: root, lsp_command: (root / "missing-language-server").to_s,
      keymap_path: (root / "config.json").to_s,
      clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
      recovery_root: root / "recovery", session_enabled: false,
    )
    app.header_text.should contain("[LSP failed]")
    app.show_status
    app.status_messages.last.should contain("Restart LSP")
    app.status_messages.last.should contain("missing-language-server")
  ensure
    app.try(&.quit(force: true))
    FileUtils.rm_rf(root) if root
  end

  it "makes a failed LSP actionable through status and F1 discovery" do
    root = Path.new(Dir.tempdir, "adamantine-lsp-error-ui-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    File.write(root / "config.json", "{}")
    app = RecoveryUiProbeApp.new(
      project_root: root, lsp_command: "", keymap_path: (root / "config.json").to_s,
      clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
      recovery_root: root / "recovery", session_enabled: false,
    )
    app.set_lsp_state("failed", "server closed the pipe")
    app.show_status
    app.status_messages.last.should contain("server closed the pipe")
    app.status_messages.last.should contain("F1")
    app.status_messages.last.should contain("Restart LSP")
    app.restart_entry.should_not be_nil
    app.restart_disabled_reason.should be_nil
    app.invoke_restart_from_f1
    app.restart_calls.should eq(1)
  ensure
    app.try(&.quit(force: true))
    FileUtils.rm_rf(root) if root
  end

  it "distinguishes disabled setup from retrying and keeps untrusted reasons on one bounded line" do
    root = Path.new(Dir.tempdir, "adamantine-lsp-error-ui-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    File.write(root / "config.json", "{}")
    app = RecoveryUiProbeApp.new(
      project_root: root, lsp_command: "", keymap_path: (root / "config.json").to_s,
      clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
      recovery_root: root / "recovery", session_enabled: false,
    )
    app.show_status
    app.status_messages.last.should contain("--lsp")
    app.restart_disabled_reason.should_not be_nil
    app.invoke_restart_from_f1
    app.restart_calls.should eq(0)
    app.status_messages.last.should contain("No configured LSP server")

    app.set_lsp_state("retrying", "old failure")
    app.show_status
    app.status_messages.last.should contain("retrying 2/3")
    app.status_messages.last.should_not contain("old failure")

    app.set_lsp_state("failed", "broken\r\n\e[31m" + "x" * 400)
    app.show_status
    message = app.status_messages.last
    message.should contain("broken")
    message.should_not contain("\n")
    message.should_not contain("\e")
    message.size.should be < 300

    app.set_lsp_state("failed", "x" * 1_000_000 + " trailing-sensitive-credential")
    app.show_status
    message = app.status_messages.last
    message.should contain("LSP transport failed")
    message.should_not contain("trailing-sensitive-credential")
    message.size.should be < 300

    command_token = "embedded-command-token-canary"
    configured_command = "missing-language-server --token #{command_token}"
    app.set_lsp_state(
      "failed",
      "missing-language-server --token #{command_token}: startup failed (File::NotFoundError)",
      configured_command: configured_command,
    )
    app.show_status
    message = app.status_messages.last
    message.should_not contain(command_token)
    message.should_not contain(configured_command)
  ensure
    app.try(&.quit(force: true))
    FileUtils.rm_rf(root) if root
  end
end
