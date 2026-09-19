require "spec"

require "../src/adamantine/buffer_replace"

private def buffer_replace_source(text : String) : Adamantine::BufferSearch::Source
  Adamantine::BufferSearch::Source.new(Tui::PieceTreeBuffer.new(text))
end

private def buffer_replace_matches(
  source : Adamantine::BufferSearch::Source,
  old_text : String,
  new_text : String,
  flags : Adamantine::ReplaceUtils::ReplaceFlags,
) : Array(Adamantine::BufferReplace::Match)
  matches = [] of Adamantine::BufferReplace::Match
  Adamantine::BufferReplace.each_match(source, old_text, new_text, flags) do |match|
    matches << match
  end
  matches
end

private class GuardedReplaceSource < Adamantine::BufferSearch::Source
  getter slice_calls : Int32 = 0

  def slice_codepoints(start : Int32, count : Int32) : String
    raise "replacement scanner requested an oversized chunk" if count > Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS
    @slice_calls += 1
    super
  end

  def to_s(io : IO) : Nil
    raise "replacement scanner must not materialize the source"
  end
end

describe Adamantine::BufferReplace do
  it "streams non-overlapping first and global matches with exact byte spans" do
    source = buffer_replace_source("aaaa")

    first = buffer_replace_matches(source, "aa", "X", Adamantine::ReplaceUtils::ReplaceFlags.new)
    global = buffer_replace_matches(source, "aa", "X", Adamantine::ReplaceUtils::ReplaceFlags.new(global: true))

    first.map { |match| {match.start_byte, match.end_byte, match.original, match.replacement} }.should eq [{0, 2, "aa", "X"}]
    global.map { |match| {match.start_byte, match.end_byte, match.original, match.replacement} }.should eq [
      {0, 2, "aa", "X"},
      {2, 4, "aa", "X"},
    ]
  end

  it "finds a match crossing a bounded chunk without losing original UTF-8 bytes" do
    prefix = "a" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS - 2)
    text = prefix + "🙂needle" + " tail"
    source = buffer_replace_source(text)
    matches = buffer_replace_matches(source, "🙂needle", "X", Adamantine::ReplaceUtils::ReplaceFlags.new)

    matches.size.should eq 1
    match = matches.first
    match.original.should eq "🙂needle"
    match.start_byte.should eq prefix.bytesize
    match.end_byte.should eq prefix.bytesize + "🙂needle".bytesize
    match.start_codepoint.should eq prefix.size
    match.end_codepoint.should eq prefix.size + "🙂needle".size
  end

  it "retains enough carry for queries spanning several chunks" do
    query = ("a" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS * 2 + 17)) + "b"
    source = buffer_replace_source("z" + query + "z")
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)

    matches = buffer_replace_matches(source, query, "X", flags)

    matches.map { |match| {match.start_byte, match.end_byte, match.original} }.should eq [{1, 1 + query.bytesize, query}]
  end

  it "keeps dense multibyte matches non-overlapping across chunk boundaries" do
    codepoints = Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS * 2 + 3
    text = "é" * codepoints
    source = buffer_replace_source(text)
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)

    matches = buffer_replace_matches(source, "éé", "X", flags)

    matches.size.should eq codepoints // 2
    matches.each_with_index do |match, index|
      match.start_codepoint.should eq index * 2
      match.start_byte.should eq index * "é".bytesize * 2
      match.end_byte.should eq match.start_byte + "éé".bytesize
    end
  end

  it "uses PCRE2 caseless semantics rather than String downcase" do
    source = buffer_replace_source("İißẞſsσςΣKKk")
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true, ignore_case: true)

    i_matches = buffer_replace_matches(source, "i", "X", flags)
    sharp_s_matches = buffer_replace_matches(source, "ß", "X", flags)
    long_s_matches = buffer_replace_matches(source, "s", "X", flags)
    sigma_matches = buffer_replace_matches(source, "σ", "X", flags)
    kelvin_matches = buffer_replace_matches(source, "k", "X", flags)

    i_matches.map(&.original).should eq ["i"]
    sharp_s_matches.map(&.original).should eq ["ß", "ẞ"]
    long_s_matches.map(&.original).should eq ["ſ", "s"]
    sigma_matches.map(&.original).should eq ["σ", "ς", "Σ"]
    kelvin_matches.map(&.original).should eq ["K", "K", "k"]
  end

  it "preserves Regex replacement backreferences only for ignore-case mode" do
    source = buffer_replace_source("old OLD")
    ignore_case = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true, ignore_case: true)
    sensitive = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)

    backrefs = buffer_replace_matches(source, "old", "\\0!", ignore_case)
    literal = buffer_replace_matches(source, "old", "\\0!", sensitive)

    backrefs.map(&.replacement).should eq ["old!", "OLD!"]
    literal.map(&.replacement).should eq ["\\0!"]
    expect_raises(IndexError) do
      buffer_replace_matches(source, "old", "\\k<missing>", ignore_case)
    end
  end

  it "keeps mixed CRLF, LF, and lone CR bytes independent" do
    text = "a\r\nb\nc\rd"
    source = buffer_replace_source(text)
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)

    crlf = buffer_replace_matches(source, "\r\n", "X", flags)
    lf = buffer_replace_matches(source, "\n", "X", flags)
    cr = buffer_replace_matches(source, "\r", "X", flags)

    crlf.map(&.original).should eq ["\r\n"]
    lf.map(&.original).should eq ["\n", "\n"]
    cr.map(&.original).should eq ["\r", "\r"]
    crlf.first.start_byte.should eq 1
    lf.first.start_byte.should eq 2
    lf.map(&.start_byte).should eq [2, 4]
    cr.map(&.start_byte).should eq [1, 6]
  end

  it "caps query and replacement arguments explicitly" do
    source = buffer_replace_source("x")
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new

    expect_raises(ArgumentError) do
      Adamantine::BufferReplace.each_match(source, "x" * (Adamantine::BufferReplace::MAX_QUERY_BYTES + 1), "y", flags) { }
    end
    expect_raises(ArgumentError) do
      Adamantine::BufferReplace.each_match(source, "x", "y" * (Adamantine::BufferReplace::MAX_REPLACEMENT_BYTES + 1), flags) { }
    end
    Adamantine::BufferReplace.each_match(source, "", "y" * (Adamantine::BufferReplace::MAX_REPLACEMENT_BYTES + 1), flags) { }.should eq 0
  end

  it "rejects explosive zero-backreference expansion before allocating it" do
    query = "a" * 4096
    source = buffer_replace_source(query)
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(ignore_case: true)

    expect_raises(ArgumentError, /expanded replacement/) do
      Adamantine::BufferReplace.each_match(source, query, "\\0" * 8193, flags) { }
    end
  end

  it "previews at most five occurrences even for first-only replacement" do
    source = buffer_replace_source("old old old old old old")
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new

    previews = Adamantine::BufferReplace.preview(source, "old", "new", flags, 100)

    previews.size.should eq 5
    previews.each_with_index do |preview, index|
      preview.should contain("#{index + 1}) @")
      preview.bytesize.should be < 400
    end
  end

  it "uses only bounded source slices for matching and preview" do
    buffer = Tui::PieceTreeBuffer.new(("a" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS * 3)) + "needle")
    source = GuardedReplaceSource.new(buffer)
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)

    matches = buffer_replace_matches(source, "needle", "X", flags)
    previews = Adamantine::BufferReplace.preview(source, "needle", "X", flags)

    matches.size.should eq 1
    previews.size.should eq 1
    source.slice_calls.should be > 1
  end
end
