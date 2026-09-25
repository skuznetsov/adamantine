require "spec"
require "file_utils"
require "../src/adamantine/app"

private class CloseAdversaryApp < Adamantine::App
  property probe_shutdown : Bool = false
  getter monitor_running_at_snapshot : Bool? = nil

  def start_shutdown_probe : Nil
    @probe_shutdown = true
    @session_lifecycle_active = true
    @document_orchestrator.start_external_file_monitor
  end

  private def save_session_state(root : Path? = nil) : Bool
    if @probe_shutdown
      @monitor_running_at_snapshot = @document_orchestrator.stop_external_file_monitor
    end
    super
  end

  def open_public(path : Path) : Adamantine::OpenBuffer
    raise "fixture open failed" unless open_file(path)
    current_buffer.not_nil!
  end

  def close_public(path : Path) : Bool
    @editor_tabs.close_tab(path.to_s)
  end

  def paths_public : Array(String)
    @editor_tabs.tabs.map(&.id)
  end

  def replace_editor_public(path : Path, target : Adamantine::OpenBuffer) : Adamantine::EditingTextEditor
    index = @editor_tabs.tabs.index { |tab| tab.id == path.to_s }.not_nil!
    tab = @editor_tabs.tabs[index]
    old_view = tab.content.as(Tui::TextEditor)
    replacement = Adamantine::EditingTextEditor.new(path.to_s, old_view.document)
    replacement.set_cursor(old_view.cursor_line, old_view.cursor_col)
    @editor_tabs.remove_child(old_view)
    @editor_tabs.tabs[index] = Tui::TabbedPanel::Tab.new(tab.id, tab.label, tab.tooltip, replacement, tab.closable)
    @editor_tabs.add_child(replacement)
    target.editor = replacement
    old_view.detach
    @editor_tabs.mark_dirty!
    replacement
  end

  def close_confirmation_active_public : Bool
    close_confirmation_active?
  end

  def exited_public? : Bool
    @input.events.closed?
  end

  def render_public(screen : Tui::Buffer, clip : Tui::Rect) : Nil
    render_close_confirmation(screen, clip)
  end
end

private class CloseBlockingClipboard < Adamantine::Clipboard::Backend
  getter started = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  getter finished = Channel(Nil).new(1)

  def read : Adamantine::Clipboard::Result
    @started.send(nil)
    @release.receive
    @finished.send(nil)
    Adamantine::Clipboard::Result.success("late-paste")
  end

  def write(text : String) : Adamantine::Clipboard::Result
    Adamantine::Clipboard::Result.success
  end
end

private def with_close_adversary(backend = Adamantine::Clipboard::UnsupportedBackend.new, &)
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-close-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "config.json"
  File.write(config, "{}")
  app = CloseAdversaryApp.new(root, lsp_command: "", keymap_path: config.to_s,
    clipboard_backend: backend, session_enabled: false, recovery_root: root / "recovery")
  yield root, app
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

private def choose_close_discard(app : CloseAdversaryApp) : Nil
  app.on_capture(Tui::KeyEvent.new(Tui::Key::Left))
  app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
end

describe "Close confirmation adversaries" do
  it "stops monitor publication before successful quit can yield in session persistence" do
    with_close_adversary do |root, app|
      path = root / "shutdown.cr"
      File.write(path, "base")
      app.open_public(path).editor.insert_text("dirty-")
      app.start_shutdown_probe
      app.quit
      choose_close_discard(app)
      app.exited_public?.should be_true
      app.monitor_running_at_snapshot.should eq false
      File.read(path).should eq "base"
    end
  end

  it "reviews buffers created during quit instead of implicitly discarding them" do
    with_close_adversary do |root, app|
      first = root / "first.cr"
      added = root / "added.cr"
      File.write(first, "first")
      File.write(added, "added")
      app.open_public(first).editor.insert_text("dirty-")
      app.quit
      app.open_public(added).editor.insert_text("new-")
      choose_close_discard(app)
      app.exited_public?.should be_false
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      app.paths_public.should eq [first.to_s, added.to_s]
      File.read(added).should eq "added"
    end
  end

  it "keeps controls legible on a compact terminal and respects partial repaint clips" do
    with_close_adversary do |root, app|
      path = root / "safe\u202E\e.cr"
      File.write(path, "base")
      app.open_public(path).editor.insert_text("dirty-")
      app.close_public(path)
      app.rect = Tui::Rect.new(0, 0, 32, 6)
      full = Tui::Buffer.new(32, 6)
      app.render_public(full, app.rect)
      row = String.build { |io| 32.times { |x| io << full.get(x, 0).glyph } }
      row.should contain "[Cancel]"
      rendered = String.build { |io| 6.times { |y| 32.times { |x| io << full.get(x, y).glyph } } }
      rendered.should_not contain '\u202E'
      rendered.should_not contain '\e'
      partial = Tui::Buffer.new(32, 6)
      clip = Tui::Rect.new(5, 1, 12, 3)
      app.render_public(partial, clip)
      6.times do |y|
        32.times do |x|
          if clip.contains?(x, y)
            partial.get(x, y).should eq full.get(x, y)
          else
            partial.get(x, y).glyph.should eq " "
          end
        end
      end
    end
  end

  it "does not reuse a discard decision after a previously reviewed buffer changes" do
    with_close_adversary do |root, app|
      a = root / "a.cr"
      b = root / "b.cr"
      File.write(a, "a")
      File.write(b, "b")
      first = app.open_public(a)
      first.editor.insert_text("first-")
      second = app.open_public(b)
      second.editor.insert_text("second-")
      app.quit
      choose_close_discard(app)
      # Simulate a deferred producer after the first decision. This must be
      # reviewed again, not covered by a blanket force-quit permission.
      first.editor.insert_text("new-")
      choose_close_discard(app)
      app.exited_public?.should be_false
      app.paths_public.should eq [a.to_s, b.to_s]
      first.editor.text.should contain "new-"
      File.read(a).should eq "a"
      File.read(b).should eq "b"
    end
  end

  it "does not close a replacement editor with the same buffer version" do
    with_close_adversary do |root, app|
      path = root / "replace.cr"
      File.write(path, "original")
      target = app.open_public(path)
      target.editor.insert_text("old-")
      app.close_public(path).should be_false
      old_version = target.version
      replacement = app.replace_editor_public(path, target)
      target.version.should eq old_version
      choose_close_discard(app)
      app.paths_public.should eq [path.to_s]
      replacement.text.should eq "old-original"
      app.close_confirmation_active_public.should be_true
      File.read(path).should eq "original"
    end
  end

  it "invalidates a pending clipboard read even after the dialog is cancelled" do
    backend = CloseBlockingClipboard.new
    with_close_adversary(backend) do |root, app|
      path = root / "paste.cr"
      File.write(path, "base")
      target = app.open_public(path)
      target.editor.insert_text("dirty-")
      app.handle_event(Tui::KeyEvent.new('\u0016'))
      select
      when backend.started.receive
      when timeout(2.seconds)
        fail "clipboard read did not start"
      end
      app.close_public(path).should be_false
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      backend.release.send(nil)
      select
      when backend.finished.receive
      when timeout(2.seconds)
        fail "clipboard read did not finish"
      end
      sleep 20.milliseconds
      target.editor.text.should eq "dirty-base"
      app.paths_public.should eq [path.to_s]
    end
  end
end
