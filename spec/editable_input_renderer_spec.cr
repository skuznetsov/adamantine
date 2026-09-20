require "spec"
require "crystal_tui"

require "../src/adamantine/editable_input_renderer"

private def render_editable_input(
  value : String,
  width : Int32,
  cursor : Int32? = nil,
  selection : Bool = false,
) : Tui::Buffer
  input = Adamantine::EditableInput.new(value)
  input.cursor = cursor.not_nil! if cursor
  if selection
    input.select_all
  end

  buffer = Tui::Buffer.new(width, 1)
  Adamantine::EditableInputRenderer.render(
    buffer,
    Tui::Rect.new(0, 0, width, 1),
    input,
    Tui::Style.new(fg: Tui::Color.white),
    Tui::Style.new(fg: Tui::Color.black, bg: Tui::Color.yellow),
    Tui::Style.new(fg: Tui::Color.black, bg: Tui::Color.cyan),
  )
  buffer
end

private def assert_no_half_wide_glyph(buffer : Tui::Buffer) : Nil
  buffer.width.times do |x|
    cell = buffer.get(x, 0)
    if cell.continuation?
      raise "continuation cell at #{x} has no in-viewport lead" unless x > 0 && buffer.get(x - 1, 0).wide?
    elsif cell.wide?
      raise "wide lead at #{x} is missing its continuation" unless x + 1 < buffer.width && buffer.get(x + 1, 0).continuation?
    end
  end
end

describe Adamantine::EditableInputRenderer do
  it "uses grapheme display widths and never splits CJK, emoji, or combining text" do
    value = "A中e\u0301🙂Z"

    [1, 2, 3].each do |width|
      buffer = render_editable_input(value, width, value.size)
      assert_no_half_wide_glyph(buffer)
    end

    buffer = render_editable_input(value, 3, 0)
    buffer.get(0, 0).glyph.should eq("A")
    buffer.get(0, 0).style.bg.should eq(Tui::Color.cyan)
    buffer.get(1, 0).glyph.should eq("中")
    buffer.get(2, 0).continuation?.should be_true

    buffer = render_editable_input(value, 3, 1)
    buffer.get(0, 0).style.bg.should_not eq(Tui::Color.cyan)
    buffer.get(0, 0).glyph.should eq("A")
    buffer.get(1, 0).style.bg.should eq(Tui::Color.cyan)
    buffer.get(2, 0).continuation?.should be_true
  end

  it "keeps the cursor visible at the start, middle, and end of a scrolled line" do
    value = "abc中def"

    start = render_editable_input(value, 3, 0)
    start.get(0, 0).style.bg.should eq(Tui::Color.cyan)

    middle = render_editable_input(value, 3, 3)
    (0...middle.width).any? { |x| middle.get(x, 0).style.bg == Tui::Color.cyan }.should be_true

    ending = render_editable_input(value, 3, value.size)
    (0...ending.width).any? { |x| ending.get(x, 0).style.bg == Tui::Color.cyan }.should be_true
  end

  it "applies selection style to each selected grapheme and all wide cells" do
    input = Adamantine::EditableInput.new("A中e\u0301B")
    input.move_home
    input.move_right
    input.move_right(extend_selection: true)
    input.move_right(extend_selection: true)

    buffer = Tui::Buffer.new(8, 1)
    text_style = Tui::Style.new(fg: Tui::Color.white)
    selection_style = Tui::Style.new(fg: Tui::Color.black, bg: Tui::Color.yellow)
    cursor_style = Tui::Style.new(fg: Tui::Color.black, bg: Tui::Color.cyan)
    Adamantine::EditableInputRenderer.render(
      buffer,
      Tui::Rect.new(0, 0, 8, 1),
      input,
      text_style,
      selection_style,
      cursor_style,
    )

    buffer.get(0, 0).style.should eq(text_style)
    buffer.get(1, 0).style.should eq(selection_style)
    buffer.get(2, 0).style.should eq(selection_style)
    buffer.get(3, 0).style.should eq(selection_style)
    buffer.get(4, 0).style.should eq(cursor_style)
    buffer.get(5, 0).style.should eq(text_style)
  end

  it "draws a visible cursor for an empty input" do
    buffer = render_editable_input("", 1)
    buffer.get(0, 0).style.bg.should eq(Tui::Color.cyan)
    buffer.get(0, 0).glyph.should eq(" ")
  end

  it "repaints an intersecting partial clip without touching neighboring cells" do
    input = Adamantine::EditableInput.new("abcd")
    buffer = Tui::Buffer.new(6, 1)
    outside = Tui::Style.new(bg: Tui::Color.red)
    6.times { |x| buffer.set(x, 0, 'x', outside) }

    Adamantine::EditableInputRenderer.render(
      buffer,
      Tui::Rect.new(0, 0, 6, 1),
      input,
      clip: Tui::Rect.new(2, 0, 2, 1),
    )

    buffer.get(0, 0).style.should eq(outside)
    buffer.get(1, 0).style.should eq(outside)
    buffer.get(2, 0).glyph.should eq("c")
    buffer.get(3, 0).glyph.should eq("d")
    buffer.get(4, 0).style.should eq(outside)
  end

  it "does not split a pre-existing wide cell at a partial clip boundary" do
    input = Adamantine::EditableInput.new("abcd")
    wide_style = Tui::Style.new(bg: Tui::Color.red)

    [1, 2].each do |clip_x|
      buffer = Tui::Buffer.new(4, 1)
      buffer.set(1, 0, Tui::Cell.text("中", wide_style, wide: true))
      buffer.set(2, 0, Tui::Cell.continuation(wide_style))

      Adamantine::EditableInputRenderer.render(
        buffer,
        Tui::Rect.new(0, 0, 4, 1),
        input,
        clip: Tui::Rect.new(clip_x, 0, 1, 1),
      )

      buffer.get(1, 0).wide?.should be_true
      buffer.get(2, 0).continuation?.should be_true
      assert_no_half_wide_glyph(buffer)
    end
  end
end
