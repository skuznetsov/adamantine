require "crystal_tui"

require "../adamantine/buffer_search"
require "../adamantine/buffer_replace"
require "../adamantine/piece_tree_replace"
require "../adamantine/lsp_line_source"

module Adamantine
  # The application-owned editor behavior for indentation.  The underlying
  # TextEditor keeps the piece tree and history private, so this subclass uses
  # the same local edit primitives instead of replacing the document string.
  class EditingTextEditor < Tui::TextEditor
    PREFIX_SCAN_CHUNK          =    1024
    REPLACE_MAX_CHANGES        = 100_000
    REPLACE_MIN_OUTPUT_BYTES   = 16_i64 * 1024 * 1024
    REPLACE_BATCH_SOURCE_BYTES = 8 * 1024
    REPLACE_BATCH_OUTPUT_BYTES = 64 * 1024

    property auto_indent : Bool = true

    # Capture an O(1), read-only root for in-file search.  The search engine
    # reads bounded codepoint chunks and never needs the compatibility `text`
    # or `lines` getters.
    def search_source : BufferSearch::Source
      BufferSearch::Source.new(@buffer)
    end

    # Used by the search scheduler before capturing a source snapshot.
    def search_byte_length : Int32
      @buffer.byte_length
    end

    # Capture an O(1), read-only source for LSP post-processing.  Consumers
    # stream lines from this snapshot instead of invoking TextEditor's
    # compatibility `lines` materializer.
    def lsp_line_source : BufferLines::Source
      BufferLines::Source.new(@buffer.snapshot)
    end

    # Replace literal occurrences in one undoable transaction.  Matching is
    # performed against an O(1) structural source snapshot and all edits are
    # prepared on a detached piece-tree fork.  The live editor is untouched
    # until the complete bounded operation has succeeded.
    def replace_literal(
      old_text : String,
      new_text : String,
      flags : ReplaceUtils::ReplaceFlags,
      *,
      max_changes : Int32 = REPLACE_MAX_CHANGES,
      max_output_bytes : Int64? = nil,
    ) : Bool
      return false if old_text.empty?
      raise ArgumentError.new("replace query must be valid UTF-8") unless old_text.valid_encoding?
      raise ArgumentError.new("replace replacement must be valid UTF-8") unless new_text.valid_encoding?
      raise ArgumentError.new("replace match limit must be positive") if max_changes <= 0

      original_bytes = @buffer.byte_length
      output_limit = max_output_bytes || [original_bytes.to_i64, REPLACE_MIN_OUTPUT_BYTES].max
      raise ArgumentError.new("replace output limit must be positive") if output_limit <= 0
      raise ArgumentError.new("replace output limit exceeded") if original_bytes.to_i64 > output_limit

      source = BufferSearch::Source.new(@buffer)
      original_snapshot = @buffer.snapshot
      candidate = @buffer.replace_fork
      processed_matches = 0
      changed = false
      candidate_bytes = original_bytes.to_i64
      delta = 0_i64

      # Nearby matches are coalesced into one bounded tree splice.  This keeps
      # dense replace-all from repeatedly splitting and rejoining the same
      # small neighborhood while keeping only bounded batch buffers live.
      batch_start : Int32? = nil
      batch_end = 0
      batch_last_end = 0
      batch_output = IO::Memory.new
      batch_output_bytes = 0

      flush_batch = -> : Nil do
        if start_byte = batch_start
          replacement = batch_output.to_s
          candidate_start = start_byte.to_i64 + delta
          candidate_finish = batch_end.to_i64 + delta
          raise IndexError.new("replacement batch outside candidate") unless candidate_start >= 0 && candidate_finish >= candidate_start && candidate_finish <= candidate.byte_length

          candidate_start_byte, candidate_finish_byte, candidate_replacement = atomic_replace_span(
            candidate,
            candidate_start.to_i32,
            candidate_finish.to_i32,
            replacement
          )
          original_span = batch_end - start_byte
          batch_delta = replacement.bytesize - original_span
          projected_bytes = candidate_bytes + batch_delta
          if projected_bytes > output_limit || projected_bytes > Int32::MAX
            raise ArgumentError.new("replace output limit exceeded")
          end

          candidate_span = candidate_finish_byte - candidate_start_byte
          candidate_range = candidate.slice(candidate_start_byte, candidate_span)
          candidate.replace_range_atomic(candidate_start_byte, candidate_span, candidate_replacement) unless candidate_range == candidate_replacement
          delta += batch_delta
          candidate_bytes = projected_bytes

          batch_start = nil
          batch_end = 0
          batch_last_end = 0
          batch_output = IO::Memory.new
          batch_output_bytes = 0
        end
      end

      BufferReplace.each_match(source, old_text, new_text, flags) do |match|
        processed_matches += 1
        if processed_matches > max_changes
          raise ArgumentError.new("replace match limit exceeded (#{max_changes})")
        end

        next if match.original == match.replacement

        # Check the projected document size before reading a gap or appending
        # to the pending batch.  A later flush must not be the first point at
        # which an output-limit violation is discovered: doing the check here
        # keeps preparation failure-atomic even when earlier batches already
        # committed into the detached candidate.
        pending_batch_delta = if start_byte = batch_start
                                batch_output_bytes.to_i64 - (batch_end - start_byte).to_i64
                              else
                                0_i64
                              end
        match_delta = match.replacement.bytesize.to_i64 - (match.end_byte - match.start_byte).to_i64
        projected_bytes = candidate_bytes + pending_batch_delta + match_delta
        if projected_bytes < 0 || projected_bytes > output_limit || projected_bytes > Int32::MAX
          raise ArgumentError.new("replace output limit exceeded")
        end

        if start_byte = batch_start
          source_span = match.end_byte - start_byte
          if source_span > REPLACE_BATCH_SOURCE_BYTES
            flush_batch.call
          else
            gap = original_replace_slice(batch_last_end, match.start_byte)
            projected_batch_bytes = batch_output_bytes + gap.bytesize + match.replacement.bytesize
            if projected_batch_bytes + 2 > REPLACE_BATCH_OUTPUT_BYTES
              flush_batch.call
            else
              batch_output.write(gap.to_slice)
              batch_output.write(match.replacement.to_slice)
              batch_output_bytes = projected_batch_bytes
              batch_end = match.end_byte
              batch_last_end = match.end_byte
              next
            end
          end
        end

        batch_start = match.start_byte
        batch_end = match.end_byte
        batch_last_end = match.end_byte
        batch_output = IO::Memory.new
        batch_output.write(match.replacement.to_slice)
        batch_output_bytes = match.replacement.bytesize
        changed = true
      end

      flush_batch.call

      return false unless changed
      return false unless @buffer.same_state?(original_snapshot)

      cursor_line = @cursor.line
      cursor_col = @cursor.col
      line_ending = replacement_line_ending(candidate)

      begin_edit(nil)
      @buffer.adopt_replace_fork!(candidate)
      @line_ending = line_ending
      @cursor.line = cursor_line.clamp(0, line_count - 1)
      @cursor.col = cursor_col.clamp(0, line_length(@cursor.line))
      @selection = nil
      text_changed(TextChange.full)
      true
    end

    # Return bounded, context-rich samples without materializing the document.
    def replace_previews(
      old_text : String,
      new_text : String,
      flags : ReplaceUtils::ReplaceFlags,
      *,
      limit : Int32 = BufferReplace::MAX_PREVIEW_SAMPLES,
    ) : Array(String)
      return [] of String if old_text.empty? || limit <= 0

      source = BufferSearch::Source.new(@buffer)
      BufferReplace.preview(source, old_text, new_text, flags, limit)
    end

    # Keep the setting's invariant at the editor boundary as well as in the
    # settings/configuration layer.  The inherited property is still the
    # source of truth used by the widget's tab rendering and editing code.
    def tab_size=(value : Int32) : Int32
      @tab_size = value.clamp(1, 8)
    end

    # Insert one configured indentation unit at the caret, or indent all
    # touched lines of a non-empty selection.  A command is one history entry.
    def indent : Bool
      selection = active_indentation_selection
      unless selection
        width = indentation_width
        insert_text(" " * width)
        return true
      end

      lines = indentation_lines(selection)
      return false if lines.empty?

      width = indentation_width
      changes = {} of Int32 => Int32
      begin_edit(nil)
      lines.reverse_each do |line|
        @buffer.insert(byte_offset(line, 0), " " * width)
        changes[line] = width
      end
      update_positions_after_indentation(selection, changes, adding: true)
      text_changed(TextChange.full)
      true
    end

    # Remove up to one configured indentation unit from each touched line.
    # A leading tab is one indentation unit for this command.  Work out all
    # removals before opening an undo entry so a no-op dedent has no history.
    def dedent : Bool
      selection = active_indentation_selection
      lines = indentation_lines(selection)
      removals = {} of Int32 => Int32
      lines.each do |line|
        if count = dedent_length(line)
          removals[line] = count
        end
      end
      return false if removals.empty?

      begin_edit(nil)
      removals.keys.sort.reverse_each do |line|
        count = removals[line]
        delete_buffer_range(byte_offset(line, 0), count)
      end
      update_positions_after_indentation(selection, removals, adding: false)
      text_changed(TextChange.full)
      true
    end

    # Split at the selection start (or caret) and copy only the whitespace
    # preceding that position.  This intentionally has no language-aware
    # behavior: it preserves the existing line's leading whitespace only.
    def insert_newline : Nil
      selection_start = if selection = @selection
                          normalized = selection.normalize
                          {normalized.start_line, normalized.start_col}
                        else
                          {@cursor.line, @cursor.col}
                        end
      indentation = @auto_indent ? leading_whitespace_before(selection_start[0], selection_start[1]) : ""

      # Each Enter keypress is an independent command, including repeated
      # presses on the same line; do not use the base editor's coalescing kind.
      begin_edit(nil)
      selection_change = delete_selection_content(false) if @selection
      start_position = selection_change.try(&.[0]) || current_text_position
      finish_position = selection_change.try(&.[1]) || start_position
      exact = selection_change.try(&.[2]) != false
      offset = byte_offset(@cursor.line, @cursor.col)
      logical = "\n#{indentation}"
      inserted = encode_newlines(logical, offset)
      @buffer.insert(offset, inserted)
      @cursor.line += 1
      @cursor.col = indentation.each_char.size
      text_changed(exact ? TextChange.new(start_position, finish_position, inserted) : TextChange.full)
    end

    private def indentation_width : Int32
      @tab_size.clamp(1, 8)
    end

    # A match touching one half of a CRLF pair cannot be passed directly to
    # PieceTreeBuffer: its public range validator intentionally rejects a
    # boundary inside the pair.  Widen the atomic range to the whole pair and
    # put the untouched byte back into the replacement.  The resulting bytes
    # are exactly the logical partial edit (for example, CRLF with LF -> Q is
    # CRQ), while the tree never observes an invalid intermediate boundary.
    private def original_replace_slice(start_byte : Int32, end_byte : Int32) : String
      return "" if start_byte == end_byte

      safe_start = start_byte
      trim_prefix = 0
      if safe_start > 0 && @buffer.byte_at_offset(safe_start) == '\n'.ord.to_u8 && @buffer.byte_at_offset(safe_start - 1) == '\r'.ord.to_u8
        safe_start -= 1
        trim_prefix = 1
      end

      safe_finish = end_byte
      trim_suffix = 0
      if safe_finish < @buffer.byte_length && safe_finish > 0 && @buffer.byte_at_offset(safe_finish) == '\n'.ord.to_u8 && @buffer.byte_at_offset(safe_finish - 1) == '\r'.ord.to_u8
        safe_finish += 1
        trim_suffix = 1
      end

      chunk = @buffer.slice(safe_start, safe_finish - safe_start)
      chunk.byte_slice(trim_prefix, chunk.bytesize - trim_prefix - trim_suffix)
    end

    private def atomic_replace_span(
      candidate : Tui::PieceTreeBuffer,
      raw_start_byte : Int32,
      raw_end_byte : Int32,
      replacement : String,
    ) : Tuple(Int32, Int32, String)
      start_byte = raw_start_byte
      end_byte = raw_end_byte

      if start_byte > 0 && candidate.byte_at_offset(start_byte) == '\n'.ord.to_u8 && candidate.byte_at_offset(start_byte - 1) == '\r'.ord.to_u8
        start_byte -= 1
        replacement = "\r" + replacement
      end

      if end_byte < candidate.byte_length && end_byte > 0 && candidate.byte_at_offset(end_byte) == '\n'.ord.to_u8 && candidate.byte_at_offset(end_byte - 1) == '\r'.ord.to_u8
        end_byte += 1
        replacement += "\n"
      end

      {start_byte, end_byte, replacement}
    end

    private def replacement_line_ending(candidate : Tui::PieceTreeBuffer) : String
      source = BufferSearch::Source.new(candidate)
      codepoint_offset = 0
      pending_cr = false

      while codepoint_offset < source.codepoint_length
        count = Math.min(BufferSearch::SCAN_CHUNK_CODEPOINTS, source.codepoint_length - codepoint_offset)
        chunk = source.slice_codepoints(codepoint_offset, count)
        chunk.each_byte do |byte|
          if pending_cr
            return "\r\n" if byte == '\n'.ord.to_u8
            return "\r"
          end

          if byte == '\r'.ord.to_u8
            pending_cr = true
          elsif byte == '\n'.ord.to_u8
            return "\n"
          end
        end
        codepoint_offset += chunk.size
      end

      pending_cr ? "\r" : @line_ending
    end

    private def active_indentation_selection : Tui::TextEditor::Selection?
      selection = @selection
      return nil unless selection
      return nil if selection.empty?
      selection
    end

    private def indentation_lines(selection : Tui::TextEditor::Selection?) : Array(Int32)
      unless selection
        return [@cursor.line]
      end

      normalized = selection.normalize
      last_line = normalized.end_line
      if last_line > normalized.start_line && normalized.end_col == 0
        last_line -= 1
      end
      return [] of Int32 if last_line < normalized.start_line
      (normalized.start_line..last_line).to_a
    end

    private def dedent_length(line : Int32) : Int32?
      first = @buffer.character_at(line, 0)
      return 1 if first == '\t'
      return nil unless first == ' '

      spaces = 1
      while spaces < indentation_width
        break unless @buffer.character_at(line, spaces) == ' '
        spaces += 1
      end
      spaces
    end

    private def update_positions_after_indentation(selection : Tui::TextEditor::Selection?, changes : Hash(Int32, Int32), *, adding : Bool) : Nil
      if original = selection
        start_line, start_col = adjust_position(original.start_line, original.start_col, changes, adding)
        end_line, end_col = adjust_position(original.end_line, original.end_col, changes, adding)
        @selection = Tui::TextEditor::Selection.new(start_line, start_col, end_line, end_col)
      else
        @selection = nil
      end

      @cursor.line, @cursor.col = adjust_position(@cursor.line, @cursor.col, changes, adding)
      @cursor.col = @cursor.col.clamp(0, line_length(@cursor.line))
    end

    private def adjust_position(line : Int32, col : Int32, changes : Hash(Int32, Int32), adding : Bool) : Tuple(Int32, Int32)
      delta = changes[line]?
      return {line, col} unless delta

      if adding
        {line, col > 0 ? col + delta : col}
      else
        {line, [col - delta, 0].max}
      end
    end

    private def leading_whitespace_before(line : Int32, column : Int32) : String
      limit = column.clamp(0, line_length(line))
      return "" if limit == 0

      String.build do |io|
        offset = 0
        while offset < limit
          chunk = @buffer.line_slice(line, offset, Math.min(PREFIX_SCAN_CHUNK, limit - offset))
          break if chunk.empty?

          consumed = 0
          stopped = false
          chunk.each_char do |char|
            unless char == ' ' || char == '\t'
              stopped = true
              break
            end
            io << char
            consumed += 1
          end

          offset += consumed
          break if stopped || consumed < chunk.size
        end
      end
    end
  end
end
