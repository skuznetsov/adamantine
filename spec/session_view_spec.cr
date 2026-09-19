require "spec"
require "../src/adamantine/app"

describe "Session viewport safety" do
  it "preserves horizontal scrolling when the top row is shorter than the cursor row" do
    editor = Adamantine::EditingTextEditor.new
    editor.text = "a\n\t🙂" + "x" * 100
    editor.tab_size = 4
    editor.set_cursor(1, 50)
    editor.restore_session_view(0, 20)
    editor.session_scroll_y.should eq 0
    editor.session_scroll_x.should eq 20
    editor.cursor_line.should eq 1
    editor.cursor_col.should eq 50
  end

  it "clamps persisted viewport offsets before terminal arithmetic" do
    editor = Adamantine::EditingTextEditor.new
    editor.text = "a\n\t🙂z"
    editor.tab_size = 4
    editor.rect = Tui::Rect.new(0, 0, 20, 3)
    editor.restore_session_view(Int32::MAX, Int32::MAX)
    editor.session_scroll_y.should eq 1
    editor.session_scroll_x.should be <= 7
    buffer = Tui::Buffer.new(20, 3)
    editor.render(buffer, Tui::Rect.new(0, 0, 20, 3))
    editor.restore_session_view(-1, -1)
    editor.session_scroll_y.should eq 0
    editor.session_scroll_x.should eq 0
  end

  it "preserves cell-based horizontal scrolling separately from codepoint cursor columns" do
    editor = Adamantine::EditingTextEditor.new
    editor.text = "\t🙂hello\nnext"
    editor.tab_size = 4
    editor.set_cursor(0, 3)
    editor.restore_session_view(0, 5)
    editor.cursor_col.should eq 3
    editor.session_scroll_x.should eq 5
    editor.text.should eq "\t🙂hello\nnext"
  end
end
