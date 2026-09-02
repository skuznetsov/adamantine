require "spec"
require "crystal_tui"

require "../src/adamantine/search_state"
require "../src/adamantine/box_drawing"
require "../src/adamantine/search_panel"

private class SearchPanelRenderSpecHarness
  include Adamantine::SearchPanel
  include Adamantine::BoxDrawing

  @search : Adamantine::SearchState

  def initialize(query : String, cursor : Int32)
    @search = Adamantine::SearchState.new
    @search.query = query
    @search.query_cursor = cursor
  end

  def draw_query(buffer : Tui::Buffer, width : Int32, style : Tui::Style, cursor_style : Tui::Style) : Nil
    draw_search_query_line(
      buffer,
      Tui::Rect.new(0, 0, buffer.width, buffer.height),
      0,
      0,
      width,
      style,
      cursor_style
    )
  end
end

describe Adamantine::SearchPanel do
  it "keeps a CJK cursor on the following display cell" do
    normal = Tui::Style.new(fg: Tui::Color.white)
    cursor_style = Tui::Style.new(fg: Tui::Color.black, bg: Tui::Color.cyan)
    buffer = Tui::Buffer.new(8, 1)

    SearchPanelRenderSpecHarness.new("A中B", 2).draw_query(buffer, 5, normal, cursor_style)

    buffer.get(1, 0).glyph.should eq("中")
    buffer.get(2, 0).continuation?.should be_true
    buffer.get(3, 0).glyph.should eq("B")
    buffer.get(3, 0).style.should eq(cursor_style)
  end

  it "keeps an emoji cursor out of its continuation cell" do
    normal = Tui::Style.new(fg: Tui::Color.white)
    cursor_style = Tui::Style.new(fg: Tui::Color.black, bg: Tui::Color.cyan)
    buffer = Tui::Buffer.new(8, 1)

    SearchPanelRenderSpecHarness.new("😀A", 1).draw_query(buffer, 4, normal, cursor_style)

    buffer.get(0, 0).glyph.should eq("😀")
    buffer.get(1, 0).continuation?.should be_true
    buffer.get(2, 0).glyph.should eq("A")
    buffer.get(2, 0).style.should eq(cursor_style)
  end

  it "places a combining-sequence cursor by display width" do
    normal = Tui::Style.new(fg: Tui::Color.white)
    cursor_style = Tui::Style.new(fg: Tui::Color.black, bg: Tui::Color.cyan)
    buffer = Tui::Buffer.new(8, 1)

    SearchPanelRenderSpecHarness.new("e\u0301X", 2).draw_query(buffer, 3, normal, cursor_style)

    buffer.get(0, 0).glyph.should eq("e\u0301")
    buffer.get(1, 0).glyph.should eq("X")
    buffer.get(1, 0).style.should eq(cursor_style)
  end
end
