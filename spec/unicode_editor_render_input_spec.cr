require "spec"
require "crystal_tui"

require "../src/adamantine/editing_text_editor"

private def unicode_render_editor(text : String, width : Int32 = 16) : Adamantine::EditingTextEditor
  editor = Adamantine::EditingTextEditor.new("unicode-render-input")
  editor.show_line_numbers = false
  editor.show_fold_gutter = false
  editor.show_scrollbar = false
  editor.rect = Tui::Rect.new(0, 0, width, 2)
  editor.load_content_as_saved(text, Path.new("unicode-render-input"))
  editor
end

describe "Unicode editor rendering and terminal input" do
  it "maps tab cells and drag selection in display-cell coordinates" do
    editor = unicode_render_editor("a\t界e\u0301🙂")
    editor.tab_size = 4

    editor.on_event(Tui::MouseEvent.new(2, 0)).should be_true
    editor.cursor_col.should eq(1)

    editor.on_event(Tui::MouseEvent.new(4, 0, Tui::MouseButton::Left, Tui::MouseAction::Drag)).should be_true
    editor.delete
    editor.text.should eq("a界e\u0301🙂")
  end

  it "omits a wide cluster that would be split by a horizontal viewport" do
    editor = unicode_render_editor("界x", 1)
    buffer = Tui::Buffer.new(1, 2)
    editor.render(buffer, Tui::Rect.new(0, 0, 1, 2))
    buffer.get(0, 0).continuation?.should be_false

    editor = unicode_render_editor("界x", 3)
    editor.move_right
    buffer = Tui::Buffer.new(3, 2)
    editor.render(buffer, Tui::Rect.new(0, 0, 3, 2))
    buffer.get(0, 0).continuation?.should be_false
    buffer.get(1, 0).glyph.should eq("x")
  end

  it "keeps a collapsed fold placeholder aligned after horizontal scroll" do
    editor = unicode_render_editor("head123456\nbody\nend", 8)
    editor.set_fold_ranges([Tui::TextEditor::FoldRange.new(0, 2)])
    editor.toggle_fold_at(0)
    editor.set_cursor(0, 10)
    buffer = Tui::Buffer.new(8, 2)
    editor.render(buffer, Tui::Rect.new(0, 0, 8, 2))
    buffer.get(6, 0).glyph.should eq(" ")
    buffer.get(7, 0).glyph.should eq("{")
  end
end
