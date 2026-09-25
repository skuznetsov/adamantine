require "spec"
require "../src/adamantine/editing_text_editor"

# Fail loudly if a local edit regresses to a whole-document public API.
private class LocalIndentationEditor < Adamantine::EditingTextEditor
  def text : String
    raise "local indentation must not materialize the complete document"
  end

  def lines : Array(String)
    raise "local indentation must not materialize every line"
  end

  def replace_text(content : String) : Bool
    raise "local indentation must not replace the complete document"
  end

  def stored_bytes : Int64
    @buffer.storage_bytesize
  end

  def document_bytes : Int32
    @buffer.byte_length
  end

  def sample_line(index : Int32) : String
    @buffer.line(index)
  end

  private def line_at(index : Int32) : String
    raise "prefix detection must not materialize a complete logical line"
  end
end

describe "local indentation on a multi-megabyte buffer" do
  it "reads only the prefix of a multi-megabyte single line" do
    original = "  " + "x" * 4_000_000
    editor = LocalIndentationEditor.new("large-single-line-indent")
    editor.text = original
    editor.tab_size = 2
    editor.set_cursor(0, 2)
    editor.insert_newline
    editor.document_bytes.should eq original.bytesize + 3
    editor.stored_bytes.should eq original.bytesize.to_i64 + 3
    editor.undo.should be_true
    editor.document_bytes.should eq original.bytesize
    editor.dedent.should be_true
    editor.document_bytes.should eq original.bytesize - 2
    editor.undo.should be_true
    editor.document_bytes.should eq original.bytesize
  end

  it "preserves a whitespace prefix across scanning chunk boundaries" do
    prefix = " \t" * 1500
    editor = LocalIndentationEditor.new("long-whitespace-prefix")
    editor.text = prefix + "tail"
    editor.set_cursor(0, prefix.size)
    editor.insert_newline
    editor.document_bytes.should eq prefix.bytesize * 2 + 5
    editor.sample_line(0).should eq prefix
    editor.sample_line(1).should eq prefix + "tail"
    editor.undo.should be_true
    editor.document_bytes.should eq prefix.bytesize + 4
  end

  it "keeps caret Tab and Enter on the incremental change path" do
    original = ("  " + "x" * 200 + "\r\n") * 20_000
    editor = LocalIndentationEditor.new("large-caret-indent")
    editor.text = original
    editor.tab_size = 4
    editor.set_cursor(10_000, 202)
    changes = [] of Tui::TextEditor::TextChange
    editor.on_text_change { |change| changes << change; nil }

    editor.indent.should be_true
    changes.last.incremental?.should be_true
    changes.last.text.should eq "    "
    editor.insert_newline
    changes.last.incremental?.should be_true
    changes.last.text.should eq "\r\n  "
    editor.document_bytes.should eq original.bytesize + 8
    editor.stored_bytes.should eq original.bytesize.to_i64 + 8
    editor.undo.should be_true
    editor.document_bytes.should eq original.bytesize + 4
    editor.undo.should be_true
    editor.document_bytes.should eq original.bytesize
  end

  it "shares undo storage and leaves distant lines unchanged" do
    line = "  " + "x" * 200
    original = (line + "\r\n") * 20_000
    editor = LocalIndentationEditor.new("large-indent")
    editor.text = original
    editor.tab_size = 4
    editor.select_range(10_000, 1, 10_002, 0)

    editor.indent

    editor.document_bytes.should eq original.bytesize + 8
    editor.stored_bytes.should eq original.bytesize.to_i64 + 8
    editor.sample_line(0).should eq line
    editor.sample_line(10_000).should eq "    " + line
    editor.sample_line(10_001).should eq "    " + line
    editor.sample_line(10_002).should eq line
    editor.sample_line(19_999).should eq line
    editor.undo.should be_true
    editor.document_bytes.should eq original.bytesize
    editor.sample_line(10_000).should eq line
    editor.sample_line(10_001).should eq line
    editor.can_undo?.should be_false
    editor.redo.should be_true
    editor.document_bytes.should eq original.bytesize + 8
  end
end
