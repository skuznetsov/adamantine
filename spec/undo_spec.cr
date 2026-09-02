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

  def run_command(command : String) : Nil
    open_command_palette_public unless @command_palette.open
    command.each_char { |ch| on_capture(Tui::KeyEvent.new(ch)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def editor_text : String
    editor = current_editor
    raise "expected active editor" if editor.nil?
    editor.text
  end

  def set_key_bindings(bindings : CrystalEditor::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" if editor.nil?
    {editor.cursor_line, editor.cursor_col}
  end
end

def with_temp_workspace(prefix : String = "editor-undo-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::App do
  it "undoes typing with Ctrl+Z and redoes with Ctrl+Y" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "ab")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(CrystalEditor::KeyConfig.defaults)
      app.open_file_public(file)
      raise "baseline text" unless app.editor_text == "ab"

      handled_x = app.handle_event(Tui::KeyEvent.new('x'))
      raise "typing x should be handled" unless handled_x
      raise "typed text, got #{app.editor_text.inspect}" unless app.editor_text == "xab" || app.editor_text == "abx"

      before_undo = app.editor_text
      handled_undo = app.handle_event(Tui::KeyEvent.new('\u001A'))
      raise "Ctrl+Z should be handled" unless handled_undo
      raise "undo should restore file text, got #{app.editor_text.inspect}" unless app.editor_text == "ab"
      raise "undo should not insert z" unless app.editor_text != "abz"

      handled_redo = app.handle_event(Tui::KeyEvent.new('y', Tui::Modifiers::Ctrl))
      raise "Ctrl+Y should be handled" unless handled_redo
      raise "redo should restore typed text" unless app.editor_text == before_undo
    end
  end

  it "undoes and redoes from the command palette" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "keep")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('!'))
      raise "typed bang" unless app.editor_text.includes?("!")

      app.run_command("undo")
      raise ":undo should restore file text" unless app.editor_text == "keep"

      app.run_command("redo")
      raise ":redo should restore the edit" unless app.editor_text.includes?("!")
    end
  end
end
