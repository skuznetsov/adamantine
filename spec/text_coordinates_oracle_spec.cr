require "spec"
require "../src/adamantine/text_coordinates"
require "../src/adamantine/semantic_tokens"
require "../src/adamantine/editing_text_editor"

describe "parent UTF-16 coordinate oracle" do
  it "keeps runtime editor adapters strict rather than silently clamping" do
    editor = Adamantine::EditingTextEditor.new("strict-coordinates")
    editor.text = "🙂a\r\n界"
    Adamantine::TextCoordinates.codepoint_to_utf16(editor, 0, 1).should eq(2)
    Adamantine::TextCoordinates.utf16_to_codepoint(editor, 0, 2).should eq(1)
    [{-1, 0}, {2, 0}, {0, -1}, {0, 3}, {1, 2}].each do |line, column|
      expect_raises(ArgumentError) { Adamantine::TextCoordinates.codepoint_to_utf16(editor, line, column) }
    end
    [{-1, 0}, {2, 0}, {0, -1}, {0, 1}, {0, 4}, {1, 2}].each do |line, column|
      expect_raises(ArgumentError) { Adamantine::TextCoordinates.utf16_to_codepoint(editor, line, column) }
    end
  end

  it "roundtrips every boundary and rejects every surrogate interior in seeded lines" do
    random = Random.new(984_320_u64)
    alphabet = ['a', '\t', '界', 'é', '\u0301', '🙂', '👩', '\u200d', '💻', '🇺', '🇸']
    100.times do
      chars = Array.new(random.rand(1..90)) { alphabet[random.rand(alphabet.size)] }
      line = chars.join
      units = 0
      chars.each_with_index do |char, cp|
        Adamantine::TextCoordinates.codepoint_to_utf16(line, cp).should eq(units)
        Adamantine::TextCoordinates.utf16_to_codepoint(line, units).should eq(cp)
        if char.ord > 0xffff
          interior = units + 1
          expect_raises(ArgumentError) { Adamantine::TextCoordinates.utf16_to_codepoint(line, interior) }
        end
        units += char.ord > 0xffff ? 2 : 1
      end
      Adamantine::TextCoordinates.codepoint_to_utf16(line, chars.size).should eq(units)
      Adamantine::TextCoordinates.utf16_to_codepoint(line, units).should eq(chars.size)
      Adamantine::TextCoordinates.utf16_to_codepoint(line, Int32::MAX, clamp: true).should eq(chars.size)
    end
  end

  it "paints codepoint rows from UTF-16 semantic spans on multiple lines" do
    lines = ["🙂a界e\u0301", "👩‍💻tail"]
    data = [0, 2, 2, 15, 0, 1, 5, 4, 8, 0]
    overlay = Adamantine::SemanticOverlay.build(data, lines, Adamantine::SemanticOverlay::STANDARD_LEGEND)
    overlay.name_at(0, 0).should be_nil
    overlay.name_at(0, 1).should eq("keyword")
    overlay.name_at(0, 2).should eq("keyword")
    overlay.name_at(0, 3).should be_nil
    overlay.name_at(1, 2).should be_nil
    (3..6).each { |cp| overlay.name_at(1, cp).should eq("variable") }
    overlay.name_at(1, 7).should be_nil
  end

  it "does not crash or wrap coordinates for hostile semantic deltas" do
    data = [Int32::MAX, Int32::MAX, Int32::MAX, 15, 0, 1, 1, 1, 15, 0]
    overlay = Adamantine::SemanticOverlay.build(data, ["small"], Adamantine::SemanticOverlay::STANDARD_LEGEND)
    overlay.any_tokens?.should be_false
  end
end
