require "./buffer_search"

module Adamantine
  # A deliberately small, LSP-independent lexical highlighter.
  #
  # The source is consumed as bounded codepoint chunks from a persistent
  # BufferSearch::Source.  No document-sized String, line array, or
  # per-character overlay is retained here.  A caller owns the source
  # snapshot and must replace it on edits; this object only publishes work for
  # its currently bound revision.
  class LexicalHighlighter
    STREAM_CHUNK_CODEPOINTS      = 2_048
    DEFAULT_MAX_CACHED_LINES     =   256
    DEFAULT_MAX_CACHED_SPANS     = 4_096
    DEFAULT_MAX_LINE_CODEPOINTS  = 4_096
    DEFAULT_MAX_TOKEN_CODEPOINTS =   128
    DEFAULT_WORK_CODEPOINTS      = 4_096

    enum TokenKind
      Keyword
      Comment
      String
      Number
      Name
    end

    enum NameRole
      Variable
      Function
      Type
      Property
    end

    # Codepoint-indexed, half-open span.  A span never crosses a logical line.
    struct Span
      getter line : Int32
      getter start_col : Int32
      getter end_col : Int32
      getter kind : TokenKind
      getter role : NameRole?

      def initialize(
        @line : Int32,
        @start_col : Int32,
        @end_col : Int32,
        @kind : TokenKind,
        @role : NameRole? = nil,
      )
      end

      def contains?(column : Int32) : Bool
        column >= @start_col && column < @end_col
      end

      # Names intentionally use the same names as the existing syntax/theme
      # layer.  Generic identifiers are variables; a small amount of local
      # context distinguishes type, function, and member names.
      def token_name : String
        case @kind
        when TokenKind::Keyword then "keyword"
        when TokenKind::Comment then "comment"
        when TokenKind::String  then "string"
        when TokenKind::Number  then "number"
        when TokenKind::Name
          case @role
          when NameRole::Function then "function"
          when NameRole::Type     then "type"
          when NameRole::Property then "property"
          else                         "variable"
          end
        else
          "variable"
        end
      end

      # Convenience alias for consumers that use the semantic-overlay naming
      # convention.
      def name : String
        token_name
      end
    end

    # Progress is retained separately so the parent scheduler can make work
    # and stale-publication decisions without requiring a synchronous scan.
    struct Progress
      getter version : UInt64
      getter codepoints_scanned : Int32
      getter lines_completed : Int32
      getter next_line : Int32
      getter requested_line : Int32?
      getter more_work : Bool
      getter complete : Bool
      getter stale : Bool

      def initialize(
        @version : UInt64,
        @codepoints_scanned : Int32,
        @lines_completed : Int32,
        @next_line : Int32,
        @requested_line : Int32?,
        @more_work : Bool,
        @complete : Bool,
        @stale : Bool = false,
      )
      end

      def made_progress? : Bool
        @codepoints_scanned > 0 || @lines_completed > 0
      end

      def more_work? : Bool
        @more_work
      end

      def complete? : Bool
        @complete
      end

      def stale? : Bool
        @stale
      end
    end

    private enum LexState
      Normal
      DoubleString
      SingleString
      Comment
      Unknown
    end

    private class CachedLine
      getter spans : Array(Span)
      getter start_offset : Int32
      getter end_offset : Int32
      getter state_before : LexState
      getter state_after : LexState
      getter complete : Bool

      def initialize(
        @spans : Array(Span),
        @start_offset : Int32,
        @end_offset : Int32,
        @state_before : LexState,
        @state_after : LexState,
        @complete : Bool,
      )
      end
    end

    KEYWORDS = Set{
      "abstract", "alias", "annotation", "as", "asm", "begin", "break",
      "case", "class", "def", "do", "else", "elsif", "end", "ensure", "enum",
      "extend", "false", "for", "fun", "if", "in", "include",
      "instance_sizeof", "interface", "lib", "macro", "module", "next",
      "nil", "of", "out", "pointerof", "previous_def", "private",
      "protected", "require", "rescue", "responds_to?", "return", "select",
      "self", "sizeof", "struct", "super", "then", "true", "type", "typeof",
      "union", "unless", "until", "verbatim", "when", "while", "with", "yield",
    }

    TYPE_NAME_KEYWORDS     = Set{"alias", "annotation", "class", "enum", "interface", "lib", "module", "struct", "type", "union"}
    FUNCTION_NAME_KEYWORDS = Set{"def", "fun", "macro"}

    @source : BufferSearch::Source
    @version : UInt64
    @max_cached_lines : Int32
    @max_cached_spans : Int32
    @max_line_codepoints : Int32
    @max_token_codepoints : Int32

    @cache = {} of Int32 => CachedLine
    @cached_span_count : Int32 = 0
    @source_offset : Int32 = 0
    @line : Int32 = 0
    @line_column : Int32 = 0
    @line_state_before : LexState = LexState::Normal
    @lex_state : LexState = LexState::Normal
    @line_spans = [] of Span
    @line_unknown : Bool = false
    @line_start_offset : Int32 = 0
    @comment_start : Int32?
    @string_start : Int32?
    @string_escaped : Bool = false
    @word_start : Int32?
    @word_text = IO::Memory.new(128)
    @word_length : Int32 = 0
    @word_overflow : Bool = false
    @number_start : Int32?
    @expected_name_role : NameRole?
    @member_access_pending : Bool = false
    @last_name_span_index : Int32?
    @pending_percent : Bool = false
    @previous_line_char : Char?
    @pending_cr : Bool = false
    @requested_line : Int32?
    @done : Bool = false
    @last_progress : Progress

    def initialize(
      source : BufferSearch::Source,
      *,
      max_cached_lines : Int32 = DEFAULT_MAX_CACHED_LINES,
      max_cached_spans : Int32 = DEFAULT_MAX_CACHED_SPANS,
      max_line_codepoints : Int32 = DEFAULT_MAX_LINE_CODEPOINTS,
      max_token_codepoints : Int32 = DEFAULT_MAX_TOKEN_CODEPOINTS,
    )
      raise ArgumentError.new("max_cached_lines must be positive") if max_cached_lines <= 0
      raise ArgumentError.new("max_cached_spans must be positive") if max_cached_spans <= 0
      raise ArgumentError.new("max_line_codepoints must be positive") if max_line_codepoints <= 0
      raise ArgumentError.new("max_token_codepoints must be positive") if max_token_codepoints <= 0

      @source = source
      @version = 0_u64
      @max_cached_lines = max_cached_lines
      @max_cached_spans = max_cached_spans
      @max_line_codepoints = max_line_codepoints
      @max_token_codepoints = max_token_codepoints
      @last_progress = Progress.new(@version, 0, 0, 0, nil, true, false)
    end

    getter version : UInt64
    getter last_progress : Progress

    def cached_line_count : Int32
      @cache.size.to_i32
    end

    def cached_span_count : Int32
      @cached_span_count
    end

    def complete? : Bool
      @done
    end

    # Return true while the requested line is not a complete cached result.
    # The method only changes the target; actual source work happens in
    # advance, which keeps rendering non-blocking.
    def request(line : Int32) : Bool
      target = Math.max(line, 0)
      unless @cache.has_key?(target)
        # A completed source cannot produce an out-of-range row.  Treat that
        # request as settled rather than waking a worker forever.  An old row
        # that was evicted still needs a bounded restart so it can be rebuilt.
        if @done && target >= @line
          @requested_line = target
          return false
        end
        # A bounded cache may have evicted an old viewport row.  Restarting is
        # still bounded per advance call and is safer than publishing a row
        # whose lexical state cannot be reconstructed from the retained cache.
        if target < @line
          restart_from_zero
        end
      end
      @requested_line = target
      !cached_complete?(target)
    end

    # Reset to an immutable source revision.  Version zero is valid for small
    # standalone callers; the application supplies a monotonically increasing
    # revision for live buffers.
    def reset(source : BufferSearch::Source, version : UInt64 = 0_u64) : Nil
      @source = source
      @version = version
      restart_from_zero
      @requested_line = nil
      @last_progress = Progress.new(@version, 0, 0, 0, nil, true, false)
    end

    def bind(source : BufferSearch::Source, version : UInt64 = 0_u64) : Nil
      reset(source, version)
    end

    # Rebind after an edit and retain only the unaffected prefix.  The caller
    # supplies the first changed logical line; bytes and lexical state before
    # that line are assumed unchanged by the editor's edit contract.
    def invalidate(source : BufferSearch::Source, from_line : Int32, *, version : UInt64? = nil) : Nil
      next_version = version || (@version + 1_u64)
      return if next_version < @version

      first = Math.max(from_line, 0)
      state_before = LexState::Normal
      restart_offset = 0

      if entry = @cache[first]?
        state_before = entry.state_before
        restart_offset = entry.start_offset
      elsif first > 0
        if previous = @cache[first - 1]?
          state_before = previous.state_after
          restart_offset = previous.end_offset
        elsif first <= @line
          # The required state was evicted; reconstruct from the beginning on
          # the next bounded advance instead of guessing through a string.
          first = 0
          state_before = LexState::Normal
          restart_offset = 0
        end
      end

      @source = source
      @version = next_version
      @cache.keys.each do |line_index|
        if line_index >= first
          removed = @cache.delete(line_index)
          @cached_span_count -= removed.not_nil!.spans.size if removed
        end
      end

      if first <= @line
        prepare_scan(first, restart_offset, state_before)
      end
      @done = false if first <= @line
      @last_progress = Progress.new(@version, 0, 0, @line, @requested_line, true, false)
    end

    # Advance at most +max_codepoints+ source codepoints.  A stale expected
    # revision performs no work and returns false; the scheduler may drop that
    # worker and start against the replacement source.
    def advance(max_codepoints : Int32 = DEFAULT_WORK_CODEPOINTS, *, expected_version : UInt64? = nil) : Bool
      raise ArgumentError.new("max_codepoints must be positive") if max_codepoints <= 0

      if expected_version && expected_version != @version
        @last_progress = Progress.new(@version, 0, 0, @line, @requested_line, false, @done, true)
        return false
      end

      target = @requested_line
      if target && cached_complete?(target)
        @requested_line = nil
        @last_progress = Progress.new(@version, 0, 0, @line, nil, false, @done)
        return false
      end

      remaining = max_codepoints
      scanned = 0
      completed_lines = 0

      while remaining > 0 && !@done
        available = @source.codepoint_length - @source_offset
        if available <= 0
          completed_lines += finish_eof
          break
        end

        take = Math.min(remaining, Math.min(STREAM_CHUNK_CODEPOINTS, available))
        chunk = @source.slice_codepoints(@source_offset, take)
        consumed = 0
        chunk.each_char do |char|
          consume_codepoint(char)
          @source_offset += 1
          consumed += 1
          # Do not consume the rest of a large source chunk after the
          # requested viewport row became complete.  This matters with a tiny
          # cache: scanning thousands of short rows could otherwise evict the
          # row just requested before the scheduler observes it.
          break if target && cached_complete?(target)
        end
        # A valid BufferSearch::Source returns exactly +take+ codepoints.  Do
        # not loop forever if a defensive source implementation violates that
        # contract.
        break if consumed <= 0
        scanned += consumed
        remaining -= consumed
        completed_lines += @completed_lines_since_last_progress
        @completed_lines_since_last_progress = 0

        if target && cached_complete?(target)
          @requested_line = nil
          break
        end
      end

      more = !@done && !(target && cached_complete?(target))
      @last_progress = Progress.new(@version, scanned, completed_lines, @line, @requested_line, more, @done)
      more
    end

    # Return the retained spans for a fully scanned line.  Nil means that the
    # line is not currently cached or was deliberately marked unknown/plain.
    # Callers should treat the returned array as read-only.
    def spans_at(line : Int32) : Array(Span)?
      return nil if line < 0
      entry = @cache[line]?
      return nil unless entry && entry.complete
      entry.spans
    end

    # Match SemanticOverlay#name_at: nil means not yet scanned, unknown, or
    # ordinary punctuation/whitespace.  Semantic LSP tokens can override this
    # result in the renderer.
    def name_at(line : Int32, column : Int32) : String?
      return nil if line < 0 || column < 0
      entry = @cache[line]?
      return nil unless entry && entry.complete
      spans = entry.spans
      low = 0
      high = spans.size - 1
      while low <= high
        middle = (low + high) // 2
        span = spans[middle]
        if column < span.start_col
          high = middle - 1
        elsif column >= span.end_col
          low = middle + 1
        else
          return span.token_name
        end
      end
      nil
    end

    @completed_lines_since_last_progress : Int32 = 0

    private def restart_from_zero : Nil
      clear_cache
      prepare_scan(0, 0, LexState::Normal)
      @done = false
    end

    private def clear_cache : Nil
      @cache.clear
      @cached_span_count = 0
    end

    private def prepare_scan(line : Int32, offset : Int32, state : LexState) : Nil
      @source_offset = Math.max(offset, 0)
      @line = Math.max(line, 0)
      @line_column = 0
      @line_state_before = state
      @lex_state = state
      @line_spans = [] of Span
      @line_unknown = state == LexState::Unknown
      @line_start_offset = @source_offset
      @comment_start = nil
      @string_start = state == LexState::DoubleString || state == LexState::SingleString ? 0 : nil
      @string_escaped = false
      @word_start = nil
      @word_text.clear
      @word_length = 0
      @word_overflow = false
      @number_start = nil
      @expected_name_role = nil
      @member_access_pending = false
      @last_name_span_index = nil
      @pending_percent = false
      @previous_line_char = nil
      @pending_cr = false
      @completed_lines_since_last_progress = 0
    end

    private def cached_complete?(line : Int32) : Bool
      entry = @cache[line]?
      !!(entry && entry.complete)
    end

    private def consume_codepoint(char : Char) : Nil
      if @pending_cr
        if char == '\n'
          finish_line
          @pending_cr = false
          return
        end
        finish_line(@source_offset)
        @pending_cr = false
      end

      case char
      when '\r'
        finish_line_pending_cr
      when '\n'
        finish_line
      else
        consume_line_char(char)
      end
    end

    private def finish_line_pending_cr : Nil
      @pending_cr = true
    end

    private def finish_line(next_offset : Int32 = @source_offset + 1) : Nil
      # The next offset includes CRLF, but excludes the following character
      # when a pending lone CR is resolved by a non-LF character.
      if @pending_cr
        @pending_cr = false
      end

      if @lex_state == LexState::Normal
        finish_word(nil)
        finish_number
      elsif @lex_state == LexState::Comment
        add_span(@comment_start || @line_column, @line_column, TokenKind::Comment)
      elsif @lex_state == LexState::DoubleString || @lex_state == LexState::SingleString
        add_span(@string_start || 0, @line_column, TokenKind::String)
      end

      state_after = @lex_state == LexState::Comment ? LexState::Normal : @lex_state
      spans = @line_unknown || state_after == LexState::Unknown ? [] of Span : @line_spans
      # Intentionally plain rows are completed too; they must not trigger a
      # fresh scan on every render frame.
      store_line(spans, @line_start_offset, next_offset, @line_state_before, state_after, true)
      @completed_lines_since_last_progress += 1

      @line += 1
      @line_column = 0
      @line_state_before = state_after
      @lex_state = state_after
      @line_spans = [] of Span
      @line_unknown = state_after == LexState::Unknown
      @line_start_offset = next_offset
      @string_escaped = false
      @comment_start = nil
      @string_start = if state_after == LexState::DoubleString || state_after == LexState::SingleString
                        0
                      else
                        nil
                      end
      @word_start = nil
      @word_text.clear
      @word_length = 0
      @word_overflow = false
      @number_start = nil
      @last_name_span_index = nil
      @pending_percent = false
      @previous_line_char = nil
      @member_access_pending = false
    end

    private def finish_eof : Int32
      before = @completed_lines_since_last_progress
      # A final newline still leaves one empty logical line.  For a non-empty
      # source this is observable in the piece-tree line model.
      if @pending_cr
        @pending_cr = false
        finish_line(@source_offset)
      end
      finish_line(@source_offset)
      @done = true
      @completed_lines_since_last_progress - before
    end

    private def consume_line_char(char : Char) : Nil
      if @lex_state == LexState::Unknown
        increment_column
        return
      end

      if @lex_state == LexState::Comment
        increment_column
        return
      end

      if @lex_state == LexState::DoubleString || @lex_state == LexState::SingleString
        consume_string_char(char)
        increment_column
        return
      end

      if @pending_percent
        @pending_percent = false
        if percent_literal_start?(char)
          mark_unknown
          increment_column
          return
        end
      end

      if @previous_line_char == '<' && char == '<'
        mark_unknown
        increment_column
        return
      end

      if @word_start
        if identifier_continue?(char)
          append_word(char)
          @previous_line_char = char
          increment_column
          return
        end
        finish_word(char)
      end

      if @number_start
        if number_continue?(char)
          @previous_line_char = char
          increment_column
          return
        end
        finish_number
      end

      case char
      when '#'
        @lex_state = LexState::Comment
        @comment_start = @line_column
        @previous_line_char = char
        increment_column
      when '"', '\''
        @lex_state = char == '"' ? LexState::DoubleString : LexState::SingleString
        @string_start = @line_column
        @string_escaped = false
        @previous_line_char = char
        increment_column
      when '`'
        mark_unknown
        increment_column
      when '%'
        @pending_percent = true
        @previous_line_char = char
        increment_column
      else
        if identifier_start?(char)
          begin_word(char)
        elsif ascii_digit?(char)
          @number_start = @line_column
        elsif char == '.'
          @member_access_pending = true
          @last_name_span_index = nil
        elsif !char.whitespace?
          # Any significant punctuation other than a member dot breaks a
          # pending function-name candidate.
          if char != '('
            @last_name_span_index = nil
          elsif index = @last_name_span_index
            promote_name(index, NameRole::Function)
            @last_name_span_index = nil
          end
        end
        @previous_line_char = char
        increment_column
      end
    end

    private def consume_string_char(char : Char) : Nil
      if @string_escaped
        @string_escaped = false
      elsif char == '\\'
        @string_escaped = true
      elsif (@lex_state == LexState::DoubleString && char == '"') ||
            (@lex_state == LexState::SingleString && char == '\'')
        add_span(@string_start || 0, @line_column + 1, TokenKind::String)
        @lex_state = LexState::Normal
        @string_start = nil
        @string_escaped = false
      end
    end

    private def begin_word(char : Char) : Nil
      @word_start = @line_column
      @word_text.clear
      @word_text << char
      @word_length = 1
      @word_overflow = false
    end

    private def append_word(char : Char) : Nil
      @word_length += 1
      if @word_length <= @max_token_codepoints
        @word_text << char
      else
        @word_overflow = true
      end
    end

    private def finish_word(delimiter : Char?) : Nil
      start = @word_start
      return unless start

      text = @word_overflow ? "" : @word_text.to_s
      if !@word_overflow && KEYWORDS.includes?(text)
        add_span(start, @line_column, TokenKind::Keyword)
        if TYPE_NAME_KEYWORDS.includes?(text)
          @expected_name_role = NameRole::Type
        elsif FUNCTION_NAME_KEYWORDS.includes?(text)
          @expected_name_role = NameRole::Function
        else
          @expected_name_role = nil
        end
      else
        role = @expected_name_role || (@member_access_pending ? NameRole::Property : NameRole::Variable)
        role = NameRole::Function if delimiter == '(' && role == NameRole::Variable
        add_span(start, @line_column, TokenKind::Name, role)
        @expected_name_role = nil
        @member_access_pending = false
        @last_name_span_index = @line_spans.size - 1
      end

      @word_start = nil
      @word_text.clear
      @word_length = 0
      @word_overflow = false
    end

    private def finish_number : Nil
      start = @number_start
      return unless start
      add_span(start, @line_column, TokenKind::Number)
      @number_start = nil
    end

    private def add_span(start_col : Int32, end_col : Int32, kind : TokenKind, role : NameRole? = nil) : Nil
      return if end_col <= start_col || @line_unknown
      if @line_spans.size >= @max_cached_spans
        @line_unknown = true
        @line_spans.clear
        return
      end
      @line_spans << Span.new(@line, start_col, end_col, kind, role)
    end

    private def promote_name(index : Int32, role : NameRole) : Nil
      span = @line_spans[index]?
      return unless span && span.kind == TokenKind::Name
      @line_spans[index] = Span.new(span.line, span.start_col, span.end_col, span.kind, role)
    end

    private def mark_unknown : Nil
      @line_unknown = true
      @lex_state = LexState::Unknown
      @line_spans.clear
      @word_start = nil
      @number_start = nil
      @comment_start = nil
      @string_start = nil
    end

    private def store_line(
      spans : Array(Span),
      start_offset : Int32,
      end_offset : Int32,
      state_before : LexState,
      state_after : LexState,
      complete : Bool,
    ) : Nil
      previous = @cache[@line]?
      @cached_span_count -= previous.not_nil!.spans.size if previous
      entry = CachedLine.new(spans, start_offset, end_offset, state_before, state_after, complete)
      @cache[@line] = entry
      @cached_span_count += spans.size

      while @cache.size > @max_cached_lines || @cached_span_count > @max_cached_spans
        oldest_line = @cache.first_key
        removed = @cache.delete(oldest_line)
        @cached_span_count -= removed.not_nil!.spans.size if removed
      end
    end

    private def increment_column : Nil
      if @line_column >= @max_line_codepoints
        # Stop retaining spans, but keep reading quote/comment delimiters so
        # the next line starts with a known state when possible.
        @line_unknown = true
        @line_spans.clear
      end
      @line_column += 1 if @line_column < Int32::MAX
    end

    private def identifier_start?(char : Char) : Bool
      char == '_' || char.letter?
    end

    private def identifier_continue?(char : Char) : Bool
      identifier_start?(char) || ascii_digit?(char) || char == '?' || char == '!'
    end

    private def ascii_digit?(char : Char) : Bool
      code = char.ord
      code >= '0'.ord && code <= '9'.ord
    end

    private def number_continue?(char : Char) : Bool
      if char == '+' || char == '-'
        return @previous_line_char == 'e' || @previous_line_char == 'E' ||
          @previous_line_char == 'p' || @previous_line_char == 'P'
      end
      ascii_digit?(char) || char == '_' || char == '.' || char == 'x' || char == 'X' ||
        char == 'o' || char == 'O' || char == 'b' || char == 'B' || char == 'e' ||
        char == 'E' || char == 'p' || char == 'P'
    end

    private def percent_literal_start?(char : Char) : Bool
      char == '(' || char == '[' || char == '{' || char == '<' || char == '"' ||
        char == '\'' || char == 'q' || char == 'Q' || char == 'r' || char == 'R' ||
        char == 'w' || char == 'W' || char == 'i' || char == 'I' || char == 's' || char == 'x' || char == 'X'
    end
  end
end
