require "spec"

require "../src/adamantine/buffer_search"

private def buffer_search_source(text : String) : Adamantine::BufferSearch::Source
  Adamantine::BufferSearch::Source.new(Tui::PieceTreeBuffer.new(text))
end

private def buffer_search_match_starts(result : Adamantine::BufferSearch::ScanResult) : Array(Tuple(Int32, Int32))
  result.matches.map { |match| {match.line, match.col} }
end

describe Adamantine::BufferSearch do
  it "reads bounded codepoint chunks and finds matches across chunk boundaries" do
    prefix = "a" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS - 2)
    text = prefix + "needle" + " tail"
    source = buffer_search_source(text)

    result = Adamantine::BufferSearch.scan(source, "needle", path: Path.new("buffer.cr"))

    result.matches.size.should eq 1
    result.matches[0].line.should eq 0
    result.matches[0].col.should eq prefix.each_char.size
    result.matches[0].end_col.should eq prefix.each_char.size + 6
    result.matches[0].snippet.each_grapheme.size.should be <= Adamantine::ProjectSearch::SNIPPET_MAX
    result.truncated?.should be_false
    result.cancelled?.should be_false
  end

  it "handles huge single lines without materializing a logical line" do
    prefix = "x" * 200_000
    source = buffer_search_source(prefix + "needle" + "suffix")

    result = Adamantine::BufferSearch.scan(source, "needle", path: Path.new("large.cr"))

    result.matches.size.should eq 1
    result.matches[0].col.should eq 200_000
    result.matches[0].end_col.should eq 200_006
    result.matches[0].snippet.bytesize.should be <= Adamantine::ProjectSearch::SNIPPET_MAX * 4
  end

  it "matches long repeated prefixes across cooperative chunks" do
    query = ("a" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS - 1)) + "b"
    source = buffer_search_source(("a" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS * 4)) + query + "z")
    checkpoints = 0

    result = Adamantine::BufferSearch.scan(source, query, checkpoint: -> do
      checkpoints += 1
      true
    end)

    result.matches.map { |match| {match.line, match.col} }.should eq [{0, Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS * 4}]
    checkpoints.should be > 1
    result.cancelled?.should be_false
  end

  it "trims a CRLF overread without corrupting a UTF-8 chunk" do
    prefix = "🙂" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS - 1)
    source = buffer_search_source(prefix + "\r\nneedle")

    result = Adamantine::BufferSearch.scan(source, "needle")

    result.matches.map { |match| {match.line, match.col} }.should eq [{1, 0}]
  end

  it "preserves logical LF, CRLF, and CR line coordinates" do
    source = buffer_search_source("zero\r\none\rtwo\nthree")

    result = Adamantine::BufferSearch.scan(source, "o", path: Path.new("mixed.txt"))

    buffer_search_match_starts(result).should eq [{0, 3}, {1, 0}, {2, 2}]
  end

  it "reports original codepoint coordinates for UTF-8 text" do
    source = buffer_search_source("éx🙂x")

    result = Adamantine::BufferSearch.scan(source, "x", path: Path.new("unicode.txt"))

    buffer_search_match_starts(result).should eq [{0, 1}, {0, 3}]
    result.matches.map(&.end_col).should eq [2, 4]
  end

  it "supports ASCII case-insensitive search without changing source coordinates" do
    source = buffer_search_source("Alpha ALPHA alpha")

    result = Adamantine::BufferSearch.scan(source, "alpha", ignore_case: true)

    buffer_search_match_starts(result).should eq [{0, 0}, {0, 6}, {0, 12}]
  end

  it "maps length-changing lowercase expansions to whole source spans" do
    source = buffer_search_source("İx")

    one = Adamantine::BufferSearch.scan(source, "i", ignore_case: true)
    two = Adamantine::BufferSearch.scan(source, "i\u0307", ignore_case: true)
    dot = Adamantine::BufferSearch.scan(source, "\u0307", ignore_case: true)

    [one, two, dot].each do |result|
      result.matches.size.should eq 1
      result.matches[0].col.should eq 0
      result.matches[0].end_col.should eq 1
    end
  end

  it "does not match across logical line endings or accept multiline queries" do
    source = buffer_search_source("ab\r\ncd\ref")

    crossing = Adamantine::BufferSearch.scan(source, "bcd")
    multiline = Adamantine::BufferSearch.scan(source, "b\nc")

    crossing.matches.should be_empty
    multiline.matches.should be_empty
  end

  it "caps live results while retaining a partial signal" do
    source = buffer_search_source(("x\n" * 205))

    result = Adamantine::BufferSearch.scan(source, "x", max_matches: 200)

    result.matches.size.should eq 200
    result.truncated?.should be_true
    result.cancelled?.should be_false
  end

  it "cancels at cooperative checkpoints and lets another fiber run" do
    source = buffer_search_source("a" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS * 8))
    progress = 0
    spawn do
      100.times do
        progress += 1
        Fiber.yield
      end
    end

    checkpoints = 0
    result = Adamantine::BufferSearch.scan(source, "missing", checkpoint: -> do
      checkpoints += 1
      checkpoints < 3
    end)

    result.matches.should be_empty
    result.cancelled?.should be_true
    checkpoints.should be >= 3
    progress.should be > 0
  end

  it "keeps a source snapshot stable when the live buffer changes" do
    buffer = Tui::PieceTreeBuffer.new("before")
    source = Adamantine::BufferSearch::Source.new(buffer)
    buffer.replace_all("after")

    result = Adamantine::BufferSearch.scan(source, "before")

    result.matches.size.should eq 1
    result.matches[0].col.should eq 0
  end

  it "finds repeat matches beyond the live result cap and wraps on one line" do
    source = buffer_search_source(("x" * 205))

    forward = Adamantine::BufferSearch.find_next(source, "x", 0, 204, forward: true)
    backward = Adamantine::BufferSearch.find_next(source, "x", 0, 0, forward: false)

    forward.match.not_nil!.col.should eq 0
    forward.wrapped?.should be_true
    backward.match.not_nil!.col.should eq 204
    backward.wrapped?.should be_true
    forward.cancelled?.should be_false
    backward.cancelled?.should be_false
  end

  it "finds forward and backward repeats in original coordinates" do
    source = buffer_search_source("éx🙂x\nxx")

    forward = Adamantine::BufferSearch.find_next(source, "x", 0, 1, forward: true)
    backward = Adamantine::BufferSearch.find_next(source, "x", 1, 0, forward: false)

    forward.match.not_nil!.col.should eq 3
    forward.wrapped?.should be_false
    backward.match.not_nil!.line.should eq 0
    backward.match.not_nil!.col.should eq 3
    backward.wrapped?.should be_false
  end

  it "reports cancellation separately for repeat search" do
    source = buffer_search_source("x" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS * 4))
    result = Adamantine::BufferSearch.find_next(source, "x", 0, 0, forward: true, checkpoint: -> { false })

    result.match.should be_nil
    result.cancelled?.should be_true
    result.wrapped?.should be_false
  end
end
