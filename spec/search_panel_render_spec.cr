require "spec"
require "crystal_tui"

require "../src/adamantine/search_state"
require "../src/adamantine/box_drawing"
require "../src/adamantine/theme"
require "../src/adamantine/search_panel"

private class SearchPanelRenderSpecBody
  getter rect : Tui::Rect

  def initialize(@rect : Tui::Rect)
  end
end

private class SearchPanelRenderSpecHarness
  include Adamantine::SearchPanel
  include Adamantine::BoxDrawing

  @search : Adamantine::SearchState
  @body_split : SearchPanelRenderSpecBody
  @project_root : Path

  def initialize(query : String, cursor : Int32)
    @search = Adamantine::SearchState.new
    @search.query = query
    @search.query_cursor = cursor
    @body_split = SearchPanelRenderSpecBody.new(Tui::Rect.new(0, 0, 80, 24))
    @project_root = Path.new("/project")
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

  def set_project_results(matches : Array(Adamantine::ProjectSearch::Match), truncated : Bool, searching : Bool = false) : Nil
    @search.open = true
    @search.scope = Adamantine::SearchState::Scope::Project
    @search.searching = searching
    @search.matches = matches
    @search.truncated = truncated
  end

  def render_project(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
    render_search_panel(buffer, clip)
  end

  def row_text(buffer : Tui::Buffer, y : Int32) : String
    String.build do |builder|
      buffer.width.times { |x| builder << buffer.get(x, y).glyph }
    end
  end

  def current_editor : Tui::TextEditor?
    nil
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

  it "labels incomplete zero-match project results instead of claiming no matches" do
    harness = SearchPanelRenderSpecHarness.new("missing", 7)
    harness.set_project_results([] of Adamantine::ProjectSearch::Match, truncated: true)
    buffer = Tui::Buffer.new(80, 24)
    harness.render_project(buffer, Tui::Rect.new(0, 0, 80, 24))

    title = harness.row_text(buffer, 1)
    message = harness.row_text(buffer, 3).strip
    raise "incomplete title should include a partial marker: #{title.inspect}" unless title.includes?("partial")
    raise "incomplete title should preserve the zero count: #{title.inspect}" unless title.includes?("0")
    raise "incomplete body should include a partial marker: #{message.inspect}" unless message.includes?("partial")
  end

  it "keeps complete zero-match project results definitive" do
    harness = SearchPanelRenderSpecHarness.new("missing", 7)
    harness.set_project_results([] of Adamantine::ProjectSearch::Match, truncated: false)
    buffer = Tui::Buffer.new(80, 24)
    harness.render_project(buffer, Tui::Rect.new(0, 0, 80, 24))

    title = harness.row_text(buffer, 1)
    message = harness.row_text(buffer, 3).strip
    raise "complete zero title should not be partial: #{title.inspect}" if title.includes?("partial")
    raise "complete zero title should show zero: #{title.inspect}" unless title.includes?("0")
    raise "complete zero body should remain definitive: #{message.inspect}" unless message.includes?("No matches")
  end

  it "marks nonzero partial project results in the bounded title" do
    harness = SearchPanelRenderSpecHarness.new("needle", 6)
    match = Adamantine::ProjectSearch::Match.new(Path.new("/project/source.cr"), 0, 0, "needle")
    harness.set_project_results([match], truncated: true)
    buffer = Tui::Buffer.new(80, 24)
    harness.render_project(buffer, Tui::Rect.new(0, 0, 80, 24))

    title = harness.row_text(buffer, 1)
    raise "nonzero incomplete title should include a partial marker: #{title.inspect}" unless title.includes?("partial")
    raise "nonzero incomplete title should preserve the count: #{title.inspect}" unless title.includes?("1")
  end

  it "keeps the partial marker visible at the minimum panel width" do
    match = Adamantine::ProjectSearch::Match.new(Path.new("/project/source.cr"), 0, 0, "needle")
    [([] of Adamantine::ProjectSearch::Match), [match]].each do |matches|
      harness = SearchPanelRenderSpecHarness.new("needle", 6)
      harness.set_project_results(matches, truncated: true)
      buffer = Tui::Buffer.new(24, 20)
      harness.render_project(buffer, Tui::Rect.new(0, 0, 24, 20))

      harness.row_text(buffer, 1).should contain("(partial)")
      buffer.get(23, 1).glyph.should eq("┐")
      if matches.empty?
        harness.row_text(buffer, 3).should contain("(partial)")
        buffer.get(23, 3).glyph.should eq("│")
      end
    end
  end

  it "keeps query-empty and searching states ahead of a stale partial marker" do
    empty = SearchPanelRenderSpecHarness.new("", 0)
    empty.set_project_results([] of Adamantine::ProjectSearch::Match, truncated: true)
    empty_buffer = Tui::Buffer.new(80, 24)
    empty.render_project(empty_buffer, Tui::Rect.new(0, 0, 80, 24))
    empty_title = empty.row_text(empty_buffer, 1)
    empty_message = empty.row_text(empty_buffer, 3)
    raise "empty query should not show a partial title: #{empty_title.inspect}" if empty_title.includes?("partial")
    raise "empty query should keep its prompt: #{empty_message.inspect}" unless empty_message.includes?("Type to search")

    searching = SearchPanelRenderSpecHarness.new("needle", 6)
    searching.set_project_results([] of Adamantine::ProjectSearch::Match, truncated: true, searching: true)
    searching_buffer = Tui::Buffer.new(80, 24)
    searching.render_project(searching_buffer, Tui::Rect.new(0, 0, 80, 24))
    searching_title = searching.row_text(searching_buffer, 1)
    searching_message = searching.row_text(searching_buffer, 3)
    raise "searching state should keep its ellipsis title: #{searching_title.inspect}" unless searching_title.includes?("...")
    raise "searching state should keep its message: #{searching_message.inspect}" unless searching_message.includes?("Searching...")
    raise "searching state should not show a partial title: #{searching_title.inspect}" if searching_title.includes?("partial")
  end
end
