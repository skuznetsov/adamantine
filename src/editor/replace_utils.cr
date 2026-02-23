module CrystalEditor
  module ReplaceUtils
    struct ReplaceFlags
      property global : Bool
      property ignore_case : Bool
      property preview : Bool

      def initialize(@global : Bool = false, @ignore_case : Bool = false, @preview : Bool = false)
      end
    end

    def self.parse_replace_arguments(argument_text : String) : Tuple(String, String, ReplaceFlags)?
      text = argument_text.strip
      return nil if text.empty?
      return nil unless text.starts_with?("/")

      pair_and_remaining = parse_delimited_pair(text[1..], '/')
      return nil if pair_and_remaining.nil?

      old_text, new_text, remaining = pair_and_remaining
      flags = parse_replace_flags(remaining)
      return nil if flags.nil?
      {old_text, new_text, flags}
    end

    def self.parse_replace_flags(remaining : String) : ReplaceFlags?
      flags = ReplaceFlags.new
      return flags if remaining.empty?

      remaining.each_char do |ch|
        case ch
        when 'g'
          flags.global = true
        when 'i'
          flags.ignore_case = true
        when 'c'
          flags.preview = true
        when .whitespace?
          # ignore spaces
        else
          return nil
        end
      end
      flags
    end

    def self.parse_delimited_pair(text : String, delimiter : Char) : Tuple(String, String, String)?
      state = 0
      escaped = false
      first = String::Builder.new
      second = String::Builder.new
      index = 0
      chars = text.chars

      while index < chars.size
        ch = chars[index]
        if escaped
          if state == 0
            first << ch
          else
            second << ch
          end
          escaped = false
          index += 1
          next
        end

        if ch == '\\'
          escaped = true
          index += 1
          next
        end

        if ch == delimiter
          if state == 0
            state = 1
            index += 1
            next
          elsif state == 1
            remaining = chars[(index + 1)..-1].try(&.join) || ""
            return {first.to_s, second.to_s, remaining}
          end
        end

        if state == 0
          first << ch
        elsif state == 1
          second << ch
        end

        index += 1
      end

      nil
    end

    def self.replace_text_content(text : String, old_text : String, new_text : String, flags : ReplaceFlags) : String
      return text if old_text.empty?
      if flags.ignore_case
        pattern = replace_pattern(old_text, true)
        return flags.global ? text.gsub(pattern, new_text) : text.sub(pattern, new_text)
      end

      flags.global ? text.gsub(old_text, new_text) : text.sub(old_text, new_text)
    end

    def self.replace_match_count(text : String, old_text : String, flags : ReplaceFlags) : Int32
      return 0 if old_text.empty?

      match_positions(text, old_text, flags).size
    end

    def self.make_replace_previews(text : String, old_text : String, new_text : String, limit : Int32, flags : ReplaceFlags) : Array(String)
      return [] of String if limit <= 0

      positions = match_positions(text, old_text, flags, limit)
      positions.map_with_index do |position, index|
        line_number, column, line = match_line_info(text, position)
        matched = old_text.size > 0 ? text[position, old_text.size] : old_text
        line_with_match = highlight_match_in_line(line, column, matched)
        line_preview = format_preview_line(line_with_match)
        "#{index + 1}) L#{line_number}:#{column} #{line_preview} (#{matched.inspect} -> #{new_text.inspect})"
      end
    end

    def self.flags_to_label(flags : ReplaceFlags) : String
      if !flags.global && !flags.ignore_case
        "single"
      elsif !flags.global && flags.ignore_case
        "first (ignore case)"
      elsif flags.global && !flags.ignore_case
        "all (global)"
      else
        "all (global, ignore case)"
      end
    end

    private def self.match_positions(text : String, old_text : String, flags : ReplaceFlags, limit : Int32 = Int32::MAX) : Array(Int32)
      return [] of Int32 if old_text.empty?

      positions = [] of Int32
      if flags.ignore_case
        pattern = replace_pattern(old_text, true)
        offset = 0
        while offset < text.size
          slice = text[offset, text.size - offset]
          match = pattern.match(slice)
          break if match.nil?
          position = offset + match.not_nil!.begin
          positions << position
          offset = position + old_text.size
          break if positions.size >= limit
        end
      else
        offset = 0
        while (position = text.index(old_text, offset))
          positions << position
          offset = position + old_text.size
          break if positions.size >= limit
        end
      end
      positions
    end

    private def self.match_line_info(text : String, position : Int32) : Tuple(Int32, Int32, String)
      line_number = text[0, position].count('\n') + 1
      line_start = (text.rindex('\n', position) || -1) + 1
      line_end = text.index('\n', position) || text.size
      line = text[line_start, line_end - line_start]
      column = text[line_start, position - line_start].size + 1
      {line_number, column, line}
    end

    private def self.format_preview_line(line : String, max_width : Int32 = 90) : String
      normalized = line.gsub('\t', " ")
      return normalized if normalized.size <= max_width

      suffix_width = (max_width - 3) // 2
      prefix_width = (max_width - 3) - suffix_width
      return "#{normalized[0...max_width - 3]}..." if prefix_width <= 0 || suffix_width <= 0

      "#{normalized[0, prefix_width]}...#{normalized[-suffix_width, suffix_width]}"
    end

    private def self.highlight_match_in_line(line : String, match_column : Int32, matched : String, bracket_width : Int32 = 2) : String
      normalized = line.gsub('\t', " ")
      chars = normalized.chars.to_a
      return normalized if chars.empty? || match_column <= 0

      match_size = matched.chars.to_a.size
      start = match_column - 1
      line_size = chars.size

      return normalized if start >= line_size

      match_len = [match_size, line_size - start].min
      match_end = start + match_len
      leading = chars[0, start].to_a.join
      match_body = chars[start, match_len].to_a.join
      trailing = chars[match_end, line_size - match_end].to_a.join

      context_budget = 90 - bracket_width
      if context_budget <= 0
        return "#{leading}[#{match_body}]#{trailing}"
      end

      leading_keep = [start, context_budget // 2].min
      trailing_keep = [line_size - match_end, context_budget // 2].min
      if leading_keep + match_len + trailing_keep > context_budget
        overflow = leading_keep + match_len + trailing_keep - context_budget
        trailing_keep = [0, trailing_keep - overflow].max
      end

      result = String::Builder.new
      if start > leading_keep
        result << "..."
        result << chars[(start - leading_keep)...start].to_a.join
      else
        result << leading
      end

      result << "["
      result << match_body
      result << "]"

      if match_end < line_size - trailing_keep
        result << chars[match_end, trailing_keep].to_a.join
        result << "..."
      else
        result << trailing
      end

      result.to_s
    end

    private def self.replace_pattern(old_text : String, ignore_case : Bool) : Regex
      if ignore_case
        Regex.new(Regex.escape(old_text), Regex::Options::IGNORE_CASE)
      else
        Regex.new(Regex.escape(old_text))
      end
    end
  end
end
