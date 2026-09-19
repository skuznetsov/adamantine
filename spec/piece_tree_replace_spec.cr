require "spec"
require "crystal_tui"
require "../src/adamantine/piece_tree_replace"

describe "app-owned PieceTreeBuffer replacement seam" do
  it "replaces a range atomically across a CRLF-sensitive seam" do
    buffer = Tui::PieceTreeBuffer.new("\rX\n")

    buffer.replace_range_atomic(1, 1, "Y")

    buffer.text.should eq "\rY\n"
    buffer.validate!
  end

  it "preserves exact newline bytes for insertion and deletion" do
    cases = {
      {"a\n", 1, 1, "\r", "a\r"},
      {"\rX\n", 1, 1, "", "\r\n"},
      {"\rX\n", 1, 1, "\n", "\r\n\n"},
      {"one\r\ntwo\rthree\nfour", 5, 4, "é", "one\r\néthree\nfour"},
    }

    cases.each do |original, offset, length, replacement, expected|
      buffer = Tui::PieceTreeBuffer.new(original)
      buffer.replace_range_atomic(offset, length, replacement)
      buffer.text.should eq expected
      buffer.validate!
    end
  end

  it "rejects a range boundary inside a CRLF pair" do
    buffer = Tui::PieceTreeBuffer.new("a\r\nb")

    expect_raises(ArgumentError, /CRLF/) do
      buffer.replace_range_atomic(2, 0, "x")
    end

    buffer.text.should eq "a\r\nb"
  end

  it "isolates a fork, rolls it back by snapshot, and adopts it safely" do
    original_text = "before old\r\nold"
    buffer = Tui::PieceTreeBuffer.new(original_text)
    original = buffer.snapshot
    candidate = buffer.replace_fork

    candidate.replace_range_atomic(7, 3, "new")
    buffer.same_state?(original).should be_true
    buffer.text.should eq original_text
    candidate.text.should eq "before new\r\nold"

    candidate.restore(original)
    candidate.text.should eq original_text
    candidate.replace_range_atomic(7, 3, "new")
    buffer.adopt_replace_fork!(candidate)
    buffer.text.should eq "before new\r\nold"
    buffer.validate!
  end

  it "continues using the live buffer after candidate adoption" do
    buffer = Tui::PieceTreeBuffer.new("old")
    candidate = buffer.replace_fork
    candidate.replace_range_atomic(0, 3, "new")
    buffer.adopt_replace_fork!(candidate)

    buffer.insert(buffer.byte_length, "!")
    buffer.delete(buffer.byte_length - 1, 1)
    buffer.validate!
    buffer.text.should eq "new"
  end
end
