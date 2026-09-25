require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

class CloseConfirmationSpecApp < Adamantine::App
  def open_file_public(path : String | Path) : Bool
    open_file(Path.new(path))
  end

  def run_command_public(command : String) : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    command.each_char { |char| on_capture(Tui::KeyEvent.new(char)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def close_tab_public(id : String) : Bool
    @editor_tabs.close_tab(id)
  end

  def switch_to_public(id : String) : Bool
    @editor_tabs.switch_to(id)
  end

  def tab_count : Int32
    @editor_tabs.tabs.size
  end

  def active_path : Path?
    current_buffer.try(&.path)
  end

  def active_modified? : Bool
    current_buffer.try(&.editor.modified?) || false
  end

  def dirty_active! : Nil
    handle_event(Tui::KeyEvent.new('!'))
  end

  def poll_external_files_public : Int32
    @document_orchestrator.poll_external_files
  end

  def external_conflict? : Bool
    !current_buffer.try(&.external_conflict).nil?
  end

  def input_closed? : Bool
    @input.events.closed?
  end
end

CONFIRMATION_TEST_APPS = [] of CloseConfirmationSpecApp

def new_close_confirmation_app(project_root : Path) : CloseConfirmationSpecApp
  keymap = project_root / "config.json"
  File.write(keymap, "{}")
  app = CloseConfirmationSpecApp.new(
    project_root: project_root, lsp_command: "", session_enabled: false,
    keymap_path: keymap.to_s, recovery_root: project_root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
  )
  CONFIRMATION_TEST_APPS << app
  app
end

def with_close_confirmation_workspace(prefix : String = "editor-close-confirmation-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  CONFIRMATION_TEST_APPS.each do |app|
    app.quit(force: true) unless app.input_closed?
  end
  CONFIRMATION_TEST_APPS.clear
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe "file-scoped close confirmation" do
  it "keeps a dirty close open on the default Enter and cancels on Escape" do
    with_close_confirmation_workspace do |tmp_dir|
      file = tmp_dir / "dirty.cr"
      File.write(file, "first\n")
      app = new_close_confirmation_app(tmp_dir)
      app.open_file_public(file)
      app.dirty_active!

      app.run_command_public("q")
      raise "dirty close should retain the tab before a decision" unless app.tab_count == 1
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "Cancel should be selected by default" unless app.tab_count == 1
      raise "default Cancel should retain dirty text" unless app.active_modified?
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      raise "Escape should cancel confirmation without quitting" if app.input_closed?
      raise "Escape should retain the dirty tab" unless app.tab_count == 1
    end
  end

  it "saves or discards the captured file only after the explicit choice" do
    with_close_confirmation_workspace do |tmp_dir|
      saved = tmp_dir / "saved.cr"
      File.write(saved, "first\n")
      save_app = new_close_confirmation_app(tmp_dir)
      save_app.open_file_public(saved)
      save_app.dirty_active!
      save_app.run_command_public("q")
      save_app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))
      save_app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "Tab from Cancel then Enter should Save and close" unless save_app.tab_count == 0
      raise "Save should persist the edit" unless File.read(saved.to_s).includes?('!')

      discarded = tmp_dir / "discarded.cr"
      File.write(discarded, "first\n")
      discard_app = new_close_confirmation_app(tmp_dir)
      discard_app.open_file_public(discarded)
      discard_app.dirty_active!
      discard_app.run_command_public("q")
      discard_app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift))
      discard_app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "Shift+Tab from Cancel then Enter should Discard and close" unless discard_app.tab_count == 0
      raise "Discard must not write the source" unless File.read(discarded.to_s) == "first\n"
    end
  end

  it "saves an inactive dirty target without changing the active tab" do
    with_close_confirmation_workspace do |tmp_dir|
      target = tmp_dir / "target.cr"
      active = tmp_dir / "active.cr"
      File.write(target, "target\n")
      File.write(active, "active\n")
      app = new_close_confirmation_app(tmp_dir)
      app.open_file_public(target)
      app.dirty_active!
      app.open_file_public(active)
      raise "the second file should be active" unless app.active_path == active
      raise "dirty inactive target should be deferred to confirmation" if app.close_tab_public(target.to_s)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "Save should close only the inactive target" unless app.tab_count == 1
      raise "the other tab should remain active" unless app.active_path == active
      raise "Save should persist the inactive target" unless File.read(target.to_s).includes?('!')
    end
  end

  it "collects quit decisions without removing tabs and cancels the whole quit" do
    with_close_confirmation_workspace do |tmp_dir|
      first = tmp_dir / "first.cr"
      second = tmp_dir / "second.cr"
      File.write(first, "first\n")
      File.write(second, "second\n")
      app = new_close_confirmation_app(tmp_dir)
      app.open_file_public(first)
      app.dirty_active!
      app.open_file_public(second)
      app.dirty_active!

      app.on_capture(Tui::KeyEvent.new('q', Tui::Modifiers::Ctrl))
      # Save the first reviewed file so refusal-only quit implementations cannot
      # satisfy the later cancellation assertions without advancing review.
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      saved_count = [first, second].count { |path| File.read(path.to_s).includes?('!') }
      raise "quit should commit the first explicit Save before the next prompt" unless saved_count == 1
      raise "discard during quit must retain both tabs" unless app.tab_count == 2
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      raise "Cancel should leave the application running" if app.input_closed?
      raise "Cancel should retain both tabs" unless app.tab_count == 2
    end
  end

  it "completes ordinary quit only after both dirty files are explicitly discarded" do
    with_close_confirmation_workspace do |tmp_dir|
      first = tmp_dir / "first.cr"
      second = tmp_dir / "second.cr"
      File.write(first, "first\n")
      File.write(second, "second\n")
      app = new_close_confirmation_app(tmp_dir)
      app.open_file_public(first)
      app.dirty_active!
      app.open_file_public(second)
      app.dirty_active!

      app.on_capture(Tui::KeyEvent.new('q', Tui::Modifiers::Ctrl))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "two explicit Discards should complete quit" unless app.input_closed?
      raise "Discard should not write the first file" unless File.read(first.to_s) == "first\n"
      raise "Discard should not write the second file" unless File.read(second.to_s) == "second\n"
    end
  end

  it "keeps a failed Save decision in the dialog" do
    with_close_confirmation_workspace do |tmp_dir|
      file = tmp_dir / "save-failure.cr"
      File.write(file, "first\n")
      app = new_close_confirmation_app(tmp_dir)
      app.open_file_public(file)
      app.dirty_active!
      File.delete(file.to_s)
      Dir.mkdir(file.to_s)
      app.run_command_public("q")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "failed Save must keep the buffer open" unless app.tab_count == 1
      raise "failed Save must not quit the application" if app.input_closed?
    end
  end

  it "refuses Save for an external conflict and keeps the target open" do
    with_close_confirmation_workspace do |tmp_dir|
      file = tmp_dir / "external.cr"
      File.write(file, "base\n")
      app = new_close_confirmation_app(tmp_dir)
      app.open_file_public(file)
      File.write(file, "theirs\n")
      disk_before_save = File.read(file.to_s)
      raise "external change should publish a conflict" unless app.poll_external_files_public == 1
      raise "external conflict should be visible on the target" unless app.external_conflict?

      app.run_command_public("q")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "conflict Save must keep the tab open" unless app.tab_count == 1
      raise "conflict Save must not quit" if app.input_closed?
      raise "conflict Save must not overwrite disk" unless File.read(file.to_s) == disk_before_save
      # A failed Save must leave the same decision surface available.  A
      # refusal-only implementation would route these keys to the editor.
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "conflict Save failure should leave an explicit Discard path" unless app.tab_count == 0
    end
  end

  it "closes a clean file immediately and preserves explicit force quit" do
    with_close_confirmation_workspace do |tmp_dir|
      clean = tmp_dir / "clean.cr"
      File.write(clean, "first\n")
      close_app = new_close_confirmation_app(tmp_dir)
      close_app.open_file_public(clean)
      close_app.run_command_public("q")
      raise "clean close should remove the tab" unless close_app.tab_count == 0

      dirty = tmp_dir / "force.cr"
      File.write(dirty, "first\n")
      quit_app = new_close_confirmation_app(tmp_dir)
      quit_app.open_file_public(dirty)
      quit_app.dirty_active!
      quit_app.quit(force: true)
      raise "explicit force quit should close the application" unless quit_app.input_closed?
    end
  end
end
