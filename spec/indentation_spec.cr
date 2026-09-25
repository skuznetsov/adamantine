require "spec"
require "crystal_tui"

require "../src/adamantine/editing_text_editor"

private def editing_editor(text : String, *, tab_size : Int32 = 2, auto_indent : Bool = true) : Adamantine::EditingTextEditor
  editor = Adamantine::EditingTextEditor.new("indentation-spec")
  editor.tab_size = tab_size
  editor.auto_indent = auto_indent
  editor.load_content_as_saved(text, Path.new("indentation-spec"))
  editor
end

describe Adamantine::EditingTextEditor do
  it "indents a caret and records one undoable edit" do
    editor = editing_editor("alpha")
    editor.set_cursor(0, 2)

    editor.indent.should be_true
    editor.text.should eq("al  pha")
    editor.cursor_col.should eq(4)
    editor.can_undo?.should be_true

    editor.undo.should be_true
    editor.text.should eq("alpha")
  end

  it "indents selected lines and excludes a zero-column final line" do
    editor = editing_editor("one\ntwo\nthree")
    editor.select_range(0, 0, 2, 0)

    editor.indent.should be_true
    editor.text.should eq("  one\n  two\nthree")
    editor.cursor_line.should eq(2)
    editor.cursor_col.should eq(0)

    editor.undo.should be_true
    editor.text.should eq("one\ntwo\nthree")
  end

  it "preserves a reversed selection while shifting its active endpoint" do
    editor = editing_editor("one\ntwo\nthree")
    editor.select_range(2, 3, 0, 1)

    editor.indent.should be_true
    editor.text.should eq("  one\n  two\n  three")
    editor.cursor_line.should eq(0)
    editor.cursor_col.should eq(3)
    editor.copy.should eq("ne\n  two\n  thr")
  end

  it "dedents spaces or one leading tab and does not add undo for a no-op" do
    editor = editing_editor("    spaces\n\ttab\nplain")
    editor.select_range(0, 0, 2, 0)

    editor.dedent.should be_true
    editor.text.should eq("  spaces\ntab\nplain")
    editor.undo.should be_true
    editor.text.should eq("    spaces\n\ttab\nplain")

    editor.set_cursor(2, 0)
    editor.dedent.should be_false
    editor.can_undo?.should be_false
  end

  it "copies only indentation before a caret and preserves CRLF" do
    editor = editing_editor("  alpha\r\nbeta")
    editor.set_cursor(0, 7)

    editor.insert_newline
    editor.text.should eq("  alpha\r\n  \r\nbeta")

    no_auto = editing_editor("  alpha\r\nbeta", auto_indent: false)
    no_auto.set_cursor(0, 7)
    no_auto.insert_newline
    no_auto.text.should eq("  alpha\r\n\r\nbeta")
  end

  it "keeps repeated Enter presses as separate undo commands" do
    editor = editing_editor("alpha")
    editor.set_cursor(0, 5)

    editor.insert_newline
    editor.insert_newline
    editor.text.should eq("alpha\n\n")

    editor.undo.should be_true
    editor.text.should eq("alpha\n")
    editor.undo.should be_true
    editor.text.should eq("alpha")
    editor.undo.should be_false
  end

  it "does not copy indentation after a replacement selection" do
    editor = editing_editor("  alpha\n  beta")
    editor.select_range(0, 7, 1, 2)

    editor.insert_newline
    editor.text.should eq("  alpha\n  beta")
  end

  it "copies whitespace from the normalized start of a reversed selection" do
    editor = editing_editor("  alpha\n  beta")
    editor.select_range(1, 4, 0, 1)

    editor.insert_newline
    editor.text.should eq(" \n ta")
  end
end
