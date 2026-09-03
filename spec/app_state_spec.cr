require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

def file_uri(path : Path) : String
  "file://#{path.expand.to_s.gsub(" ", "%20")}".gsub("\\", "/")
end

def with_temp_workspace(prefix : String = "editor-app-state-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

class TestApp < Adamantine::App
  getter lsp_shutdown_calls : Int32 = 0
  getter lsp_root_change_calls : Int32 = 0

  def shutdown_lsp : Nil
    @lsp_shutdown_calls += 1
    super
  end

  def lsp_project_root_changed : Nil
    @lsp_root_change_calls += 1
    super
  end

  def open_file_public(path : String | Path, line : Int32? = nil, col : Int32? = nil)
    open_file(Path.new(path), line, col)
  end

  def run_command(command : String) : Nil
    open_command_palette_public unless @command_palette.open
    command.each_char { |ch| on_capture(Tui::KeyEvent.new(ch)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def project_root : String
    @project_root.to_s
  end

  def open_buffer_count : Int32
    @document_session.open_buffers.size
  end

  def active_uri
    current_buffer.try(&.uri)
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" if editor.nil?
    {editor.cursor_line, editor.cursor_col}
  end

  def open_command_palette_public
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def command_open : Bool
    @command_palette.open
  end

  def input_closed? : Bool
    @input.events.closed?
  end

  def editor_modified? : Bool
    editor = current_editor
    raise "expected active editor" if editor.nil?
    editor.modified?
  end

  def close_tab_widget_public : Bool
    @editor_tabs.close_active_tab
  end
end

describe Adamantine::App do
  it "closes active tab and keeps remaining tab active" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "first\n")
      File.write(file_b, "second\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      raise "expected two buffers before close" unless app.open_buffer_count == 2
      raise "expected b active before close" unless app.active_uri == file_uri(file_b)

      app.run_command("q")

      raise "exactly one buffer should remain after closing active" unless app.open_buffer_count == 1
      raise "previous buffer should become active" unless app.active_uri == file_uri(file_a)
    end
  end

  it "keeps editor state consistent when closing the last tab" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      File.write(file_a, "first\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      raise "expected one buffer before close" unless app.open_buffer_count == 1
      raise "expected active uri before close" unless app.active_uri == file_uri(file_a)

      app.run_command("q")
      raise "all buffers should be closed" unless app.open_buffer_count == 0
      raise "no active uri after closing all buffers" unless app.active_uri.nil?

      app.run_command("q")
      raise "buffer count should remain zero" unless app.open_buffer_count == 0
      raise "command should stay safe without an active editor" unless app.active_uri.nil?
    end
  end

  it "blocks :q and Ctrl-W for a dirty active tab" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "dirty.cr")
      File.write(file, "first\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('!'))
      raise "sanity: file should be dirty" unless app.editor_modified?

      app.run_command("q")
      raise ":q must not close a dirty tab" unless app.open_buffer_count == 1
      raise "blocked :q must leave the input running" if app.input_closed?

      handled = app.handle_event(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))
      raise "Ctrl-W should be handled" unless handled
      raise "Ctrl-W must not close a dirty tab" unless app.open_buffer_count == 1
      raise "blocked Ctrl-W must leave the input running" if app.input_closed?

      raise "tab widget close must be vetoed for a dirty tab" if app.close_tab_widget_public
      raise "tab widget close must preserve the dirty buffer" unless app.open_buffer_count == 1
    end
  end

  it "blocks application quit when any open buffer is dirty" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "first\n")
      File.write(file_b, "second\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.open_file_public(file_a)
      app.handle_event(Tui::KeyEvent.new('!'))
      raise "sanity: one buffer should be dirty" unless app.editor_modified?

      handled = app.handle_event(Tui::KeyEvent.new('q', Tui::Modifiers::Ctrl))
      raise "Ctrl-Q should be handled" unless handled
      raise "application quit must be blocked by any dirty buffer" if app.input_closed?
      raise "dirty buffer should remain open" unless app.open_buffer_count == 2
    end
  end

  it "does not quit after :wq save failure" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "wq-failure.cr")
      File.write(file, "first\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('!'))
      File.delete(file.to_s)
      Dir.mkdir(file.to_s)

      app.run_command("wq")

      raise "failed :wq must keep the buffer open" unless app.open_buffer_count == 1
      raise "failed :wq must keep the buffer dirty" unless app.editor_modified?
      raise "failed :wq must not quit the application" if app.input_closed?
    end
  end

  it "quits after a successful :wq save" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "wq-success.cr")
      File.write(file, "first\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('!'))
      app.run_command("wq")

      raise "successful :wq should quit the application" unless app.input_closed?
      raise "successful :wq should persist the edit" unless File.read(file.to_s).includes?('!')
    end
  end

  it "blocks the quit, exit, and qa aliases when a buffer is dirty" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "quit-aliases.cr")
      File.write(file, "first\n")

      ["quit", "exit", "qa"].each do |command|
        app = TestApp.new(project_root: tmp_dir, lsp_command: "")
        app.open_file_public(file)
        app.handle_event(Tui::KeyEvent.new('!'))
        app.run_command(command)

        raise ":#{command} must be blocked by dirty buffers" if app.input_closed?
      end
    end
  end

  it "allows q! to force quit with dirty buffers" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "force-quit.cr")
      File.write(file, "first\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('!'))
      app.run_command("q!")

      raise "q! should force quit despite dirty buffers" unless app.input_closed?
      raise "forced quit must shut down LSP" unless app.lsp_shutdown_calls == 1
    end
  end

  it "updates project root via :cd while preserving open buffers and marks" do
    with_temp_workspace do |tmp_dir|
      current_root = Path.new(tmp_dir, "project")
      other_root = Path.new(tmp_dir, "other_root")
      Dir.mkdir(current_root)
      Dir.mkdir_p(other_root)

      file_a = Path.new(current_root, "a.cr")
      file_b = Path.new(other_root, "b.cr")
      File.write(file_a, "first\n")
      File.write(file_b, "second\n")

      app = TestApp.new(project_root: current_root, lsp_command: "")
      app.open_file_public(file_a, 0, 0)
      app.run_command("mark m")
      app.open_file_public(file_b, 0, 0)

      app.run_command("cd #{other_root}")
      if app.project_root != other_root.to_s
        raise "project root should switch; got #{app.project_root} expected #{other_root}"
      end
      raise "project root change must invalidate the old LSP session" unless app.lsp_root_change_calls == 1
      raise "project root change must shut down the old LSP session" unless app.lsp_shutdown_calls == 1
      raise "open buffers should remain after root change" unless app.open_buffer_count == 2
      raise "active uri should remain file b" unless app.active_uri == file_uri(file_b)

      app.run_command("jump m")
      raise "jump to mark should still open source file after root change" unless app.active_uri == file_uri(file_a)
      raise "jump should restore marked location" unless app.cursor == {0, 0}
    end
  end
end
