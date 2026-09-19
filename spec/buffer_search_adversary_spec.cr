require "spec"
require "../src/adamantine/buffer_search"

# Deliberately simple, allocating oracle for small fixtures only. Match in the
# transformed string, then map every result back to the original characters.
private def reference_buffer_matches(text : String, query : String, ignore_case : Bool, overlap : Bool) : Array(Tuple(Int32, Int32, Int32))
  results = [] of Tuple(Int32, Int32, Int32)
  return results if query.empty? || query.includes?('\n') || query.includes?('\r')
  needle = (ignore_case ? query.downcase : query).chars
  text.split(/\r\n|\r|\n/).each_with_index do |line, line_index|
    characters = [] of Char
    original_columns = [] of Int32
    line.each_char.with_index do |character, column|
      transformed = ignore_case ? character.to_s.downcase : character.to_s
      transformed.each_char do |mapped|
        characters << mapped
        original_columns << column
      end
    end
    next_source_column = 0
    characters.size.times do |offset|
      next if offset + needle.size > characters.size
      next unless characters[offset, needle.size] == needle
      start_column = original_columns[offset]
      end_column = original_columns[offset + needle.size - 1] + 1
      next if !overlap && start_column < next_source_column
      span = {line_index, start_column, end_column}
      results << span unless results.last? == span
      next_source_column = end_column
    end
  end
  results
end

describe "Buffer search adversarial checks" do
  it "agrees with an allocating original-span oracle on randomized Unicode and line endings" do
    random = Random.new(573019_u64)
    alphabet = ["a", "A", "b", "İ", "i", "\u0307", "é", "🙂", "界", "\r", "\n"]
    queries = ["a", "aa", "i", "i\u0307", "\u0307", "🙂", "界", "absent", "a\nb"]
    60.times do
      text = Array.new(45) { alphabet[random.rand(alphabet.size)] }.join
      source = Adamantine::BufferSearch::Source.new(Tui::PieceTreeBuffer.new(text))
      [false, true].each do |ignore_case|
        queries.each do |query|
          expected = reference_buffer_matches(text, query, ignore_case, overlap: false)
          actual = Adamantine::BufferSearch.scan(source, query, ignore_case: ignore_case)
          actual.matches.map { |match| {match.line, match.col, match.end_col} }.should eq(expected)

          candidates = reference_buffer_matches(text, query, ignore_case, overlap: true)
          [{0, 0}, {1, 2}, {3, 0}].each do |line, col|
            [false, true].each do |forward|
              direct = if forward
                         candidates.find { |span| span[0] > line || (span[0] == line && span[1] > col) }
                       else
                         candidates.reverse.find { |span| span[0] < line || (span[0] == line && span[1] < col) }
                       end
              expected_match = direct || (forward ? candidates.first? : candidates.last?)
              result = Adamantine::BufferSearch.find_next(source, query, line, col, forward: forward, ignore_case: ignore_case)
              actual_match = result.match.try { |match| {match.line, match.col, match.end_col} }
              actual_match.should eq(expected_match)
              result.wrapped?.should eq(!expected_match.nil? && direct.nil?)
              result.cancelled?.should be_false
            end
          end
        end
      end
    end
  end

  it "keeps source roots stable across append-page growth and replacement" do
    buffer = Tui::PieceTreeBuffer.new("seed")
    buffer.insert(buffer.byte_length, "needle")
    source = Adamantine::BufferSearch::Source.new(buffer)
    100.times { buffer.insert(buffer.byte_length, " later needle") }
    buffer.replace_all("replacement")

    result = Adamantine::BufferSearch.scan(source, "needle")
    result.matches.map { |match| {match.line, match.col, match.end_col} }.should eq([{0, 4, 10}])
    source.byte_length.should eq(10)
  end

  it "keeps CRLF a single boundary when the chunk ends between its bytes" do
    prefix = "x" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS - 1)
    source = Adamantine::BufferSearch::Source.new(Tui::PieceTreeBuffer.new(prefix + "\r\nİneedle"))
    result = Adamantine::BufferSearch.scan(source, "needle")
    result.matches.map { |match| {match.line, match.col, match.end_col} }.should eq([{1, 1, 7}])
  end

  it "trims CRLF overreads by bytes even when a chunk contains multibyte characters" do
    prefix = "界" * (Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS - 1)
    source = Adamantine::BufferSearch::Source.new(Tui::PieceTreeBuffer.new(prefix + "\r\nneedle"))
    source.slice_codepoints(0, Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS).should eq(prefix + "\r")
    source.slice_codepoints(Adamantine::BufferSearch::SCAN_CHUNK_CODEPOINTS, 2).should eq("\nn")
    result = Adamantine::BufferSearch.scan(source, "needle")
    result.matches.map { |match| {match.line, match.col, match.end_col} }.should eq([{1, 0, 6}])
  end
end
