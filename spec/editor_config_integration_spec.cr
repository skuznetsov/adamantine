require "spec"

require "../src/adamantine/editing_text_editor"

private def config_editor(text : String) : Adamantine::EditingTextEditor
  editor = Adamantine::EditingTextEditor.new("editor-config-spec")
  editor.load_content_as_saved(text, Path.new("editor-config-spec"))
  editor
end

describe "EditingTextEditor EditorConfig hooks" do
  it "applies visual and insertion policy without changing bytes, history, or saved state" do
    original = "a\r\nb\n"
    editor = config_editor(original)
    editor.set_cursor(1, 1)
    editor.apply_editor_config(4, indent_style: :space, tab_width: 3, end_of_line: "\r\n")

    editor.tab_size.should eq 3
    editor.indent_width.should eq 4
    editor.indent_style.should eq :space
    editor.text.should eq original
    editor.modified?.should be_false
    editor.can_undo?.should be_false
    editor.cursor_line.should eq 1
    editor.cursor_col.should eq 1

    editor.insert_newline
    editor.text.should eq "a\r\nb\r\n\n"
    editor.undo.should be_true
    editor.text.should eq original
    editor.modified?.should be_false
  end

  it "accounts for the current tab stop when inserting tab-style indentation" do
    editor = config_editor("a")
    editor.apply_editor_config(4, indent_style: :tab, tab_width: 3)
    editor.set_cursor(0, 1)

    editor.indent.should be_true
    editor.text.should eq "a\t  "
    editor.undo.should be_true
    editor.text.should eq "a"
    editor.modified?.should be_false
  end

  it "shifts selection columns by inserted codepoints, not logical columns" do
    editor = config_editor("one\ntwo")
    editor.apply_editor_config(4, indent_style: :tab, tab_width: 3)
    editor.select_range(0, 1, 1, 2)

    editor.indent.should be_true
    editor.text.should eq "\t one\n\t two"
    editor.copy.should eq("ne\n\t tw")
    editor.undo.should be_true
    editor.text.should eq "one\ntwo"
  end

  it "dedents a generated tab-plus-space unit as one command" do
    editor = config_editor("\t one")
    editor.apply_editor_config(4, indent_style: :tab, tab_width: 3)

    editor.dedent.should be_true
    editor.text.should eq "one"
    editor.undo.should be_true
    editor.text.should eq "\t one"
  end
end
