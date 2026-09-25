require "./buffer_search"
require "./replace_utils"

module Adamantine
  # Bounded replacement matching over a stable BufferSearch::Source snapshot.
  #
  # The matcher deliberately uses the same escaped-literal Regex that
  # ReplaceUtils uses for ignore-case replacement.  In particular, it does
  # not implement case folding with String#downcase: PCRE2's Unicode caseless
  # matching is the compatibility authority here.
  module BufferReplace
    MAX_QUERY_BYTES                = 16 * 1024
    MAX_REPLACEMENT_BYTES          = 1 * 1024 * 1024
    MAX_EXPANDED_REPLACEMENT_BYTES = 16 * 1024 * 1024
    MAX_PREVIEW_SAMPLES            =  5
    PREVIEW_CONTEXT_CODEPOINTS     = 80

    struct Match
      getter start_byte : Int32
      getter end_byte : Int32
      getter replacement : String
      getter original : String
      getter start_codepoint : Int32
      getter end_codepoint : Int32

      def initialize(
        @start_byte : Int32,
        @end_byte : Int32,
        @replacement : String,
        @original : String,
        @start_codepoint : Int32,
        @end_codepoint : Int32,
      )
      end
    end

    # Yield non-overlapping matches in original source order.  The returned
    # count is useful to callers that need a bounded match count without
    # retaining every Match.  A non-global replacement stops after one match;
    # preview uses the private scanner in global mode so it can show several
    # samples for a first-only command.
    def self.each_match(
      source : BufferSearch::Source,
      old_text : String,
      new_text : String,
      flags : ReplaceUtils::ReplaceFlags,
      &
    ) : Int32
      return 0 if old_text.empty?
      validate_arguments!(old_text, new_text)

      pattern = replacement_pattern(old_text, flags)
      replacement_zero_refs = flags.ignore_case ? zero_backreference_count(new_text) : 0_i64
      scan(
        source,
        old_text,
        new_text,
        flags,
        pattern,
        global: flags.global,
        evaluate_replacement: true,
        replacement_zero_refs: replacement_zero_refs
      ) { |match| yield match }
    end

    # Build at most five bounded context samples.  This follows the legacy
    # preview behavior by showing several occurrences even when the operation
    # itself is first-only.  The @byte label is intentionally an original
    # source byte offset; computing an LF line/column would require another
    # prefix walk and is not necessary for bounded preview safety.
    def self.preview(
      source : BufferSearch::Source,
      old_text : String,
      new_text : String,
      flags : ReplaceUtils::ReplaceFlags,
      limit : Int32 = MAX_PREVIEW_SAMPLES,
    ) : Array(String)
      return [] of String if limit <= 0 || old_text.empty?
      validate_arguments!(old_text, new_text)

      sample_limit = Math.min(limit, MAX_PREVIEW_SAMPLES)
      pattern = replacement_pattern(old_text, flags)
      previews = [] of String
      scan(
        source,
        old_text,
        new_text,
        flags,
        pattern,
        global: true,
        max_matches: sample_limit,
        evaluate_replacement: false,
        replacement_zero_refs: 0_i64
      ) do |match|
        previews << format_preview(source, match, previews.size, new_text)
      end
      previews
    end

    private def self.validate_arguments!(old_text : String, new_text : String) : Nil
      if old_text.bytesize > MAX_QUERY_BYTES
        raise ArgumentError.new("replace query exceeds #{MAX_QUERY_BYTES} bytes")
      end
      if new_text.bytesize > MAX_REPLACEMENT_BYTES
        raise ArgumentError.new("replace replacement exceeds #{MAX_REPLACEMENT_BYTES} bytes")
      end
    end

    private def self.replacement_pattern(old_text : String, flags : ReplaceUtils::ReplaceFlags) : Regex
      options = flags.ignore_case ? Regex::Options::IGNORE_CASE : Regex::Options::None
      Regex.new(Regex.escape(old_text), options)
    end

    private def self.scan(
      source : BufferSearch::Source,
      old_text : String,
      new_text : String,
      flags : ReplaceUtils::ReplaceFlags,
      pattern : Regex,
      *,
      global : Bool,
      max_matches : Int32? = nil,
      evaluate_replacement : Bool,
      replacement_zero_refs : Int64,
      &
    ) : Int32
      return 0 if max_matches && max_matches.not_nil! <= 0

      total_codepoints = source.codepoint_length
      return 0 if total_codepoints == 0

      # A literal escaped pattern has a fixed codepoint width in the PCRE2
      # UTF matcher.  Retain enough source codepoints to complete a match
      # that starts in the preceding bounded chunk.  The retained String is
      # query-sized (plus one scan chunk), never document-sized.
      query_codepoints = old_text.size
      carry_codepoints = Math.max(query_codepoints - 1, 0)
      carry = ""
      carried_codepoints = 0

      chunk_start_codepoint = 0
      chunk_start_byte = 0
      next_start_byte = 0
      match_count = 0

      while chunk_start_codepoint < total_codepoints
        chunk_count = Math.min(BufferSearch::SCAN_CHUNK_CODEPOINTS, total_codepoints - chunk_start_codepoint)
        chunk = source.slice_codepoints(chunk_start_codepoint, chunk_count)
        window = carry + chunk
        window_base_byte = chunk_start_byte - carry.bytesize
        window_end_byte = chunk_start_byte + chunk.bytesize
        window_base_codepoint = chunk_start_codepoint - carried_codepoints

        search_start_byte = Math.max(next_start_byte, window_base_byte)
        while search_start_byte <= window_end_byte
          local_search_byte = search_start_byte - window_base_byte
          # Match directly in the bounded window.  This avoids allocating a
          # suffix String for every dense match while retaining byte-relative
          # MatchData offsets for exact source spans.
          match_data = pattern.match_at_byte_index(window, local_search_byte)
          break unless match_data

          local_start_byte = match_data.not_nil!.byte_begin
          local_end_byte = match_data.not_nil!.byte_end
          absolute_start_byte = window_base_byte + local_start_byte
          absolute_end_byte = window_base_byte + local_end_byte
          original = window.byte_slice(local_start_byte, local_end_byte - local_start_byte)

          start_codepoint = window_base_codepoint + window.byte_index_to_char_index(local_start_byte).not_nil!
          end_codepoint = start_codepoint + original.size
          replacement = if evaluate_replacement && flags.ignore_case
                          # The escaped query has no capture groups.  Keep
                          # String#sub's native backreference parser so \0,
                          # skipped numeric refs, and named-ref exceptions
                          # remain exactly compatible with ReplaceUtils.
                          validate_expanded_replacement!(new_text, original.bytesize, replacement_zero_refs)
                          original.sub(pattern, new_text)
                        elsif evaluate_replacement
                          # String replacement (unlike Regex replacement) is
                          # literal, including all backslashes and backrefs.
                          new_text
                        else
                          new_text
                        end

          yield Match.new(
            absolute_start_byte,
            absolute_end_byte,
            replacement,
            original,
            start_codepoint,
            end_codepoint
          )
          match_count += 1

          # Replacement matching is non-overlapping and leftmost, exactly as
          # String#sub/gsub.  The next search starts at the original match
          # end, not at a transformed or downcased offset.
          next_start_byte = absolute_end_byte
          return match_count unless global
          if max = max_matches
            return match_count if match_count >= max
          end

          # A non-empty literal query cannot produce an empty Regex match.
          # Keep this guard explicit so a future matcher change cannot spin.
          break if absolute_end_byte <= absolute_start_byte
          search_start_byte = next_start_byte
        end

        processed_byte_end = window_end_byte
        if carry_codepoints > 0
          window_codepoints = window.size
          keep = Math.min(carry_codepoints, window_codepoints)
          drop_codepoints = window_codepoints - keep
          drop_bytes = byte_offset_after_codepoints(window, drop_codepoints)
          carry = window.byte_slice(drop_bytes, window.bytesize - drop_bytes)
          carried_codepoints = keep
        else
          carry = ""
          carried_codepoints = 0
        end

        chunk_start_codepoint += chunk_count
        chunk_start_byte = processed_byte_end
      end

      match_count
    end

    # String#sub expands each unescaped \0 to the complete matched source.
    # The public replacement input is capped at 1 MiB, but a small input such
    # as repeated \0 can otherwise expand one 16 KiB query into gigabytes
    # before the editor's aggregate output guard gets a chance to run.  This
    # conservative per-match bound keeps the native replacement parser while
    # rejecting that amplification before it allocates the result.
    private def self.validate_expanded_replacement!(replacement : String, original_bytes : Int32, zero_refs : Int64) : Nil
      return if zero_refs == 0

      remaining = MAX_EXPANDED_REPLACEMENT_BYTES.to_i64 - replacement.bytesize
      if original_bytes.to_i64 > remaining // zero_refs
        raise ArgumentError.new("expanded replacement exceeds #{MAX_EXPANDED_REPLACEMENT_BYTES} bytes")
      end
    end

    # Count only the native replacement parser's unescaped \0 references.
    # `\\0` is a literal backslash plus zero and must not be counted.  Other
    # backreferences are not expansion sources for the escaped-literal query:
    # numeric groups are absent, while named groups still raise natively.
    private def self.zero_backreference_count(text : String) : Int64
      bytes = text.to_slice
      index = 0
      count = 0_i64
      while index < bytes.size
        if bytes[index] == '\\'.ord.to_u8 && index + 1 < bytes.size
          case bytes[index + 1]
          when '\\'.ord.to_u8
            index += 2
          when '0'.ord.to_u8
            count += 1
            index += 2
          else
            index += 1
          end
        else
          index += 1
        end
      end
      count
    end

    private def self.byte_offset_after_codepoints(text : String, count : Int32) : Int32
      return 0 if count <= 0

      offset = 0
      seen = 0
      text.each_char do |char|
        break if seen >= count
        offset += char.bytesize
        seen += 1
      end
      offset
    end

    private def self.format_preview(
      source : BufferSearch::Source,
      match : Match,
      index : Int32,
      new_text : String,
    ) : String
      total_codepoints = source.codepoint_length
      half_context = PREVIEW_CONTEXT_CODEPOINTS // 2
      context_start = [match.start_codepoint - half_context, 0].max
      context_end = [context_start + PREVIEW_CONTEXT_CODEPOINTS, total_codepoints].min
      if context_end - context_start < PREVIEW_CONTEXT_CODEPOINTS
        context_start = [context_end - PREVIEW_CONTEXT_CODEPOINTS, 0].max
      end

      context = source.slice_codepoints(context_start, context_end - context_start)
      match_offset = match.start_codepoint - context_start
      match_codepoints = match.end_codepoint - match.start_codepoint
      prefix = match_offset > 0 ? context[0, match_offset] : ""
      suffix_start = [match_offset + match_codepoints, context.size].min
      suffix = suffix_start < context.size ? context[suffix_start, context.size - suffix_start] : ""

      rendered_context = "#{preview_excerpt(prefix)}[#{preview_excerpt(match.original, 24)}]#{preview_excerpt(suffix)}"
      rendered_context = escape_preview(rendered_context)
      "#{index + 1}) @#{match.start_byte}: #{rendered_context} (#{preview_excerpt(match.original).inspect} -> #{preview_excerpt(new_text).inspect})"
    end

    private def self.preview_excerpt(text : String, max_codepoints : Int32 = PREVIEW_CONTEXT_CODEPOINTS) : String
      return text if text.size <= max_codepoints

      head = max_codepoints // 2
      tail = max_codepoints - head
      "#{text[0, head]}…#{text[-tail, tail]}"
    end

    private def self.escape_preview(text : String) : String
      text.gsub('\r', "\\r").gsub('\n', "\\n").gsub('\t', " ")
    end
  end
end
