module Adamantine
  module Folding
    STANDARD_KIND_HINT = "region"

    def self.parse_ranges(raw : JSON::Any?) : Array(Tui::TextEditor::FoldRange)
      return [] of Tui::TextEditor::FoldRange unless raw
      return [] of Tui::TextEditor::FoldRange if raw.raw.nil?

      items = raw.as_a?
      return [] of Tui::TextEditor::FoldRange unless items

      ranges = [] of Tui::TextEditor::FoldRange
      items.each do |item|
        start_line = item["startLine"]?.try(&.as_i?)
        end_line = item["endLine"]?.try(&.as_i?)
        next unless start_line && end_line
        next unless end_line > start_line
        next if start_line < 0
        ranges << Tui::TextEditor::FoldRange.new(start_line, end_line)
      end
      ranges
    end

    def self.supported?(capabilities : JSON::Any?) : Bool
      return false unless capabilities
      provider = capabilities["foldingRangeProvider"]?
      return false if provider.nil? || provider.raw.nil?
      return false if provider.as_bool? == false
      true
    end

    # Adamas/Crystal LSP folds the whole `if…end`, but not `else`/`elsif`/`when`.
    # Keep the closer (`end` / next branch) visible.
    def self.merge_crystal_branches(lines : Array(String), ranges : Array(Tui::TextEditor::FoldRange)) : Array(Tui::TextEditor::FoldRange)
      merged = ranges.dup
      starts = {} of Int32 => Int32
      merged.each_with_index do |range, index|
        starts[range.start_line] = index
      end

      lines.each_with_index do |line, start_line|
        next unless crystal_branch_header?(line)
        end_line = crystal_branch_end_line(lines, start_line, leading_indent(line))
        next unless end_line > start_line

        if existing_index = starts[start_line]?
          current_end = merged[existing_index].end_line
          tighter = Math.min(current_end, end_line)
          merged[existing_index] = Tui::TextEditor::FoldRange.new(start_line, tighter)
        else
          starts[start_line] = merged.size
          merged << Tui::TextEditor::FoldRange.new(start_line, end_line)
        end
      end

      merged
    end

    private def self.crystal_branch_header?(line : String) : Bool
      return false if comment_only?(line)
      !!(line =~ /\A\s*(elsif|else|when|in|rescue|ensure)\b/)
    end

    private def self.crystal_branch_end_line(lines : Array(String), start_line : Int32, indent : Int32) : Int32
      ((start_line + 1)...lines.size).each do |index|
        candidate = lines[index]
        next if candidate.strip.empty?
        next if comment_only?(candidate)
        return index - 1 if leading_indent(candidate) <= indent
      end
      lines.size - 1
    end

    private def self.comment_only?(line : String) : Bool
      !!(line =~ /\A\s*#/)
    end

    private def self.leading_indent(line : String) : Int32
      count = 0
      line.each_char do |char|
        break unless char.whitespace?
        count += 1
      end
      count
    end
  end
end
