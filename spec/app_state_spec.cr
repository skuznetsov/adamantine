require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/app"

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

  class TestApp < CrystalEditor::App
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
end

describe CrystalEditor::App do
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
      raise "open buffers should remain after root change" unless app.open_buffer_count == 2
      raise "active uri should remain file b" unless app.active_uri == file_uri(file_b)

      app.run_command("jump m")
      raise "jump to mark should still open source file after root change" unless app.active_uri == file_uri(file_a)
      raise "jump should restore marked location" unless app.cursor == {0, 0}
    end
  end
end
