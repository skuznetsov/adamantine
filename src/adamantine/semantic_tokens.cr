require "json"
require "./lsp_line_source"
require "./text_coordinates"

module Adamantine
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
      build(data, BufferLines::Source.new(lines), legend)
    end

    # Build the row storage from a persistent document snapshot without asking
    # the editor for its materialized `lines` array.  Only line lengths are
    # retained; source text remains in the piece-tree snapshot.
    def self.build(data : Array(Int32), source : BufferLines::Source, legend : Array(String)) : SemanticOverlay
      rows = [] of Array(Int8)
      source.each_line_length do |length, _line_index|
        rows << Array.new(length, -1_i8)
      end
      overlay = new(legend.dup, rows)
      overlay.decode(data, source)
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

    def apply_hash_comments(source : BufferLines::Source) : Nil
      comment_index = legend_index("comment")
      return if comment_index.nil? || comment_index > Int8::MAX

      source.each_line do |line, line_index|
        next if line_index >= @cells.size
        hash_index = hash_comment_start(line, line_index)
        next unless hash_index
        fill_line(line_index, hash_index, line.size, comment_index.to_i8)
      end
    end

    # Decode semantic token positions while the source is still streaming.
    # LSP positions are UTF-16 columns; overlay rows remain codepoint-indexed.
    # The pending token keeps delta state intact while the source advances to
    # its line, so malformed backwards deltas are skipped in input order
    # rather than reordered into a later row.
    protected def decode(data : Array(Int32), source : BufferLines::Source) : Nil
      return if data.size < 5

      previous_line = 0_i64
      previous_start = 0_i64
      data_index = 0

      pending_line : Int64? = nil
      pending_start : Int64? = nil
      pending_length : Int64 = 0
      pending_type = -1

      source.each_line do |line_text, line_index|
        mapper : Utf16LineMapper? = nil

        loop do
          unless pending_line
            break if data_index + 4 >= data.size

            delta_line = data[data_index].to_i64
            delta_start = data[data_index + 1].to_i64
            pending_line = safe_add(previous_line, delta_line)
            pending_start = delta_line == 0 ? safe_add(previous_start, delta_start) : delta_start
            pending_length = data[data_index + 2].to_i64
            pending_type = data[data_index + 3]
          end

          token_line = pending_line.not_nil!
          break if token_line > line_index

          token_start = pending_start.not_nil!
          previous_line = token_line
          previous_start = token_start
          data_index += 5
          pending_line = nil
          pending_start = nil

          # A token whose delta walks backwards is malformed for a streaming
          # source: the source has already passed its row.  Consume it, but do
          # not let it alter a row or the ordering of later valid tokens.
          next if token_line < 0 || token_line < line_index
          next if pending_length <= 0
          next if pending_type < 0 || pending_type >= @legend.size || pending_type > Int8::MAX
          next unless token_line == line_index
          next if token_start < 0

          mapper ||= Utf16LineMapper.new(line_text)
          begin
            start_column = mapper.to_codepoint(token_start, clamp: true)
            finish_utf16 = safe_add(token_start, pending_length)
            finish_column = mapper.to_codepoint(finish_utf16, clamp: true)
            paint(line_index, start_column, finish_column, pending_type)
          rescue ArgumentError
            # A surrogate-interior boundary is malformed.  Read-only semantic
            # highlighting drops that token rather than inventing a codepoint
            # boundary; oversized endpoints are clamped by the mapper.
          end
        end
      end
    end

    private def paint(line : Int32, start_char : Int32, finish_char : Int32, token_type : Int32) : Nil
      return if line < 0 || start_char < 0 || finish_char <= start_char
      return if token_type < 0 || token_type >= @legend.size || token_type > Int8::MAX
      return if line >= @cells.size

      row = @cells[line]
      from = Math.min(start_char, row.size)
      to = Math.min(Math.max(finish_char, 0), row.size)
      type = token_type.to_i8
      col = from
      while col < to
        row[col] = type
        col += 1
      end
    end

    private def safe_add(left : Int64, right : Int64) : Int64
      if right > 0 && left > Int64::MAX - right
        Int64::MAX
      elsif right < 0 && left < Int64::MIN - right
        Int64::MIN
      else
        left + right
      end
    end

    # A map is built only for lines containing a non-BMP codepoint.  For an
    # ASCII/BMP line, UTF-16 and codepoint columns are identical and no line
    # sized allocation is needed.  Non-BMP lines are mapped once and then
    # reused for every token group on that line.
    private class Utf16LineMapper
      @boundaries : Array(Int64)?
      @codepoint_count : Int32

      def initialize(@line : String)
        @codepoint_count = @line.size
        needs_map = @line.each_char.any? { |char| char.ord > 0xffff }
        @boundaries = needs_map ? build_boundaries : nil
      end

      def to_codepoint(target : Int64, *, clamp : Bool) : Int32
        raise ArgumentError.new("negative UTF-16 column") if target < 0

        unless boundaries = @boundaries
          if target <= @codepoint_count
            return target.to_i32
          end
          return @codepoint_count if clamp
          raise ArgumentError.new("UTF-16 column outside line")
        end

        final = boundaries.last
        if target > final
          return boundaries.size.to_i32 - 1 if clamp
          raise ArgumentError.new("UTF-16 column outside line")
        end

        low = 0
        high = boundaries.size - 1
        while low <= high
          middle = (low + high) // 2
          boundary = boundaries[middle]
          if boundary == target
            return middle.to_i32
          elsif boundary < target
            low = middle + 1
          else
            high = middle - 1
          end
        end

        raise ArgumentError.new("UTF-16 column falls inside a surrogate pair")
      end

      private def build_boundaries : Array(Int64)
        result = [0_i64]
        units = 0_i64
        @line.each_char do |char|
          units += char.ord > 0xffff ? 2 : 1
          result << units
        end
        result
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
