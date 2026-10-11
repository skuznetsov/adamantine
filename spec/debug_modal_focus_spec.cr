require "spec"
require "file_utils"
require "json"
require "crystal_tui"

require "../src/adamantine/app"

private class DebugModalTestApp < Adamantine::App
  def open_debug_watch_modal_public : Nil
    open_debug_watch_form
  end

  def open_debug_profile_form_public : Nil
    open_debug_profile_form
  end

  def debug_modal_open_public? : Bool
    debug_modal_active?
  end

  def debug_watch_text_public : String
    @debug_form_fields.first?.try(&.value) || ""
  end

  def debug_profile_argv_public : Array(String)
    JSON.parse(@debug_form_fields.first?.try(&.value) || "[]").as_a.map(&.as_s)
  end

  def debug_profile_hint_public : String?
    @debug_profile_hint
  end

  def debug_snapshot_public : Adamantine::DebugController::Snapshot
    @debug_controller.snapshot
  end

  def editor_cursor_public : {Int32, Int32}?
    current_editor.try { |editor| {editor.cursor_line, editor.cursor_col} }
  end
end

private def with_debug_modal_workspace(&)
  root = Path.new(Dir.tempdir, "adamantine-debug-modal-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe "debug modal input ownership" do
  it "keeps Watch paste editable while consuming debugger bindings and a configured Pause key" do
    with_debug_modal_workspace do |root|
      keymap = root / "keymap.json"
      File.write(keymap, {"keymap" => {"debug.pause" => ["ctrl+alt+p"]}}.to_json)
      app = DebugModalTestApp.new(project_root: root, lsp_command: "", keymap_path: keymap.to_s)
      app.open_debug_watch_modal_public
      app.debug_modal_open_public?.should be_true
      before_cursor = app.editor_cursor_public
      before_snapshot = app.debug_snapshot_public

      [
        Tui::KeyEvent.new(Tui::Key::F5),
        Tui::KeyEvent.new(Tui::Key::F5, Tui::Modifiers::Shift),
        Tui::KeyEvent.new(Tui::Key::F9),
        Tui::KeyEvent.new(Tui::Key::F10),
        Tui::KeyEvent.new(Tui::Key::F11),
        Tui::KeyEvent.new(Tui::Key::F11, Tui::Modifiers::Shift),
      ].each do |event|
        app.on_capture(event).should be_true
        app.debug_modal_open_public?.should be_true
      end
      app.on_capture(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl | Tui::Modifiers::Alt)).should be_true

      app.on_capture(Tui::PasteEvent.new("watch draft")).should be_true
      app.debug_watch_text_public.should eq("watch draft")
      app.editor_cursor_public.should eq(before_cursor)
      app.debug_snapshot_public.state.should eq(before_snapshot.state)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.debug_modal_open_public?.should be_false
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "only prefills an existing canonical lldb-dap suggestion without executing it" do
    with_debug_modal_workspace do |root|
      setting = "ADAMANTINE_DEBUG_LLDB_DAP"
      previous = ENV[setting]?
      candidate = root / "lldb-dap"
      marker = root / "must-not-run"
      File.write(candidate, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod(candidate, 0o700)
      ENV[setting] = candidate.to_s

      app = DebugModalTestApp.new(project_root: root, lsp_command: "")
      app.open_debug_profile_form_public
      app.debug_profile_argv_public.should eq([File.realpath(candidate.to_s), "--no-lldbinit"])
      app.debug_profile_hint_public.not_nil!.should contain("review")
      File.exists?(marker).should be_false
    ensure
      if previous.nil?
        ENV.delete("ADAMANTINE_DEBUG_LLDB_DAP")
      else
        ENV["ADAMANTINE_DEBUG_LLDB_DAP"] = previous.not_nil!
      end
      app.try(&.quit(force: true))
    end
  end

  it "gives an actionable hint when no adapter executable can be resolved" do
    with_debug_modal_workspace do |root|
      setting = "ADAMANTINE_DEBUG_LLDB_DAP"
      previous = ENV[setting]?
      ENV[setting] = (root / "missing-lldb-dap").to_s
      app = DebugModalTestApp.new(project_root: root, lsp_command: "")
      app.open_debug_profile_form_public
      app.debug_profile_argv_public.should eq([] of String)
      app.debug_profile_hint_public.not_nil!.should contain("ADAMANTINE_DEBUG_LLDB_DAP")
    ensure
      if previous.nil?
        ENV.delete("ADAMANTINE_DEBUG_LLDB_DAP")
      else
        ENV["ADAMANTINE_DEBUG_LLDB_DAP"] = previous.not_nil!
      end
      app.try(&.quit(force: true))
    end
  end
end
