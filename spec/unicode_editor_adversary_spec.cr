require "spec"
require "../src/adamantine/editing_text_editor"

private class BoundedUnicodeEditor < Adamantine::EditingTextEditor
  def scroll_for_test(cells : Int32)
    @scroll_x = cells
  end

  def text : String
    raise "rendering must not copy the document"
  end

  def lines : Array(String)
    raise "rendering must not copy all lines"
  end

  private def line_at(index : Int32) : String
    raise "rendering must not materialize a giant line"
  end
end

describe "parent Unicode adversarial checks" do
  it "positions a folded placeholder once after horizontal scrolling and protects the gutter" do
    editor = BoundedUnicodeEditor.new("scrolled-fold")
    editor.show_line_numbers = false
    editor.show_fold_gutter = true
    editor.show_scrollbar = false
    editor.rect = Tui::Rect.new(0, 0, 14, 3)
    editor.text = "界abc\ninside\nend"
    editor.set_fold_ranges([Tui::TextEditor::FoldRange.new(0, 2)])
    editor.toggle_fold_at(0)
    editor.scroll_for_test(1)
    buffer = Tui::Buffer.new(14, 3)
    editor.render(buffer, Tui::Rect.new(0, 0, 14, 3))
    buffer.get(0, 0).glyph.should eq("+")
    buffer.get(1, 0).glyph.should eq(" ")
    buffer.get(2, 0).glyph.should eq("a")
    buffer.get(5, 0).glyph.should eq(" ")
    buffer.get(6, 0).glyph.should eq("{")
    editor.on_event(Tui::MouseEvent.new(6, 0))
    editor.fold_marker_at(0).should eq('-')
  end

  it "does not select unrelated lines when a grapheme selection is present" do
    editor = Adamantine::EditingTextEditor.new("selection-extent")
    editor.show_line_numbers = false
    editor.show_fold_gutter = false
    editor.show_scrollbar = false
    editor.rect = Tui::Rect.new(0, 0, 12, 4)
    editor.text = "a界\n界e\u0301\n🙂z"
    editor.selection_bg = Tui::Color.red
    editor.select_range(0, 0, 0, 1)
    buffer = Tui::Buffer.new(12, 4)
    editor.render(buffer, Tui::Rect.new(0, 0, 12, 4))
    buffer.get(0, 1).style.bg.should eq(editor.text_bg)
    buffer.get(0, 2).style.bg.should eq(editor.text_bg)
  end

  it "moves and deletes across independently specified cluster boundaries" do
    clusters = ["a", "e\u0301", "👩‍💻", "🇺🇸", "👍🏽", "界", "\t", "x\u0308\u0301"]
    text = clusters.join
    offsets = [0]
    clusters.each { |cluster| offsets << offsets.last + cluster.size }
    editor = Adamantine::EditingTextEditor.new("grapheme-oracle")
    editor.load_content_as_saved(text, Path.new("grapheme-oracle"))
    offsets.skip(1).each do |expected|
      editor.move_right
      editor.cursor_col.should eq(expected)
    end
    offsets.reverse.skip(1).each do |expected|
      editor.move_left
      editor.cursor_col.should eq(expected)
    end

    clusters.each_with_index do |cluster, index|
      remaining = clusters.dup
      remaining.delete_at(index)
      expected_text = remaining.join
      editor.load_content_as_saved(text, Path.new("grapheme-oracle"))
      editor.set_cursor(0, offsets[index])
      editor.delete
      editor.text.should eq(expected_text)
      editor.undo.should be_true
      editor.text.should eq(text)
      editor.redo.should be_true
      editor.text.should eq(expected_text)
      editor.load_content_as_saved(text, Path.new("grapheme-oracle"))
      editor.set_cursor(0, offsets[index + 1])
      editor.backspace
      editor.text.should eq(expected_text)
      editor.undo.should be_true
      editor.text.should eq(text)
    end
  end

  it "renders a tab and wide/combining prefix without whole-line getters" do
    editor = BoundedUnicodeEditor.new("wide-long-line")
    editor.show_line_numbers = false
    editor.show_fold_gutter = false
    editor.show_scrollbar = false
    editor.tab_size = 4
    editor.rect = Tui::Rect.new(0, 0, 20, 2)
    editor.load_content_as_saved("a\t界e\u0301🙂" + "x" * 4_000_000, Path.new("wide-long-line"))
    buffer = Tui::Buffer.new(20, 2)
    editor.render(buffer, Tui::Rect.new(0, 0, 20, 2))
    buffer.get(0, 0).glyph.should eq("a")
    buffer.get(1, 0).glyph.should eq(" ")
    buffer.get(3, 0).glyph.should eq(" ")
    buffer.get(4, 0).glyph.should eq("界")
    buffer.get(5, 0).continuation?.should be_true
    buffer.get(6, 0).glyph.should eq("e\u0301")
    buffer.get(7, 0).glyph.should eq("🙂")
    buffer.get(8, 0).continuation?.should be_true
    before = GC.stats.total_bytes
    4.times { editor.render(buffer, Tui::Rect.new(0, 0, 20, 2)) }
    (GC.stats.total_bytes - before).should be < 4_000_000_u64
    before = GC.stats.total_bytes
    editor.on_event(Tui::MouseEvent.new(4, 0))
    editor.cursor_col.should eq(2)
    (GC.stats.total_bytes - before).should be < 4_000_000_u64
  end
end
