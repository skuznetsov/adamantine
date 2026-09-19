require "spec"
require "crystal_tui"

require "../src/adamantine/text_coordinates"

private class CoordinateLineEditor < Tui::TextEditor
  include Adamantine::TextCoordinates::LineProvider

  def line_text(line : Int32) : String
    lines[line]
  end
end

describe Adamantine::TextCoordinates do
  it "converts codepoint columns to UTF-16 columns after an emoji" do
    line = "a🙂b"
    Adamantine::TextCoordinates.codepoint_to_utf16(line, 0).should eq 0
    Adamantine::TextCoordinates.codepoint_to_utf16(line, 1).should eq 1
    Adamantine::TextCoordinates.codepoint_to_utf16(line, 2).should eq 3
    Adamantine::TextCoordinates.codepoint_to_utf16(line, 3).should eq 4
  end

  it "converts UTF-16 columns back to codepoints and rejects a surrogate interior" do
    line = "a🙂b"
    Adamantine::TextCoordinates.utf16_to_codepoint(line, 0).should eq 0
    Adamantine::TextCoordinates.utf16_to_codepoint(line, 1).should eq 1
    Adamantine::TextCoordinates.utf16_to_codepoint(line, 3).should eq 2
    Adamantine::TextCoordinates.utf16_to_codepoint(line, 4).should eq 3
    expect_raises(ArgumentError) do
      Adamantine::TextCoordinates.utf16_to_codepoint(line, 2)
    end
  end

  it "rejects negative and oversized mutation coordinates" do
    line = "a🙂b"
    expect_raises(ArgumentError) { Adamantine::TextCoordinates.codepoint_to_utf16(line, -1) }
    expect_raises(ArgumentError) { Adamantine::TextCoordinates.codepoint_to_utf16(line, 4) }
    expect_raises(ArgumentError) { Adamantine::TextCoordinates.utf16_to_codepoint(line, -1) }
    expect_raises(ArgumentError) { Adamantine::TextCoordinates.utf16_to_codepoint(line, 5) }
  end

  it "clamps only oversized read-only navigation to the line end" do
    line = "a🙂b"
    Adamantine::TextCoordinates.utf16_to_codepoint(line, 99, clamp: true).should eq 3
    expect_raises(ArgumentError) do
      Adamantine::TextCoordinates.utf16_to_codepoint(line, 2, clamp: true)
    end
  end

  it "uses the editor's one-line adapter rather than requiring a document snapshot" do
    editor = CoordinateLineEditor.new("coordinate-editor")
    editor.text = "a🙂b\nnext"
    Adamantine::TextCoordinates.codepoint_to_utf16(editor, 0, 2).should eq 3
    Adamantine::TextCoordinates.utf16_to_codepoint(editor, 0, 3).should eq 2
  end
end
