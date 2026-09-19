require "json"

require "./editing_text_editor"
require "./piece_tree_replace"
require "./text_coordinates"

module Adamantine
  # Failure-atomic application of one LSP TextEdit batch to one editor.
  #
  # The parser accepts only the plain LSP TextEdit shape.  It resolves every
  # UTF-16 range against the original piece-tree root, prepares a detached
  # candidate, and only then exposes a Plan that can be applied once to its
  # owning editor.
  module SafeDocumentEdits
    MAX_EDITS                 = 4_096
    MAX_REPLACEMENT_BYTES     = 16_i64 * 1024 * 1024
    MAX_OUTPUT_GROWTH_BYTES   = 16_i64 * 1024 * 1024
    MAX_PREVIEW_LINES         =   256
    MAX_PREVIEW_STRING_BYTES  = 4_096
    MAX_PREVIEW_LINE_BYTES    = 4_096
    PREVIEW_TRUNCATION_MARKER = "[truncated]"

    # A prepared edit batch.  The candidate and snapshot are intentionally
    # private: callers can inspect only bounded preview data and scalar state,
    # then hand the opaque plan back to its owner for guarded application.
    class Plan
      getter change_count : Int32

      @owner : EditingTextEditor
      @original : Tui::PieceTreeBuffer::Snapshot
      @candidate : Tui::PieceTreeBuffer
      @candidate_line_ending : String
      @preview : Array(String)
      @changed : Bool
      @applied : Bool = false

      protected def initialize(
        @owner : EditingTextEditor,
        @original : Tui::PieceTreeBuffer::Snapshot,
        @candidate : Tui::PieceTreeBuffer,
        @candidate_line_ending : String,
        @preview : Array(String),
        @change_count : Int32,
        @changed : Bool,
      )
      end

      # Return detached strings as well as a detached array so callers cannot
      # mutate any preview state retained by the plan.
      def preview_lines : Array(String)
        @preview.map(&.dup)
      end

      def changed? : Bool
        @changed
      end

      # These accessors are deliberately limited to the owning editor's
      # adapter.  They are not public plan API and cannot be used to mutate a
      # candidate or snapshot from a caller.
      protected def owned_by?(editor : EditingTextEditor) : Bool
        @owner.same?(editor)
      end

      protected def current_for?(editor : EditingTextEditor) : Bool
        owned_by?(editor) && !@applied && editor.safe_document_edits_state_same?(@original)
      end

      protected def mark_applied : Nil
        @applied = true
      end

      protected def original_snapshot : Tui::PieceTreeBuffer::Snapshot
        @original
      end

      protected def candidate : Tui::PieceTreeBuffer
        @candidate
      end

      protected def candidate_line_ending : String
        @candidate_line_ending
      end
    end

    private struct ParsedPosition
      getter line : Int32
      getter character : Int32
      getter codepoint : Int32

      def initialize(@line : Int32, @character : Int32, @codepoint : Int32)
      end
    end

    private struct ParsedEdit
      getter start : ParsedPosition
      getter finish : ParsedPosition
      getter replacement : String
      getter original_start_byte : Int32
      getter original_end_byte : Int32

      def initialize(
        @start : ParsedPosition,
        @finish : ParsedPosition,
        @replacement : String,
        @original_start_byte : Int32,
        @original_end_byte : Int32,
      )
      end
    end

    private def self.argument_error(message : String) : NoReturn
      raise ArgumentError.new("invalid document edit: #{message}")
    end

    private def self.object!(value : JSON::Any, label : String) : Hash(String, JSON::Any)
      value.as_h
    rescue TypeCastError
      argument_error("#{label} must be an object")
    end

    private def self.integer!(value : JSON::Any?, label : String) : Int32
      argument_error("missing #{label}") unless value
      integer = value.not_nil!.as_i64?
      argument_error("#{label} must be an integer") unless integer
      number = integer.not_nil!
      argument_error("#{label} is outside Int32") unless number >= 0 && number <= Int32::MAX
      number.to_i32
    end

    private def self.string!(value : JSON::Any?, label : String) : String
      argument_error("missing #{label}") unless value
      result = value.not_nil!.as_s?
      argument_error("#{label} must be a string") unless result
      text = result.not_nil!
      argument_error("#{label} must be valid UTF-8") unless text.valid_encoding?
      text
    end

    private def self.reject_unknown!(object : Hash(String, JSON::Any), allowed : Array(String), label : String) : Nil
      object.each_key do |key|
        argument_error("unsupported #{label} field #{key.inspect}") unless allowed.includes?(key)
      end
    end

    private def self.position!(value : JSON::Any?, label : String, editor : EditingTextEditor) : ParsedPosition
      argument_error("missing #{label}") unless value
      object = object!(value.not_nil!, label)
      reject_unknown!(object, ["line", "character"], label)
      line = integer!(object["line"]?, "#{label}.line")
      character = integer!(object["character"]?, "#{label}.character")
      argument_error("#{label}.line is outside document") if line >= editor.line_count_for_safe_document_edits

      begin
        codepoint = TextCoordinates.utf16_to_codepoint(editor, line, character)
        ParsedPosition.new(line, character, codepoint)
      rescue ex : ArgumentError
        argument_error("#{label}: #{ex.message || "invalid coordinate"}")
      end
    end

    private def self.parse_edit!(value : JSON::Any, editor : EditingTextEditor) : ParsedEdit
      object = object!(value, "edit")
      reject_unknown!(object, ["range", "newText"], "edit")
      range_value = object["range"]?
      argument_error("missing range") unless range_value
      range = object!(range_value.not_nil!, "range")
      reject_unknown!(range, ["start", "end"], "range")
      start_position = position!(range["start"]?, "range.start", editor)
      finish_position = position!(range["end"]?, "range.end", editor)
      replacement = string!(object["newText"]?, "newText")

      start_byte = editor.byte_offset_for_safe_document_edits(start_position.line, start_position.codepoint)
      end_byte = editor.byte_offset_for_safe_document_edits(finish_position.line, finish_position.codepoint)
      argument_error("range is reversed") if start_byte > end_byte

      ParsedEdit.new(
        start_position,
        finish_position,
        replacement,
        start_byte,
        end_byte
      )
    end

    private def self.reject_overlaps!(edits : Array(ParsedEdit)) : Nil
      ordered = edits.sort_by { |edit| {edit.original_start_byte, edit.original_end_byte} }
      previous : ParsedEdit? = nil
      ordered.each do |current|
        if prior = previous
          if prior.original_end_byte > current.original_start_byte
            argument_error("overlapping ranges")
          end

          same_position = prior.original_start_byte == current.original_start_byte
          boundary_insertion = (prior.original_start_byte == prior.original_end_byte && prior.original_end_byte == current.original_start_byte) ||
                               (current.original_start_byte == current.original_end_byte && current.original_start_byte == prior.original_end_byte)
          argument_error("ambiguous same-position edits") if same_position || boundary_insertion
        end
        previous = current
      end
    end

    private def self.continuation_byte?(byte : UInt8) : Bool
      (byte & 0xc0_u8) == 0x80_u8
    end

    private def self.utf8_prefix(text : String, max_bytes : Int32) : String
      return text if text.bytesize <= max_bytes
      take = max_bytes
      while take > 0 && take < text.bytesize && continuation_byte?(text.byte_at(take))
        take -= 1
      end
      text.byte_slice(0, take)
    end

    private def self.utf8_suffix(text : String, max_bytes : Int32) : String
      return text if text.bytesize <= max_bytes
      start = text.bytesize - max_bytes
      while start < text.bytesize && continuation_byte?(text.byte_at(start))
        start += 1
      end
      text.byte_slice(start, text.bytesize - start)
    end

    private def self.bounded_text(text : String, max_bytes : Int32 = MAX_PREVIEW_STRING_BYTES) : String
      return text if text.bytesize <= max_bytes
      marker = " #{PREVIEW_TRUNCATION_MARKER} "
      available = Math.max(max_bytes - marker.bytesize, 2)
      head = utf8_prefix(text, available // 2)
      tail = utf8_suffix(text, available - head.bytesize)
      "#{head}#{marker}#{tail}"
    end

    private def self.valid_slice_boundary?(buffer : Tui::PieceTreeBuffer, offset : Int32) : Bool
      return true if offset == 0 || offset == buffer.byte_length

      byte = buffer.byte_at_offset(offset).not_nil!
      return false if continuation_byte?(byte)

      byte != '\n'.ord.to_u8 || buffer.byte_at_offset(offset - 1) != '\r'.ord.to_u8
    end

    # PieceTreeBuffer#slice deliberately rejects a boundary inside a UTF-8
    # scalar or CRLF pair.  Keep bounded comparisons byte-oriented, but move
    # each chunk end back to a legal boundary in both roots before slicing.
    private def self.safe_chunk_length(
      left : Tui::PieceTreeBuffer,
      right : Tui::PieceTreeBuffer,
      start_byte : Int32,
      requested : Int32,
    ) : Int32
      count = requested
      while count > 0
        finish = start_byte + count
        return count if valid_slice_boundary?(left, finish) && valid_slice_boundary?(right, finish)
        count -= 1
      end
      0
    end

    private def self.safe_single_chunk_length(
      buffer : Tui::PieceTreeBuffer,
      start_byte : Int32,
      requested : Int32,
    ) : Int32
      count = requested
      while count > 0
        return count if valid_slice_boundary?(buffer, start_byte + count)
        count -= 1
      end
      0
    end

    private def self.raw_buffer_slice(
      buffer : Tui::PieceTreeBuffer,
      start_byte : Int32,
      length : Int32,
    ) : String
      return "" if length == 0

      finish_byte = start_byte + length
      safe_start = start_byte
      trim_prefix = 0
      if safe_start > 0 && buffer.byte_at_offset(safe_start) == '\n'.ord.to_u8 && buffer.byte_at_offset(safe_start - 1) == '\r'.ord.to_u8
        safe_start -= 1
        trim_prefix = 1
      end

      safe_finish = finish_byte
      trim_suffix = 0
      if safe_finish < buffer.byte_length && safe_finish > 0 && buffer.byte_at_offset(safe_finish) == '\n'.ord.to_u8 && buffer.byte_at_offset(safe_finish - 1) == '\r'.ord.to_u8
        safe_finish += 1
        trim_suffix = 1
      end

      chunk = buffer.slice(safe_start, safe_finish - safe_start)
      chunk.byte_slice(trim_prefix, chunk.bytesize - trim_prefix - trim_suffix)
    end

    private def self.bounded_buffer_text(
      buffer : Tui::PieceTreeBuffer,
      start_byte : Int32,
      length : Int32,
      max_bytes : Int32 = MAX_PREVIEW_STRING_BYTES,
    ) : String
      return "" if length == 0
      return raw_buffer_slice(buffer, start_byte, length) if length <= max_bytes

      marker = " #{PREVIEW_TRUNCATION_MARKER} "
      available = Math.max(max_bytes - marker.bytesize, 2)
      head_bytes = Math.min(available // 2, length)
      while head_bytes > 0 && head_bytes < length && continuation_byte?(buffer.byte_at_offset(start_byte + head_bytes).not_nil!)
        head_bytes -= 1
      end
      tail_bytes = Math.min(available - head_bytes, length - head_bytes)
      tail_start = start_byte + length - tail_bytes
      while tail_start < start_byte + length && continuation_byte?(buffer.byte_at_offset(tail_start).not_nil!)
        tail_start += 1
      end
      head = head_bytes > 0 ? raw_buffer_slice(buffer, start_byte, head_bytes) : ""
      tail_length = start_byte + length - tail_start
      tail = tail_length > 0 ? raw_buffer_slice(buffer, tail_start, tail_length) : ""
      "#{head}#{marker}#{tail}"
    end

    private def self.preview_row(prefix : String, value : String) : String
      rendered = value.inspect
      available = MAX_PREVIEW_LINE_BYTES - prefix.bytesize
      available = 0 if available < 0
      rendered = bounded_text(rendered, available) if rendered.bytesize > available
      line = "#{prefix}#{rendered}"
      # `bounded_text` is intentionally also applied to the final assembled
      # line: String#inspect can expand controls after the source fragment was
      # bounded, and callers need a hard, visible horizontal limit.
      bounded_text(line, MAX_PREVIEW_LINE_BYTES)
    end

    private def self.preview_header(index : Int32, edit : ParsedEdit) : String
      "edit #{index + 1} @ #{edit.start.line}:#{edit.start.character}..#{edit.finish.line}:#{edit.finish.character}"
    end

    private def self.preview_rows(
      index : Int32,
      buffer : Tui::PieceTreeBuffer,
      edit : ParsedEdit,
    ) : Array(String)
      before = bounded_buffer_text(buffer, edit.original_start_byte, edit.original_end_byte - edit.original_start_byte)
      [
        bounded_text(preview_header(index, edit), MAX_PREVIEW_LINE_BYTES),
        preview_row("- ", before),
        preview_row("+ ", bounded_text(edit.replacement)),
      ]
    end

    private def self.build_previews(buffer : Tui::PieceTreeBuffer, edits : Array(ParsedEdit)) : Array(String)
      previews = [] of String
      rendered_edits = 0
      edits.each_with_index do |edit, index|
        break if previews.size + 3 > MAX_PREVIEW_LINES - 1
        previews.concat(preview_rows(index.to_i32, buffer, edit))
        rendered_edits += 1
      end
      if rendered_edits < edits.size
        previews << "#{PREVIEW_TRUNCATION_MARKER} #{edits.size - rendered_edits} edit previews omitted"
      end
      previews
    end

    private def self.same_bytes?(left : Tui::PieceTreeBuffer, right : Tui::PieceTreeBuffer) : Bool
      return false unless left.byte_length == right.byte_length
      offset = 0
      while offset < left.byte_length
        requested = Math.min(64 * 1024, left.byte_length - offset)
        count = safe_chunk_length(left, right, offset, requested)
        return false if count == 0
        return false unless left.slice(offset, count) == right.slice(offset, count)
        offset += count
      end
      true
    end

    # Implementation body is reopened onto EditingTextEditor below so the
    # adapter can use its existing private history and CRLF seams.
    def self.prepare(editor : EditingTextEditor, edits : Array(JSON::Any)) : Plan
      argument_error("edit count exceeds maximum #{MAX_EDITS}") if edits.size > MAX_EDITS

      original_snapshot = editor.safe_document_edits_snapshot
      parsed = [] of ParsedEdit
      replacement_bytes = 0_i64
      edits.each do |raw|
        edit = parse_edit!(raw, editor)
        replacement_bytes += edit.replacement.bytesize
        argument_error("replacement bytes exceed #{MAX_REPLACEMENT_BYTES}") if replacement_bytes > MAX_REPLACEMENT_BYTES
        parsed << edit
      end
      reject_overlaps!(parsed)

      original_bytes = editor.safe_document_edits_byte_length.to_i64
      output_limit = Math.min(Int32::MAX.to_i64, original_bytes + MAX_OUTPUT_GROWTH_BYTES)
      candidate = editor.safe_document_edits_replace_fork

      # Descending original offsets keep all remaining ranges valid while the
      # detached candidate grows and shrinks.
      ordered = parsed.sort_by { |edit| {-edit.original_start_byte, -edit.original_end_byte} }
      ordered.each do |edit|
        start_byte, finish_byte, replacement = editor.safe_document_edits_atomic_span(
          candidate,
          edit.original_start_byte,
          edit.original_end_byte,
          edit.replacement
        )
        span = finish_byte - start_byte
        projected = candidate.byte_length.to_i64 - span.to_i64 + replacement.bytesize
        argument_error("output bytes exceed limit") if projected < 0 || projected > output_limit

        unless same_range?(candidate, start_byte, span, replacement)
          candidate.replace_range_atomic(start_byte, span, replacement)
        end
      end

      # Compare bytes rather than roots: a sequence of individually changing
      # edits can still be a net no-op and must not open an undo transaction.
      # This is necessarily O(document bytes) for a net no-op, but the
      # boundary-safe chunks keep transient comparison memory bounded.
      changed = !same_bytes?(editor.safe_document_edits_live_buffer, candidate)
      line_ending = editor.safe_document_edits_replacement_line_ending(candidate)
      previews = build_previews(editor.safe_document_edits_live_buffer, parsed)
      unless editor.safe_document_edits_state_same?(original_snapshot)
        argument_error("document changed during preparation")
      end

      Plan.new(
        editor,
        original_snapshot,
        candidate,
        line_ending,
        previews,
        parsed.size.to_i32,
        changed
      )
    end

    private def self.same_range?(buffer : Tui::PieceTreeBuffer, start_byte : Int32, length : Int32, replacement : String) : Bool
      return false unless length == replacement.bytesize
      offset = 0
      while offset < length
        requested = Math.min(64 * 1024, length - offset)
        count = safe_single_chunk_length(buffer, start_byte + offset, requested)
        return false if count == 0
        return false unless buffer.slice(start_byte + offset, count) == replacement.byte_slice(offset, count)
        offset += count
      end
      true
    end
  end

  class EditingTextEditor
    # Public adapter for the sealed one-document LSP edit API.
    def prepare_document_edits(edits : Array(JSON::Any)) : SafeDocumentEdits::Plan
      SafeDocumentEdits.prepare(self, edits)
    end

    # Apply only a plan made by this editor against the exact root captured at
    # preparation time.  The live editor is untouched on every false path.
    def apply_document_edits(plan : SafeDocumentEdits::Plan) : Bool
      return false unless plan.owned_by?(self)
      return false unless plan.current_for?(self)
      return false unless plan.changed?

      # Revalidate immediately before opening history.  begin_edit snapshots
      # the exact original root and cursor once; text_changed publishes once.
      return false unless @buffer.same_state?(plan.original_snapshot)

      cursor_line = @cursor.line
      cursor_col = @cursor.col
      begin_edit(nil)
      @buffer.adopt_replace_fork!(plan.candidate)
      @line_ending = plan.candidate_line_ending
      @cursor.line = cursor_line.clamp(0, line_count - 1)
      @cursor.col = cursor_col.clamp(0, line_length(@cursor.line))
      @selection = nil
      text_changed(TextChange.full)
      plan.mark_applied
      true
    end

    # Narrow protected seams used by SafeDocumentEdits.  Keeping these
    # adapters here avoids materializing the compatibility text/lines getters.
    protected def safe_document_edits_snapshot : Tui::PieceTreeBuffer::Snapshot
      @buffer.snapshot
    end

    protected def safe_document_edits_state_same?(snapshot : Tui::PieceTreeBuffer::Snapshot) : Bool
      @buffer.same_state?(snapshot)
    end

    protected def safe_document_edits_live_buffer : Tui::PieceTreeBuffer
      @buffer
    end

    protected def safe_document_edits_replace_fork : Tui::PieceTreeBuffer
      @buffer.replace_fork
    end

    protected def safe_document_edits_byte_length : Int32
      @buffer.byte_length
    end

    protected def line_count_for_safe_document_edits : Int32
      line_count
    end

    protected def byte_offset_for_safe_document_edits(line : Int32, column : Int32) : Int32
      byte_offset(line, column)
    end

    protected def safe_document_edits_atomic_span(
      candidate : Tui::PieceTreeBuffer,
      start_byte : Int32,
      end_byte : Int32,
      replacement : String,
    ) : Tuple(Int32, Int32, String)
      atomic_replace_span(candidate, start_byte, end_byte, replacement)
    end

    protected def safe_document_edits_replacement_line_ending(candidate : Tui::PieceTreeBuffer) : String
      replacement_line_ending(candidate)
    end
  end
end
