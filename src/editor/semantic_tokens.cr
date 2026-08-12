require "json"

module CrystalEditor
  module Lsp
    module SemanticTokens
      STANDARD_LEGEND = %w(
        namespace type class enum interface struct typeParameter parameter
        variable property enumMember event function method macro keyword
        modifier comment string number regexp operator decorator
      )

      STANDARD_MODIFIERS = %w(
        declaration definition readonly static deprecated abstract async
        modification documentation defaultLibrary
      )

      def self.parse_data(raw : JSON::Any?) : Array(Int32)
        return [] of Int32 unless raw
        return [] of Int32 if raw.raw.nil?

        values = raw["data"]?.try(&.as_a?)
        return [] of Int32 unless values

        values.compact_map do |value|
          value.as_i? || value.as_i64?.try(&.to_i)
        end
      end

      def self.parse_legend(capabilities : JSON::Any?) : Array(String)
        return STANDARD_LEGEND.dup unless capabilities
        provider = capabilities["semanticTokensProvider"]?
        return STANDARD_LEGEND.dup if provider.nil? || provider.raw.nil?

        types = provider["legend"]?.try(&.["tokenTypes"]?).try(&.as_a?)
        return STANDARD_LEGEND.dup unless types

        parsed = types.compact_map(&.as_s?)
        parsed.empty? ? STANDARD_LEGEND.dup : parsed
      end

      def self.supported?(capabilities : JSON::Any?) : Bool
        return false unless capabilities
        provider = capabilities["semanticTokensProvider"]?
        return false if provider.nil? || provider.raw.nil?
        return false if provider.as_bool? == false
        true
      end
    end
  end

  class SemanticOverlay
    STANDARD_LEGEND = Lsp::SemanticTokens::STANDARD_LEGEND

    getter legend : Array(String)

    def initialize(@legend : Array(String) = STANDARD_LEGEND.dup, @cells : Array(Array(Int8)) = [] of Array(Int8))
    end

    def self.empty : SemanticOverlay
      new
    end

    def self.build(data : Array(Int32), lines : Array(String), legend : Array(String)) : SemanticOverlay
      overlay = new(legend.dup, lines.map { |line| Array.new(line.size, -1_i8) })
      overlay.decode(data)
      overlay
    end

    def any_tokens? : Bool
      @cells.any? do |row|
        row.any? { |cell| cell >= 0 }
      end
    end

    def name_at(line : Int32, col : Int32) : String?
      index = type_index_at(line, col)
      return nil unless index
      @legend[index]?
    end

    def type_index_at(line : Int32, col : Int32) : Int32?
      return nil if line < 0 || col < 0
      row = @cells[line]?
      return nil unless row
      return nil if col >= row.size
      value = row[col]
      value < 0 ? nil : value.to_i
    end

    def apply_hash_comments(lines : Array(String)) : Nil
      comment_index = legend_index("comment")
      return if comment_index.nil? || comment_index > Int8::MAX

      lines.each_with_index do |line, line_index|
        next if line_index >= @cells.size
        hash_index = hash_comment_start(line, line_index)
        next unless hash_index
        fill_line(line_index, hash_index, line.size, comment_index.to_i8)
      end
    end

    protected def decode(data : Array(Int32)) : Nil
      prev_line = 0
      prev_start = 0
      index = 0

      while index + 4 < data.size
        delta_line = data[index]
        delta_start = data[index + 1]
        length = data[index + 2]
        token_type = data[index + 3]
        line = prev_line + delta_line
        start_char = delta_line == 0 ? prev_start + delta_start : delta_start
        paint(line, start_char, length, token_type)
        prev_line = line
        prev_start = start_char
        index += 5
      end
    end

    private def paint(line : Int32, start_char : Int32, length : Int32, token_type : Int32) : Nil
      return if line < 0 || start_char < 0 || length <= 0
      return if token_type < 0 || token_type >= @legend.size || token_type > Int8::MAX
      return if line >= @cells.size

      row = @cells[line]
      from = Math.min(start_char, row.size)
      to = Math.min(start_char + length, row.size)
      type = token_type.to_i8
      col = from
      while col < to
        row[col] = type
        col += 1
      end
    end

    private def fill_line(line : Int32, start_char : Int32, exclusive_end : Int32, token_type : Int8) : Nil
      return if line < 0 || line >= @cells.size
      row = @cells[line]
      from = Math.min(Math.max(start_char, 0), row.size)
      to = Math.min(Math.max(exclusive_end, 0), row.size)
      col = from
      while col < to
        row[col] = token_type
        col += 1
      end
    end

    private def legend_index(name : String) : Int32?
      if existing = @legend.index(name)
        return existing
      end
      return nil if @legend.size > Int8::MAX
      @legend << name
      @legend.size - 1
    end

    private def hash_comment_start(line : String, line_index : Int32) : Int32?
      line.each_char_with_index do |char, col|
        next unless char == '#'
        token = name_at(line_index, col)
        return col unless token == "string" || token == "regexp"
      end
      nil
    end
  end
end
