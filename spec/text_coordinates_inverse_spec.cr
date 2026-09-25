require "spec"
require "../src/adamantine/editing_text_editor"

private class NoLineCopyEditor < Adamantine::EditingTextEditor
  def line_text(line : Int32) : String
    raise "coordinate conversion must not copy a line"
  end
end

describe "inverse editor coordinates" do
  it "matches the string oracle without materializing Unicode lines" do
    ["", "ascii\ttext", "🙂a👩\u200d💻e\u0301", "中文🙂"].each do |line|
      editor = NoLineCopyEditor.new("inverse")
      editor.text = line
      maximum = Adamantine::TextCoordinates.codepoint_to_utf16(line, line.size)
      [false, true].each do |clamp|
        (-1..maximum + 1).each do |column|
          expected = begin
            Adamantine::TextCoordinates.utf16_to_codepoint(line, column, clamp: clamp)
          rescue ArgumentError
            nil
          end
          if expected
            Adamantine::TextCoordinates.utf16_to_codepoint(editor, 0, column, clamp: clamp).should eq expected
          else
            expect_raises(ArgumentError) { Adamantine::TextCoordinates.utf16_to_codepoint(editor, 0, column, clamp: clamp) }
          end
        end
      end
      expect_raises(ArgumentError) { Adamantine::TextCoordinates.utf16_to_codepoint(editor, 1, 0) }
    end
  end

  it "converts a multi-megabyte line without a line copy" do
    editor = NoLineCopyEditor.new("large-inverse")
    editor.text = "a" * 2_000_000 + "🙂z"
    100.times do
      Adamantine::TextCoordinates.utf16_to_codepoint(editor, 0, 2_000_002).should eq 2_000_001
    end
  end

  it "tracks fragmented edited lines and CRLF boundaries" do
    editor = NoLineCopyEditor.new("edited-inverse")
    editor.text = "first\r\na🙂b\r\nlast"
    editor.set_cursor(1, 1)
    editor.insert_text("界👩")
    line = "a界👩🙂b"
    (0..line.size).each do |column|
      units = Adamantine::TextCoordinates.codepoint_to_utf16(line, column)
      Adamantine::TextCoordinates.utf16_to_codepoint(editor, 1, units).should eq column
    end
    editor.undo
    Adamantine::TextCoordinates.utf16_to_codepoint(editor, 1, 3).should eq 2
  end
end
