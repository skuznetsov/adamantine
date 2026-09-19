require "spec"
require "file_utils"
require "../src/adamantine/app"

private class ExternalNotificationApp < Adamantine::App
  def open_public(path : Path) : Adamantine::OpenBuffer
    raise "fixture open failed" unless open_file(path)
    current_buffer.not_nil!
  end

  def poll_public : Nil
    @document_orchestrator.poll_external_files
  end

  def menu_title_public : String?
    @context_menu.open ? @context_menu.title : nil
  end

  def palette_public : Nil
    open_command_palette
  end

  def palette_input_public : String?
    @command_palette.open ? @command_palette.input : nil
  end

  def review_public : Nil
    open_external_review
  end

  def review_open_public? : Bool
    external_review_active?
  end

  def popup_public : Nil
    open_lsp_popup("Deferred hover", ["must not replace review"])
  end

  def popup_open_public? : Bool
    @lsp_popup.open
  end
end

private class ExternalReviewClipboard < Adamantine::Clipboard::Backend
  getter started = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  getter finished = Channel(Nil).new(1)

  def read : Adamantine::Clipboard::Result
    @started.send(nil)
    @release.receive
    @finished.send(nil)
    Adamantine::Clipboard::Result.success("late clipboard")
  end

  def write(text : String) : Adamantine::Clipboard::Result
    Adamantine::Clipboard::Result.success
  end
end

private def with_external_notification(backend = Adamantine::Clipboard::UnsupportedBackend.new, &)
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-external-notice-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "config.json"
  File.write(config, "{}")
  app = ExternalNotificationApp.new(root, lsp_command: "", keymap_path: config.to_s,
    clipboard_backend: backend,
    session_enabled: false, recovery_root: root / "recovery")
  yield root, app
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

describe "External change notifications" do
  it "does not interrupt typing or implicitly reload on Enter" do
    with_external_notification do |root, app|
      path = root / "typing.cr"
      File.write(path, "base")
      buffer = app.open_public(path)
      File.write(path, "external")
      app.poll_public
      buffer.external_conflict.should_not be_nil
      app.menu_title_public.should be_nil
      app.handle_event(Tui::KeyEvent.new('x'))
      buffer.editor.text.should eq "xbase"
      File.read(path).should eq "external"
    end
  end

  it "leaves the command palette and its query intact" do
    with_external_notification do |root, app|
      path = root / "palette.cr"
      File.write(path, "base")
      app.open_public(path)
      app.palette_public
      app.on_capture(Tui::KeyEvent.new('g'))
      before = app.palette_input_public
      before.should_not be_nil
      File.write(path, "external")
      app.poll_public
      app.menu_title_public.should be_nil
      app.palette_input_public.should eq before
      app.on_capture(Tui::KeyEvent.new('i'))
      app.palette_input_public.should eq "#{before}i"
    end
  end

  it "does not replace an active review with a newer candidate or a deferred popup" do
    with_external_notification do |root, app|
      path = root / "review.cr"
      File.write(path, "editor")
      buffer = app.open_public(path)
      File.write(path, "candidate one")
      app.poll_public
      app.review_public
      app.review_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab)) # Select Reload.
      File.write(path, "candidate two")
      app.poll_public
      app.popup_public
      app.popup_open_public?.should be_false
      app.review_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      buffer.editor.text.should eq "editor"
      File.read(path).should eq "candidate two"
      buffer.external_conflict.should_not be_nil
    end
  end

  it "requires explicit Save review even for a conflict first discovered by that save" do
    with_external_notification do |root, app|
      path = root / "save-race.cr"
      File.write(path, "base")
      buffer = app.open_public(path)
      buffer.editor.insert_text("mine-")
      File.write(path, "theirs")
      app.on_capture(Tui::KeyEvent.new('s', Tui::Modifiers::Ctrl))
      app.review_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)) # Default Later.
      buffer.editor.text.should eq "mine-base"
      File.read(path).should eq "theirs"
      buffer.external_conflict.should_not be_nil
    end
  end

  it "invalidates a clipboard read that finishes after opening and deferring review" do
    backend = ExternalReviewClipboard.new
    with_external_notification(backend) do |root, app|
      path = root / "late-paste.cr"
      File.write(path, "base")
      buffer = app.open_public(path)
      app.handle_event(Tui::KeyEvent.new('\u0016'))
      select
      when backend.started.receive
      when timeout(2.seconds)
        fail "clipboard read did not start"
      end
      File.write(path, "disk")
      app.poll_public
      app.review_public
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      backend.release.send(nil)
      select
      when backend.finished.receive
      when timeout(2.seconds)
        fail "clipboard read did not finish"
      end
      sleep 20.milliseconds
      buffer.editor.text.should eq "base"
      File.read(path).should eq "disk"
      buffer.external_conflict.should_not be_nil
    end
  end

  it "cancels a yielding preparation without installing its late overlay" do
    with_external_notification do |root, app|
      path = root / "loading.cr"
      File.write(path, "base")
      buffer = app.open_public(path)
      File.write(path, "disk")
      app.poll_public
      cancelled = false
      spawn do
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
        cancelled = true
      end
      app.review_public
      cancelled.should be_true # FileRevision.read must actually yield.
      app.review_open_public?.should be_false
      buffer.editor.text.should eq "base"
      File.read(path).should eq "disk"
      buffer.external_conflict.should_not be_nil
    end
  end

  it "opens review through the default shortcut without requiring colon commands" do
    with_external_notification do |root, app|
      path = root / "shortcut.cr"
      File.write(path, "base")
      buffer = app.open_public(path)
      File.write(path, "disk")
      app.poll_public
      app.on_capture(Tui::KeyEvent.new('e', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift))
      app.review_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.review_open_public?.should be_false
      buffer.editor.text.should eq "base"
      File.read(path).should eq "disk"
    end
  end

  it "offers explicit recreation, not reload, for a missing disk file" do
    with_external_notification do |root, app|
      path = root / "missing.cr"
      File.write(path, "base")
      buffer = app.open_public(path)
      buffer.editor.insert_text("mine-")
      File.delete(path)
      app.poll_public
      app.review_public
      app.review_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab)) # Only Later / Overwrite.
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.review_open_public?.should be_false
      File.read(path).should eq "mine-base"
      buffer.external_conflict.should be_nil
    end
  end

  it "does not offer a destructive choice for a non-text disk candidate" do
    with_external_notification do |root, app|
      path = root / "nontext.cr"
      File.write(path, "base")
      buffer = app.open_public(path)
      binary = "\0\xff"
      File.write(path, binary.to_slice)
      app.poll_public
      app.review_public
      app.review_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)) # Still Later.
      app.review_open_public?.should be_false
      buffer.editor.text.should eq "base"
      File.read(path).should eq binary
      buffer.external_conflict.should_not be_nil
    end
  end
end
