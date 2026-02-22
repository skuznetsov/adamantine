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

  def jump_back_public : Nil
    jump_back
  end

  def jump_forward_public : Nil
    jump_forward
  end

  def forward_history : Array(CrystalEditor::NavigationLocation)
    @navigation_forward_history
  end

  def back_history : Array(CrystalEditor::NavigationLocation)
    @navigation_history
  end

  def active_uri
    current_buffer.try(&.uri)
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" if editor.nil?
    {editor.cursor_line, editor.cursor_col}
  end
end

def with_temp_workspace(prefix : String = "editor-nav-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::App do
  it "navigates backward then forward between open files" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "hello\nsecond\n")
      File.write(file_b, "world\nsecond\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a, 0, 0)
      app.open_file_public(file_b, 0, 1)

      app.back_history << CrystalEditor::NavigationLocation.new(file_uri(file_a), 0, 0)

      app.jump_back_public

      raise "wrong active file after jump back" unless app.active_uri == file_uri(file_a)
      raise "wrong cursor after jump back" unless app.cursor == {0, 0}
      raise "forward history not updated" unless app.forward_history == [CrystalEditor::NavigationLocation.new(file_uri(file_b), 0, 1)]

      app.jump_forward_public

      raise "wrong active file after jump forward" unless app.active_uri == file_uri(file_b)
      raise "wrong cursor after jump forward" unless app.cursor == {0, 1}
      raise "forward history not consumed" unless app.forward_history.empty?
      raise "back history not restored" unless app.back_history == [CrystalEditor::NavigationLocation.new(file_uri(file_a), 0, 0)]
    end
  end

  it "keeps current location when jump back is unavailable" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      File.write(file_a, "only file\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a, 0, 0)

      app.jump_back_public

      raise "uri changed unexpectedly" unless app.active_uri == file_uri(file_a)
      raise "history should remain empty" unless app.forward_history.empty?
      raise "cursor should stay the same" unless app.cursor == {0, 0}
    end
  end
end
