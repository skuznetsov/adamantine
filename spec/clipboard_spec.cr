require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private class ClipboardSpecApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def editor_public : Tui::TextEditor
    current_editor || raise "expected active editor"
  end

  def editor_text_public : String
    editor_public.text
  end

  def input_closed_public? : Bool
    @input.events.closed?
  end

  def clipboard_value_public : String?
    @clipboard.value
  end

  def set_bindings_public(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def focus_tree_public : Nil
    @file_panel.focus
  end

  def open_command_palette_public : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def remember_clipboard_public(text : String) : Bool
    @clipboard.remember(text)
  end
end

private class RecordingClipboardBackend < Adamantine::Clipboard::Backend
  getter writes = [] of String
  getter reads = 0
  property read_result : Adamantine::Clipboard::Result = Adamantine::Clipboard::Result.unsupported
  property write_result : Adamantine::Clipboard::Result = Adamantine::Clipboard::Result.success

  def read : Adamantine::Clipboard::Result
    @reads += 1
    @read_result
  end

  def write(text : String) : Adamantine::Clipboard::Result
    @writes << text
    @write_result
  end
end

private class BlockingReadClipboardBackend < RecordingClipboardBackend
  getter started = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def read : Adamantine::Clipboard::Result
    @reads += 1
    @started.send(nil)
    @release.receive
    @read_result
  end
end

private def with_clipboard_workspace(&)
  root = Path.new(Dir.tempdir, "adamantine-clipboard-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe "Adamantine clipboard routing" do
  it "handles C0 Ctrl+C in the focused editor without quitting" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: RecordingClipboardBackend.new)
      app.open_file_public(path)
      app.editor_public.select_range(0, 0, 0, 5)

      handled = app.handle_event(Tui::KeyEvent.new('\u0003'))

      raise "Ctrl+C should be handled" unless handled
      raise "Ctrl+C must not quit the application" if app.input_closed_public?
    end
  end

  it "copies and cuts through the injected backend, then pastes through one undo step" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\nbeta\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)

      app.handle_event(Tui::KeyEvent.new('\u0003')).should be_true
      wait_until { backend.writes == ["alpha"] }
      app.clipboard_value_public.should eq "alpha"

      app.handle_event(Tui::KeyEvent.new('\u0018')).should be_true
      editor.text.should eq "\nbeta\n"
      app.handle_event(Tui::KeyEvent.new('\u0016')).should be_true
      wait_until { editor.text == "alpha\nbeta\n" }

      editor.undo.should be_true
      editor.text.should eq "\nbeta\n"
      editor.undo.should be_true
      editor.text.should eq "alpha\nbeta\n"
    end
  end

  it "retains the previous clipboard for no-selection and zero-width copies" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)
      app.handle_event(Tui::KeyEvent.new('\u0003'))
      wait_until { backend.writes == ["alpha"] }

      editor.set_cursor(0, 0)
      app.handle_event(Tui::KeyEvent.new('\u0003'))
      editor.select_range(0, 0, 0, 0)
      app.handle_event(Tui::KeyEvent.new('\u0003'))
      sleep 10.milliseconds

      app.clipboard_value_public.should eq "alpha"
      backend.writes.should eq ["alpha"]
    end
  end

  it "does not delete a selection when an external write fails" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      backend.write_result = Adamantine::Clipboard::Result.failed
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)

      app.handle_event(Tui::KeyEvent.new('\u0018')).should be_true
      wait_until { backend.writes == ["alpha"] }
      editor.text.should eq "\n"
      app.clipboard_value_public.should eq "alpha"
    end
  end

  it "prefers the internal value after a failed external write" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      backend.write_result = Adamantine::Clipboard::Result.failed
      backend.read_result = Adamantine::Clipboard::Result.success("stale desktop text")
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)

      app.handle_event(Tui::KeyEvent.new('\u0018'))
      wait_until { backend.writes == ["alpha"] }
      sleep 10.milliseconds
      app.handle_event(Tui::KeyEvent.new('\u0016'))
      sleep 10.milliseconds

      editor.text.should eq "alpha\n"
      backend.reads.should eq 0
    end
  end

  it "blocks widget hardcoded shortcuts after the app bindings are remapped" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      bindings = Adamantine::KeyConfig.defaults
      bindings["app.copy"] = ["ctrl+y"]
      bindings["app.cut"] = ["ctrl+b"]
      bindings["app.paste"] = ["ctrl+n"]
      app.set_bindings_public(bindings)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)

      app.handle_event(Tui::KeyEvent.new('\u0003')).should be_true
      app.handle_event(Tui::KeyEvent.new('\u0018')).should be_true
      sleep 10.milliseconds

      app.clipboard_value_public.should be_nil
      editor.text.should eq "alpha\n"
    end
  end

  it "rejects a delayed paste after the document changes" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "target\n")
      backend = BlockingReadClipboardBackend.new
      backend.read_result = Adamantine::Clipboard::Result.success("stale")
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      editor = app.editor_public
      app.handle_event(Tui::KeyEvent.new('\u0016')).should be_true
      backend.started.receive
      editor.paste("new")
      backend.release.send(nil)
      sleep 25.milliseconds

      editor.text.should eq "newtarget\n"
    end
  end

  it "routes explicit Ctrl modifiers through copy, cut, and paste" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)

      ctrl_c = Tui::KeyEvent.new('c', Tui::Modifiers::Ctrl)
      ctrl_x = Tui::KeyEvent.new('x', Tui::Modifiers::Ctrl)
      ctrl_v = Tui::KeyEvent.new('v', Tui::Modifiers::Ctrl)

      app.handle_event(ctrl_c).should be_true
      wait_until { backend.writes == ["alpha"] }
      app.handle_event(ctrl_x).should be_true
      wait_until { backend.writes == ["alpha", "alpha"] }
      editor.text.should eq "\n"
      app.handle_event(ctrl_v).should be_true
      wait_until { editor.text == "alpha\n" }
    end
  end

  it "carries a copied selection between editor tabs" do
    with_clipboard_workspace do |root|
      first = root / "first.txt"
      second = root / "second.txt"
      File.write(first, "alpha\n")
      File.write(second, "beta\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(first)
      first_editor = app.editor_public
      first_editor.select_range(0, 0, 0, 5)
      app.handle_event(Tui::KeyEvent.new('\u0003')).should be_true
      wait_until { backend.writes == ["alpha"] }

      app.open_file_public(second)
      second_editor = app.editor_public
      second_editor.set_cursor(0, 0)
      app.handle_event(Tui::KeyEvent.new('\u0016')).should be_true
      wait_until { second_editor.text == "alphabeta\n" }
      first_editor.text.should eq "alpha\n"
    end
  end

  it "does not copy when the project tree owns focus" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)
      app.focus_tree_public

      app.handle_event(Tui::KeyEvent.new('\u0003')).should be_true
      sleep 10.milliseconds
      app.clipboard_value_public.should be_nil
      backend.writes.should be_empty
      editor.text.should eq "alpha\n"
    end
  end

  it "executes remapped copy, cut, and paste bindings" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      bindings = Adamantine::KeyConfig.defaults
      bindings["app.copy"] = ["ctrl+shift+y"]
      bindings["app.cut"] = ["ctrl+shift+x"]
      bindings["app.paste"] = ["ctrl+shift+v"]
      app.set_bindings_public(bindings)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)
      modifiers = Tui::Modifiers::Ctrl | Tui::Modifiers::Shift

      app.handle_event(Tui::KeyEvent.new('y', modifiers)).should be_true
      wait_until { backend.writes == ["alpha"] }
      app.handle_event(Tui::KeyEvent.new('x', modifiers)).should be_true
      wait_until { backend.writes == ["alpha", "alpha"] }
      editor.text.should eq "\n"
      app.handle_event(Tui::KeyEvent.new('v', modifiers)).should be_true
      wait_until { editor.text == "alpha\n" }
    end
  end

  it "does not mutate the editor from remapped clipboard keys in a modal" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      bindings = Adamantine::KeyConfig.defaults
      bindings["app.copy"] = ["ctrl+shift+y"]
      bindings["app.cut"] = ["ctrl+shift+x"]
      bindings["app.paste"] = ["ctrl+shift+v"]
      app.set_bindings_public(bindings)
      editor = app.editor_public
      editor.select_range(0, 0, 0, 5)
      app.open_command_palette_public
      modifiers = Tui::Modifiers::Ctrl | Tui::Modifiers::Shift

      app.handle_event(Tui::KeyEvent.new('y', modifiers)).should be_true
      app.handle_event(Tui::KeyEvent.new('x', modifiers)).should be_true
      app.handle_event(Tui::KeyEvent.new('v', modifiers)).should be_true
      sleep 10.milliseconds
      app.clipboard_value_public.should be_nil
      backend.writes.should be_empty
      editor.text.should eq "alpha\n"
    end
  end

  it "keeps the previous value when copy service validation rejects input" do
    with_clipboard_workspace do |root|
      path = root / "sample.txt"
      File.write(path, "alpha\n")
      backend = RecordingClipboardBackend.new
      app = ClipboardSpecApp.new(project_root: root, lsp_command: "", clipboard_backend: backend)
      app.open_file_public(path)
      app.remember_clipboard_public("previous").should be_true
      invalid = String.new(Bytes[0xff_u8])
      oversized = "x" * (Adamantine::Clipboard::MAX_BYTES + 1)

      app.remember_clipboard_public(invalid).should be_false
      app.clipboard_value_public.should eq "previous"
      app.remember_clipboard_public(oversized).should be_false
      app.clipboard_value_public.should eq "previous"
    end
  end
end

private def wait_until(timeout : Time::Span = 1.second, &)
  deadline = Time.instant + timeout
  satisfied = yield
  until satisfied
    break if Time.instant >= deadline
    Fiber.yield
    sleep 1.millisecond
    satisfied = yield
  end
  raise "clipboard test timed out" unless satisfied
end
