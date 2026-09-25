require "spec"
require "crystal_tui"
require "../src/adamantine/unicode_layout"

describe "parent streaming grapheme oracle" do
  it "does not allocate a new string for every ASCII cell in a deep cursor scan" do
    tree = Tui::PieceTreeBuffer.new("x" * 4_000_000)
    before = GC.stats.total_bytes
    Adamantine::UnicodeLayout.cell_offset_for_column(tree, 0, 4_000_000, 4).should eq(4_000_000)
    (GC.stats.total_bytes - before).should be < 32_000_000_u64
  end

  it "matches whole-string segmentation across many chunk boundaries" do
    text = "x" * 1023 + ("e\u0301👩‍💻🇺🇸👍🏽界\t" * 600) + "tail"
    tree = Tui::PieceTreeBuffer.new(text)
    expected = [] of {Int32, Int32, String}
    col = 0
    text.each_grapheme do |grapheme|
      value = grapheme.to_s
      expected << {col, col + value.size, value}
      col += value.size
    end
    actual = [] of {Int32, Int32, String}
    result = Adamantine::UnicodeLayout.each_cluster(tree, 0, 4) do |cluster|
      actual << {cluster.start_col, cluster.end_col, cluster.text}
      true
    end
    actual.should eq(expected)
    result.complete.should be_true
  end

  it "does not repeatedly copy a growing cluster across chunks" do
    text = "e" + "\u0301" * 128_000 + "x"
    tree = Tui::PieceTreeBuffer.new(text)
    first_end = 0
    before = GC.stats.total_bytes
    Adamantine::UnicodeLayout.each_cluster(tree, 0, 4) do |cluster|
      first_end = cluster.end_col
      false
    end
    allocated = GC.stats.total_bytes - before
    first_end.should eq(128_001)
    allocated.should be < 8_000_000_u64
  end
end
