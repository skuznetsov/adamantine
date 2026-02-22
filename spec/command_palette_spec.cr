require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/app"

def file_uri(path : Path) : String
  "file://#{path.expand.to_s.gsub(" ", "%20")}".gsub("\\", "/")
end

class TestApp < CrystalEditor::App
  def open_file_public(path : String | Path, line : Int32? = nil, col : Int32? = nil)
    open_file(Path.new(path), line, col)
  end

  def open_command_palette_public
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def command_open? : Bool
    @command_open
  end

  def context_menu_open? : Bool
    @context_menu_open
  end

  def context_menu_title : String
    @context_menu_title
  end

  def run_command(command : String) : Nil
    open_command_palette_public unless @command_open
    command.each_char { |ch| on_capture(Tui::KeyEvent.new(ch)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" if editor.nil?
    {editor.cursor_line, editor.cursor_col}
  end

  def command_input_text : String
    @command_input
  end

  def active_uri : String?
    current_buffer.try(&.uri)
  end
end

def with_temp_workspace(prefix : String = "editor-command-palette-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::App do
  it "searches forward with / and repeats with n" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\nbeta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)

      app.run_command("/beta")
      raise "first forward search should jump to first match" unless app.cursor == {1, 0}

      app.run_command("n")
      raise "n should jump to next match" unless app.cursor == {2, 0}
    end
  end

  it "searches backward with ? and flips direction with N" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "zero\nmatch\none\nmatch\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)

      app.run_command("/match")
      raise "setup forward search should land first match" unless app.cursor == {1, 0}

      app.run_command("?match")
      raise "backward search should wrap to previous match" unless app.cursor == {3, 0}

      app.run_command("N")
      raise "N should repeat backward search direction from last ?" unless app.cursor == {1, 0}
    end
  end

  it "opens quick actions with Shift+Enter" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)

      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter, Tui::Modifiers::Shift))
      raise "Shift+Enter should be handled" unless handled
      raise "quick actions menu should open" unless app.context_menu_open?
      raise "quick actions title expected" unless app.context_menu_title == "Quick Actions"
    end
  end

  it "opens search dialog from quick actions menu" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter, Tui::Modifiers::Shift))

      app.on_capture(Tui::KeyEvent.new('1'))

      raise "command palette should open" unless app.command_open?
      raise "command input should be prefilled for search" unless app.command_input_text == "/"
      raise "context menu should close after action" if app.context_menu_open?
    end
  end

  it "allows menu-bound letters in command input" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.open_command_palette_public

      "mark x".each_char do |ch|
        app.on_capture(Tui::KeyEvent.new(ch))
      end

      raise "k should remain in command input" unless app.command_input_text == ":mark x"
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    end
  end

  it "switches to buffer by index via :buf" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      file_c = Path.new(tmp_dir, "c.cr")
      File.write(file_a, "a\n")
      File.write(file_b, "b\n")
      File.write(file_c, "c\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.open_file_public(file_c)
      raise "expected c active before switch" unless app.active_uri == file_uri(file_c)

      app.run_command("buf 2")
      raise "active buffer should be b" unless app.active_uri == file_uri(file_b)

      app.run_command("buf 1")
      raise "active buffer should return to a" unless app.active_uri == file_uri(file_a)
    end
  end

  it "switches to buffer by exact name via :buf" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "alpha.cr")
      file_b = Path.new(tmp_dir, "beta.cr")
      File.write(file_a, "a\n")
      File.write(file_b, "b\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)

      app.run_command("buf alpha.cr")
      raise "active buffer should remain alpha by name" unless app.active_uri == file_uri(file_a)
    end
  end

  it "reuses existing tab when opening the same file with cursor position" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "same.cr")
      File.write(file_a, "line0\nline1\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a, 0, 0)
      app.open_file_public(file_a, 1, 2)

      raise "should move cursor in existing buffer" unless app.cursor == {1, 2}
    end
  end

  it "ignores out-of-range :buf index" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      file_c = Path.new(tmp_dir, "c.cr")
      File.write(file_a, "a\n")
      File.write(file_b, "b\n")
      File.write(file_c, "c\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.open_file_public(file_c)
      raise "expected c active before switch" unless app.active_uri == file_uri(file_c)

      app.run_command("buf 99")
      raise "active buffer should remain unchanged on invalid index" unless app.active_uri == file_uri(file_c)
    end
  end

  it "keeps active buffer when :buf match is ambiguous" do
    with_temp_workspace do |tmp_dir|
      nested = Path.new(tmp_dir, "nested")
      other = Path.new(tmp_dir, "other")
      Dir.mkdir_p(nested)
      Dir.mkdir_p(other)

      file_a = Path.new(tmp_dir, "shared.cr")
      file_b = Path.new(nested, "shared.cr")
      file_c = Path.new(other, "shared.cr")
      File.write(file_a, "root\n")
      File.write(file_b, "nested\n")
      File.write(file_c, "other\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.open_file_public(file_c)
      raise "expected other/shared.cr active before switch" unless app.active_uri == file_uri(file_c)

      app.run_command("buf shared.cr")
      raise "active buffer should remain unchanged on ambiguous name" unless app.active_uri == file_uri(file_c)
    end
  end
end
