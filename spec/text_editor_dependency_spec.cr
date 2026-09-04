require "spec"
require "file_utils"
require "crystal_tui"

private def with_text_editor_file(content : String, &)
  root = Path.new(Dir.tempdir, "adamantine-text-editor-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "sample.txt"
  File.write(path, content)
  begin
    yield Tui::TextEditor.new("dependency-contract"), path
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "crystal_tui text editor contract" do
  it "round-trips final newlines and line-ending style" do
    ["alpha", "alpha\n", "alpha\n\n", "alpha\r\nbeta\r\n", "alpha\rbeta\r"].each do |content|
      with_text_editor_file(content) do |editor, path|
        editor.load_file(path).should be_true
        editor.text.should eq content
        editor.save.should be_true
        File.read(path).should eq content
      end
    end
  end

  it "atomically saves while preserving permissions and symlinks" do
    with_text_editor_file("before\n") do |editor, path|
      File.chmod(path, 0o640)
      original = File.info(path)
      link = path.parent / "sample-link.txt"
      File.symlink(path.basename.to_s, link)
      editor.load_file(link).should be_true
      editor.text = "after\n"

      editor.save.should be_true
      original.same_file?(File.info(path)).should be_false
      File.info(path).permissions.to_i.should eq(0o640)
      File.info(link, follow_symlinks: false).symlink?.should be_true
      File.read(path).should eq("after\n")
    end
  end

  it "supports an undoable complete-document replacement" do
    editor = Tui::TextEditor.new("replace-contract")
    editor.text = "old old\n"

    editor.replace_text("new new\n").should be_true
    editor.undo.should be_true
    editor.text.should eq "old old\n"
    editor.redo.should be_true
    editor.text.should eq "new new\n"
  end

  it "retains multi-megabyte undo states through shared buffer storage" do
    original = "source line 0123456789\n" * 350_000
    buffer = Tui::PieceTreeBuffer.new(original)
    original_state = buffer.snapshot
    history = [] of Tui::PieceTreeBuffer::Snapshot
    inserted_bytes = 0

    100.times do |index|
      inserted = "<#{index}>"
      inserted_bytes += inserted.bytesize
      buffer.insert(buffer.byte_length // 2, inserted)
      history << buffer.snapshot
    end

    buffer.storage_bytesize.should eq original.bytesize.to_i64 + inserted_bytes
    buffer.tree_height.should be <= Tui::PieceTreeBuffer::MAX_TREE_HEIGHT
    buffer.restore(original_state)
    buffer.byte_length.should eq original.bytesize
    buffer.restore(history.last)
    buffer.byte_length.should eq original.bytesize + inserted_bytes
  end
end
