require "spec"
require "../src/adamantine/editing_text_editor"
require "../src/adamantine/folding"
require "../src/adamantine/semantic_tokens"

# Deliberately simple old forward-scan oracle, independent of the streaming
# implementation. Branch closers stay visible; blank/comment lines do not close.
private def reference_branch_folds(lines : Array(String), ranges : Array(Tui::TextEditor::FoldRange))
  result = ranges.map { |range| {range.start_line, range.end_line} }
  lines.each_with_index do |line, start|
    next unless line =~ /\A\s*(elsif|else|when|in|rescue|ensure)\b/
    indent = line.chars.take_while(&.whitespace?).size
    finish = lines.size - 1
    ((start + 1)...lines.size).each do |index|
      candidate = lines[index]
      next if candidate.strip.empty? || candidate =~ /\A\s*#/
      if candidate.chars.take_while(&.whitespace?).size <= indent
        finish = index - 1
        break
      end
    end
    next unless finish > start
    if existing = result.rindex { |range| range[0] == start }
      result[existing] = {start, Math.min(result[existing][1], finish)}
    else
      result << {start, finish}
    end
  end
  result.sort
end

describe "LSP post-processing reference comparisons" do
  it "preserves branch folds across randomized indentation and existing ranges" do
    random = Random.new(7721)
    tokens = ["else", "elsif ready", "when 1", "in pattern", "rescue", "ensure", "end", "puts 界", "# else", "", "   "]
    120.times do
      lines = Array.new(random.rand(1..120)) { (" " * random.rand(0..8)) + tokens[random.rand(tokens.size)] }
      ranges = [] of Tui::TextEditor::FoldRange
      5.times do
        start = random.rand(lines.size)
        ranges << Tui::TextEditor::FoldRange.new(start, lines.size - 1) if start < lines.size - 1
      end
      editor = Adamantine::EditingTextEditor.new("fold-oracle")
      editor.load_content_as_saved(lines.join("\r\n"))
      actual = Adamantine::Folding.merge_crystal_branches(editor.lsp_line_source, ranges)
      actual.map { |range| {range.start_line, range.end_line} }.sort.should eq(reference_branch_folds(lines, ranges))
    end
  end

  it "retains source bytes and final empty lines across mixed newline boundaries" do
    ["", "\r", "\n", "\r\n", "\r\r\n", "🙂\r\n界\ré\n", "a" * 65_535 + "\r\n🙂"].each do |text|
      editor = Adamantine::EditingTextEditor.new("line-oracle")
      editor.load_content_as_saved(text)
      expected = editor.lines
      source = editor.lsp_line_source
      actual = [] of String
      lengths = [] of Int32
      source.each_line { |line, _| actual << line }
      source.each_line_length { |length, _| lengths << length }
      actual.should eq(expected)
      lengths.should eq(expected.map(&.size))
    end
  end
end
