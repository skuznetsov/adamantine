require "spec"
require "file_utils"
require "../src/adamantine/app"

private class QuickOpenAdversaryApp < Adamantine::App
  getter quick_worker_launches : Int32 = 0

  private def schedule_quick_open_worker : Nil
    already_active = @quick_open.worker_active
    super
    @quick_worker_launches += 1 if !already_active && @quick_open.worker_active
  end

  def open_public(path : Path)
    open_file(path)
  end

  def editor_public : Tui::TextEditor
    current_editor.not_nil!
  end

  def dispatch_public(event : Tui::Event)
    editor_public.on_event(event) unless on_capture(event)
  end

  def mode_public : String
    active_input_mode.to_s
  end

  def palette_open_public : Bool
    @command_palette.open
  end

  def buffer_count_public : Int32
    @document_session.open_buffers.size
  end

  def wait_quick_open_public
    deadline = Time.instant + 3.seconds
    while @quick_open.searching
      raise "quick-open timeout" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def query_public(text : String)
    text.each_char { |char| dispatch_public(Tui::KeyEvent.new(char)) }
    wait_quick_open_public
  end

  def path_public : Path
    current_buffer.not_nil!.path
  end

  def query_value_public : String
    @quick_open.query
  end

  def inject_partial_empty_public
    @quick_open.matches.clear
    @quick_open.partial = true
    @quick_open.searching = false
  end

  def status_public : String
    @quick_open.status
  end
end

private def with_quick_open_adversary(&)
  root = Path.new(Dir.tempdir, "adamantine-quick-open-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "original.cr"
  File.write(path, "keep me")
  app = QuickOpenAdversaryApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")
  app.open_public(path).should be_true
  app.editor_public.set_cursor(0, 7)
  yield app, root
ensure
  app.try &.quit(force: true)
  FileUtils.rm_rf(root) if root
end

describe "parent quick-open capture boundaries" do
  it "preserves partial-empty status when Enter finds no selectable row" do
    with_quick_open_adversary do |app, _root|
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.wait_quick_open_public
      app.inject_partial_empty_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.status_public.should contain("partial")
      app.mode_public.should eq("QuickOpen")
      app.editor_public.text.should eq("keep me")
    end
  end

  it "opens a dedicated mode through Ctrl+P and consumes query input" do
    with_quick_open_adversary do |app, _root|
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.mode_public.should eq("QuickOpen")
      app.dispatch_public(Tui::KeyEvent.new('x'))
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Backspace))
      app.dispatch_public(Tui::PasteEvent.new("unexpected"))
      app.editor_public.text.should eq("keep me")
      app.editor_public.undo.should be_false
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.mode_public.should eq("Normal")
    end
  end

  it "does not let the global command-palette shortcut escape the modal" do
    with_quick_open_adversary do |app, _root|
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift))
      app.mode_public.should eq("QuickOpen")
      app.palette_open_public.should be_false
      app.editor_public.text.should eq("keep me")
    end
  end

  it "reuses the existing unsaved editor without rereading its disk content" do
    with_quick_open_adversary do |app, _root|
      original_editor = app.editor_public
      original_editor.insert_text("!")
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.query_public("original.cr")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.mode_public.should eq("Normal")
      app.editor_public.same?(original_editor).should be_true
      app.editor_public.text.should eq("keep me!")
      app.buffer_count_public.should eq(1)
    end
  end

  it "rechecks a selected file that disappeared after indexing" do
    with_quick_open_adversary do |app, root|
      path = root / "vanishing.cr"
      File.write(path, "temporary")
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.query_public("vanishing.cr")
      File.delete(path)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.mode_public.should eq("QuickOpen")
      app.editor_public.text.should eq("keep me")
      app.buffer_count_public.should eq(1)
    end
  end

  it "indexes names without bypassing binary-file open rejection" do
    with_quick_open_adversary do |app, root|
      File.write(root / "binary.dat", "a\0b")
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.query_public("binary.dat")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.mode_public.should eq("QuickOpen")
      app.editor_public.text.should eq("keep me")
      app.buffer_count_public.should eq(1)
    end
  end

  it "publishes only the latest query after rapid changes" do
    with_quick_open_adversary do |app, root|
      File.write(root / "second.cr", "second")
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      "original".each_char { |char| app.dispatch_public(Tui::KeyEvent.new(char)) }
      8.times { app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Backspace)) }
      app.query_public("second.cr")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.path_public.should eq(root / "second.cr")
      app.editor_public.text.should eq("second")
    end
  end

  it "treats j, k and shift-only letters as query text rather than menu shortcuts" do
    with_quick_open_adversary do |app, _root|
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.dispatch_public(Tui::KeyEvent.new('j'))
      app.dispatch_public(Tui::KeyEvent.new('k'))
      app.dispatch_public(Tui::KeyEvent.new('A', Tui::Modifiers::Shift))
      app.query_value_public.should eq("jkA")
      app.editor_public.text.should eq("keep me")
    end
  end

  it "does not let a cancelled worker steal a reopened modal's pending query" do
    with_quick_open_adversary do |app, root|
      File.write(root / "second.cr", "second")
      12.times do
        app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
        app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      end
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.quick_worker_launches.should eq(1)
      app.query_public("second.cr")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.path_public.should eq(root / "second.cr")
      app.mode_public.should eq("Normal")
    end
  end
end
