require "crystal_tui"

require "./project_search"

module Adamantine
  # Bounded, read-only search over a persistent PieceTreeBuffer snapshot.
  #
  # The source deliberately exposes codepoint chunks rather than text, lines,
  # or line slices.  Search callers therefore cannot accidentally turn a
  # large document or a single very long line into one transient String.
  module BufferSearch
    SCAN_CHUNK_CODEPOINTS = 2048

    class Source
      @buffer : Tui::PieceTreeBuffer

      # PieceTreeBuffer#dup copies the active root and shares immutable source
      # pages.  Appended edit pages remain safe to read through this old root.
      def initialize(buffer : Tui::PieceTreeBuffer)
        @buffer = buffer.dup
      end

      def byte_length : Int32
        @buffer.byte_length
      end

      def codepoint_length : Int32
        @codepoint_length ||= @buffer.codepoint_index_at_offset(@buffer.byte_length)
      end

      @codepoint_length : Int32? = nil

      def slice_codepoints(start : Int32, count : Int32) : String
        raise ArgumentError.new("codepoint start and count must not be negative") if start < 0 || count < 0

        finish = start.to_i64 + count
        raise ArgumentError.new("codepoint range outside buffer") if finish > codepoint_length
        return "" if count == 0

        from = @buffer.byte_offset_at_codepoint(start)
        to = @buffer.byte_offset_at_codepoint(finish.to_i32)

        # PieceTreeBuffer intentionally rejects a slice boundary between the
        # bytes of a CRLF pair. A codepoint chunk can legitimately end after
        # CR (or begin at LF), so include the adjacent byte in the read and
        # trim it back from the returned String. The over-read is at most one
        # byte at either edge and keeps the source reader bounded.
        safe_from = from
        trim_prefix = 0
        if from > 0 && @buffer.byte_at_offset(from) == '\n'.ord.to_u8 && @buffer.byte_at_offset(from - 1) == '\r'.ord.to_u8
          safe_from -= 1
          trim_prefix = 1
        end

        safe_to = to
        trim_suffix = 0
        if to < byte_length && to > 0 && @buffer.byte_at_offset(to) == '\n'.ord.to_u8 && @buffer.byte_at_offset(to - 1) == '\r'.ord.to_u8
          safe_to += 1
          trim_suffix = 1
        end

        chunk = @buffer.slice(safe_from, safe_to - safe_from)
        chunk.byte_slice(trim_prefix, chunk.bytesize - trim_prefix - trim_suffix)
      end
    end

    struct ScanResult
      getter matches : Array(ProjectSearch::Match)
      getter truncated : Bool
      getter cancelled : Bool

      def initialize(@matches : Array(ProjectSearch::Match), @truncated : Bool, @cancelled : Bool)
      end

      def truncated? : Bool
        @truncated
      end

      def cancelled? : Bool
        @cancelled
      end
    end

    # A repeat search always returns a result object so cancellation cannot be
    # confused with an ordinary no-match result.
    struct RepeatResult
      getter match : ProjectSearch::Match?
      getter wrapped : Bool
      getter cancelled : Bool

      def initialize(@match : ProjectSearch::Match?, @wrapped : Bool, @cancelled : Bool)
      end

      def wrapped? : Bool
        @wrapped
      end

      def cancelled? : Bool
        @cancelled
      end
    end

    private struct RawMatch
      getter line : Int32
      getter col : Int32
      getter end_col : Int32
      getter start_codepoint : Int32
      getter end_codepoint : Int32

      def initialize(@line : Int32, @col : Int32, @end_col : Int32, @start_codepoint : Int32, @end_codepoint : Int32)
      end
    end

    private struct Token
      getter char : Char
      getter line : Int32
      getter col : Int32
      getter codepoint : Int32

      def initialize(@char : Char, @line : Int32, @col : Int32, @codepoint : Int32)
      end
    end

    private class Matcher
      @ring : Array(Token)
      @ring_head : Int32 = 0
      @ring_count : Int32 = 0
      @next_allowed_codepoint : Int32 = 0
      @last_match_start : Int32? = nil
      @last_match_end : Int32? = nil
      @failure : Array(Int32)
      @matched : Int32 = 0

      def initialize(@query : Array(Char), @ignore_case : Bool, @non_overlapping : Bool)
        @ring = Array(Token).new(@query.size) { Token.new('\0', 0, 0, 0) }
        @failure = failure_table(@query)
      end

      def reset : Nil
        @ring_head = 0
        @ring_count = 0
        @matched = 0
      end

      def feed(char : Char, codepoint : Int32, line : Int32, col : Int32, &) : Nil
        if @ignore_case
          if char.ord < 128
            append_token(char.downcase, codepoint, line, col) { |raw| yield raw }
          else
            char.downcase do |mapped|
              append_token(mapped, codepoint, line, col) { |raw| yield raw }
            end
          end
        else
          append_token(char, codepoint, line, col) { |raw| yield raw }
        end
      end

      private def append_token(char : Char, codepoint : Int32, line : Int32, col : Int32, &) : Nil
        index = if @ring_count < @ring.size
                  result = (@ring_head + @ring_count) % @ring.size
                  @ring_count += 1
                  result
                else
                  result = @ring_head
                  @ring_head = (@ring_head + 1) % @ring.size
                  result
                end
        @ring[index] = Token.new(char, line, col, codepoint)
        while @matched > 0 && @query[@matched] != char
          @matched = @failure[@matched - 1]
        end
        if @query[@matched] == char
          @matched += 1
        end
        return unless @matched == @query.size
        @matched = @failure[@matched - 1]

        first = @ring[@ring_head]
        last = @ring[(@ring_head + @ring_count - 1) % @ring.size]
        start_codepoint = first.codepoint
        end_codepoint = last.codepoint + 1
        return if @last_match_start == start_codepoint && @last_match_end == end_codepoint
        return if @non_overlapping && start_codepoint < @next_allowed_codepoint

        raw = RawMatch.new(first.line, first.col, last.col + 1, start_codepoint, end_codepoint)
        @last_match_start = start_codepoint
        @last_match_end = end_codepoint
        @next_allowed_codepoint = end_codepoint if @non_overlapping
        yield raw
      end

      private def failure_table(query : Array(Char)) : Array(Int32)
        failure = Array(Int32).new(query.size, 0)
        prefix = 0
        index = 1
        while index < query.size
          while prefix > 0 && query[index] != query[prefix]
            prefix = failure[prefix - 1]
          end
          if query[index] == query[prefix]
            prefix += 1
          end
          failure[index] = prefix
          index += 1
        end
        failure
      end
    end

    # Scan all logical lines, retaining at most max_matches result objects.
    # The live search uses the default cap; repeat search uses find_next below
    # and therefore never relies on this capped result list.
    def self.scan(
      source : Source,
      query : String,
      *,
      ignore_case : Bool = false,
      path : Path = Path.new(""),
      max_matches : Int32 = 200,
      checkpoint : Proc(Bool)? = nil,
    ) : ScanResult
      matches = [] of ProjectSearch::Match
      return ScanResult.new(matches, false, false) if query.empty? || multiline_query?(query)
      return ScanResult.new(matches, true, false) if max_matches <= 0

      query_units = normalized_query(query, ignore_case)
      return ScanResult.new(matches, false, false) if query_units.empty?

      matcher = Matcher.new(query_units, ignore_case, true)
      cancelled = walk(source, matcher, checkpoint) do |raw|
        matches << match_for(source, path, raw)
        matches.size < max_matches
      end

      ScanResult.new(matches, !cancelled && matches.size >= max_matches, cancelled)
    end

    # Locate one occurrence without collecting the whole result set.  Forward
    # search starts strictly after the supplied cursor position.  Backward
    # search accepts only occurrences starting before the cursor.  If no
    # candidate exists in that direction, the result wraps through the same
    # line as well as earlier/later lines.
    def self.find_next(
      source : Source,
      query : String,
      line : Int32,
      col : Int32,
      *,
      forward : Bool,
      ignore_case : Bool = false,
      path : Path = Path.new(""),
      checkpoint : Proc(Bool)? = nil,
    ) : RepeatResult
      return RepeatResult.new(nil, false, false) if query.empty? || multiline_query?(query)

      query_units = normalized_query(query, ignore_case)
      return RepeatResult.new(nil, false, false) if query_units.empty?

      cursor_line = [line, 0].max
      cursor_col = [col, 0].max
      first : RawMatch? = nil
      last : RawMatch? = nil
      after : RawMatch? = nil
      before : RawMatch? = nil
      matcher = Matcher.new(query_units, ignore_case, false)
      cancelled = walk(source, matcher, checkpoint) do |raw|
        first ||= raw
        last = raw

        if forward
          if after.nil? && after_cursor?(raw, cursor_line, cursor_col)
            after = raw
            false
          else
            true
          end
        elsif before_cursor?(raw, cursor_line, cursor_col)
          before = raw
          true
        else
          true
        end
      end

      return RepeatResult.new(nil, false, true) if cancelled

      selected, wrapped = if forward
                            {after || first, after.nil? && !first.nil?}
                          else
                            {before || last, before.nil? && !last.nil?}
                          end
      return RepeatResult.new(nil, false, false) unless raw = selected

      RepeatResult.new(match_for(source, path, raw), wrapped, false)
    end

    private def self.walk(source : Source, matcher : Matcher, checkpoint : Proc(Bool)?, &) : Bool
      total = source.codepoint_length
      return false if total == 0

      chunk_start = 0
      line = 0
      col = 0
      previous_cr = false
      absolute_codepoint = 0

      while chunk_start < total
        if checkpoint
          Fiber.yield
          return true unless checkpoint.call
        end

        chunk_count = Math.min(SCAN_CHUNK_CODEPOINTS, total - chunk_start)
        chunk = source.slice_codepoints(chunk_start, chunk_count)
        chunk.each_char do |char|
          if char == '\r'
            matcher.reset
            line += 1
            col = 0
            previous_cr = true
          elsif char == '\n'
            matcher.reset
            unless previous_cr
              line += 1
              col = 0
            end
            previous_cr = false
          else
            previous_cr = false
            matcher.feed(char, absolute_codepoint, line, col) do |raw|
              return false unless yield raw
            end
            col += 1
          end
          absolute_codepoint += 1
        end
        chunk_start += chunk_count
      end
      false
    end

    private def self.multiline_query?(query : String) : Bool
      query.includes?('\r') || query.includes?('\n')
    end

    private def self.normalized_query(query : String, ignore_case : Bool) : Array(Char)
      chars = [] of Char
      query.each_char do |char|
        if ignore_case
          if char.ord < 128
            chars << char.downcase
          else
            char.downcase { |mapped| chars << mapped }
          end
        else
          chars << char
        end
      end
      chars
    end

    private def self.after_cursor?(raw : RawMatch, line : Int32, col : Int32) : Bool
      raw.line > line || (raw.line == line && raw.col > col)
    end

    private def self.before_cursor?(raw : RawMatch, line : Int32, col : Int32) : Bool
      raw.line < line || (raw.line == line && raw.col < col)
    end

    private def self.match_for(source : Source, path : Path, raw : RawMatch) : ProjectSearch::Match
      ProjectSearch::Match.new(
        path,
        raw.line,
        raw.col,
        snippet(source, raw.start_codepoint),
        raw.end_col
      )
    end

    private def self.snippet(source : Source, start_codepoint : Int32) : String
      remaining = source.codepoint_length - start_codepoint
      return "" if remaining <= 0

      count = Math.min(ProjectSearch::SNIPPET_MAX, remaining)
      text = source.slice_codepoints(start_codepoint, count)
      text = text.gsub('\t', " ").gsub('\r', " ").gsub('\n', " ").strip
      String.build do |builder|
        graphemes = 0
        text.each_grapheme do |grapheme|
          break if graphemes >= ProjectSearch::SNIPPET_MAX
          builder << grapheme
          graphemes += 1
        end
      end
    end
  end
end
