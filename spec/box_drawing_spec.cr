require "spec"
require "crystal_tui"

require "../src/adamantine/box_drawing"

private class BoxDrawingSpecHarness
  include Adamantine::BoxDrawing

  def draw_line(buffer : Tui::Buffer, text : String, max_width : Int32) : Nil
    draw_text_line(buffer, Tui::Rect.new(0, 0, buffer.width, buffer.height), 0, 0, text, Tui::Style.default, max_width)
  end

  def draw_box_title(buffer : Tui::Buffer, title : String) : Nil
    clip = Tui::Rect.new(0, 0, buffer.width, buffer.height)
    style = Tui::Style.default
    draw_box_border(buffer, clip, 0, 0, buffer.width, buffer.height, style, style, title, style)
  end
end

describe Adamantine::BoxDrawing do
  it "advances text by display cells for CJK characters" do
    buffer = Tui::Buffer.new(8, 1)
    BoxDrawingSpecHarness.new.draw_line(buffer, "A中B", 5)

    buffer.get(0, 0).glyph.should eq("A")
    buffer.get(1, 0).glyph.should eq("中")
    buffer.get(1, 0).wide?.should be_true
    buffer.get(2, 0).continuation?.should be_true
    buffer.get(3, 0).glyph.should eq("B")
  end

  it "keeps emoji and following text out of the continuation cell" do
    buffer = Tui::Buffer.new(8, 1)
    BoxDrawingSpecHarness.new.draw_line(buffer, "😀A", 4)

    buffer.get(0, 0).glyph.should eq("😀")
    buffer.get(0, 0).wide?.should be_true
    buffer.get(1, 0).continuation?.should be_true
    buffer.get(2, 0).glyph.should eq("A")
  end

  it "renders combining sequences as one grapheme cell" do
    buffer = Tui::Buffer.new(8, 1)
    BoxDrawingSpecHarness.new.draw_line(buffer, "e\u0301X", 3)

    buffer.get(0, 0).glyph.should eq("e\u0301")
    buffer.get(1, 0).glyph.should eq("X")
    buffer.get(2, 0).glyph.should eq(" ")
  end

  it "advances a box title by display cells" do
    buffer = Tui::Buffer.new(8, 3)
    BoxDrawingSpecHarness.new.draw_box_title(buffer, "A中B")

    buffer.get(1, 0).glyph.should eq("A")
    buffer.get(2, 0).glyph.should eq("中")
    buffer.get(2, 0).wide?.should be_true
    buffer.get(3, 0).continuation?.should be_true
    buffer.get(4, 0).glyph.should eq("B")
    buffer.get(7, 0).glyph.should eq("┐")
  end
end
