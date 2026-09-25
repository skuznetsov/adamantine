require "spec"
require "file_utils"
require "../src/adamantine/app"

private class ClipboardTerminalApp < Adamantine::App
  getter quit_calls = 0

  def use_default_bindings : Nil
    @key_bindings = Adamantine::KeyConfig.defaults
  end

  def quit(force : Bool = false) : Nil
    @quit_calls += 1
  end

  def open_test_file(path : Path) : Nil
    raise "cannot open fixture" unless open_file(path)
  end

  def test_editor : Tui::TextEditor
    current_editor || raise "missing editor"
  end

  def show_test_palette : Nil
    open_command_palette
  end
end

private class EmptyTerminalClipboard < Adamantine::Clipboard::Backend
  getter reads = 0

  def read : Adamantine::Clipboard::Result
    @reads += 1
    Adamantine::Clipboard::Result.success("")
  end

  def write(text : String) : Adamantine::Clipboard::Result
    Adamantine::Clipboard::Result.success
  end
end

private class DelayedTerminalClipboard < EmptyTerminalClipboard
  getter started = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  getter completed = Channel(Nil).new(1)

  def read : Adamantine::Clipboard::Result
    @started.send(nil)
    @release.receive
    Adamantine::Clipboard::Result.success("late")
  ensure
    @completed.send(nil)
  end
end

private def with_terminal_clipboard_editor(backend : Adamantine::Clipboard::Backend = Adamantine::Clipboard::UnsupportedBackend.new, &)
  root = Path.new(Dir.tempdir, "adamantine-terminal-clipboard-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  file = root / "sample.txt"
  File.write(file, "original")
  app = ClipboardTerminalApp.new(root, lsp_command: "", clipboard_backend: backend)
  app.use_default_bindings
  app.open_test_file(file)
  yield app
ensure
  FileUtils.rm_rf(root) if root
end

describe "clipboard terminal input routing" do
  it "does not interpret terminal Ctrl+C as an implicit quit" do
    app = ClipboardTerminalApp.new(Path.new(__DIR__).parent, lsp_command: "", clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new)
    app.use_default_bindings
    parser = Tui::InputParser.new
    events = parser.feed("\u0003")
    events.size.should eq 1
    events.each { |event| app.handle_event(event) }
    app.quit_calls.should eq 0
  end

  it "retains the explicit terminal Ctrl+Q quit shortcut" do
    app = ClipboardTerminalApp.new(Path.new(__DIR__).parent, lsp_command: "", clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new)
    app.use_default_bindings
    parser = Tui::InputParser.new
    events = parser.feed("\u0011")
    events.size.should eq 1
    events.each { |event| app.handle_event(event) }
    app.quit_calls.should eq 1
  end

  it "pastes raw bracketed text as one undoable edit" do
    with_terminal_clipboard_editor do |app|
      app.test_editor.select_all
      events = Tui::InputParser.new.feed("\e[200~alpha\nbeta\e[201~")
      events.size.should eq 1
      events.each { |event| app.handle_event(event) }
      app.test_editor.text.should eq "alpha\nbeta"
      app.test_editor.undo.should be_true
      app.test_editor.text.should eq "original"
    end
  end

  it "round-trips a raw terminal cut and paste without a desktop clipboard" do
    with_terminal_clipboard_editor do |app|
      app.test_editor.select_all
      parser = Tui::InputParser.new
      parser.feed("\u0018").each { |event| app.handle_event(event) }
      app.test_editor.text.should eq ""
      parser.feed("\u0016").each { |event| app.handle_event(event) }
      deadline = Time.instant + 1.second
      while app.test_editor.text.empty? && Time.instant < deadline
        sleep 1.millisecond
      end
      app.test_editor.text.should eq "original"
      app.test_editor.undo.should be_true
      app.test_editor.text.should eq ""
      app.test_editor.undo.should be_true
      app.test_editor.text.should eq "original"
      app.quit_calls.should eq 0
    end
  end

  it "does not paste terminal text into the document behind the palette" do
    with_terminal_clipboard_editor do |app|
      app.test_editor.select_all
      app.show_test_palette
      Tui::InputParser.new.feed("\e[200~unexpected\e[201~").each do |event|
        app.handle_event(event)
      end
      app.test_editor.text.should eq "original"
    end
  end

  it "does not erase a selection when the desktop clipboard is empty" do
    backend = EmptyTerminalClipboard.new
    with_terminal_clipboard_editor(backend) do |app|
      app.test_editor.select_all
      Tui::InputParser.new.feed("\u0016").each { |event| app.handle_event(event) }
      deadline = Time.instant + 1.second
      while backend.reads == 0 && Time.instant < deadline
        sleep 1.millisecond
      end
      backend.reads.should eq 1
      Fiber.yield
      app.test_editor.text.should eq "original"
      app.test_editor.can_undo?.should be_false
    end
  end

  it "discards a delayed paste after the cursor moves away and returns" do
    backend = DelayedTerminalClipboard.new
    with_terminal_clipboard_editor(backend) do |app|
      parser = Tui::InputParser.new
      parser.feed("\u0016").each { |event| app.handle_event(event) }
      backend.started.receive
      parser.feed("\e[C\e[D").each { |event| app.handle_event(event) }
      app.test_editor.cursor_col.should eq 0
      backend.release.send(nil)
      backend.completed.receive
      Fiber.yield
      app.test_editor.text.should eq "original"
    end
  end

  it "applies a delayed paste when its target is still current" do
    backend = DelayedTerminalClipboard.new
    with_terminal_clipboard_editor(backend) do |app|
      Tui::InputParser.new.feed("\u0016").each { |event| app.handle_event(event) }
      backend.started.receive
      backend.release.send(nil)
      backend.completed.receive
      Fiber.yield
      app.test_editor.text.should eq "lateoriginal"
      app.test_editor.undo.should be_true
      app.test_editor.text.should eq "original"
    end
  end
end
