require "json"

require "./editing_text_editor"
require "./piece_tree_replace"
require "./text_coordinates"
require "./inline_edit_preview"

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

    private struct ParsedPosition
      getter line : Int32
      getter character : Int32
      getter codepoint : Int32

      def initialize(@line : Int32, @character : Int32, @codepoint : Int32)
      end
    end

    # The source index is assigned once while parsing the original LSP batch.
    # Selection and subset composition carry this identity; they never infer
    # edit identity from a rendered diff row.
    private struct ParsedEdit
      getter source_index : Int32
      getter start : ParsedPosition
      getter finish : ParsedPosition
      getter replacement : String
      getter original_start_byte : Int32
      getter original_end_byte : Int32

      def initialize(
        @source_index : Int32,
        @start : ParsedPosition,
        @finish : ParsedPosition,
        @replacement : String,
        @original_start_byte : Int32,
        @original_end_byte : Int32,
      )
      end

      def with_source_index(source_index : Int32) : ParsedEdit
        ParsedEdit.new(source_index, @start, @finish, @replacement.dup, @original_start_byte, @original_end_byte)
      end
    end

    # A prepared edit batch.  The candidate and snapshot are intentionally
    # private: callers can inspect only bounded preview data and scalar state,
    # then hand the opaque plan back to its owner for guarded application.
    class Plan
      getter change_count : Int32

      @owner : EditingTextEditor
      @original : Tui::PieceTreeBuffer::Snapshot
      @original_source : Tui::PieceTreeBuffer
      @candidate : Tui::PieceTreeBuffer
      @candidate_line_ending : String
      @preview : Array(String)
      @preview_spans : Array(InlineEditPreview::EditSpan)
      @source_edits : Array(ParsedEdit)
      @changed : Bool
      @applied : Bool = false

      protected def initialize(
        @owner : EditingTextEditor,
        @original : Tui::PieceTreeBuffer::Snapshot,
        @original_source : Tui::PieceTreeBuffer,
        @candidate : Tui::PieceTreeBuffer,
        @candidate_line_ending : String,
        @preview : Array(String),
        @preview_spans : Array(InlineEditPreview::EditSpan),
        source_edits : Array(ParsedEdit),
        @change_count : Int32,
        @changed : Bool,
      )
        @source_edits = source_edits.map { |edit| edit.with_source_index(edit.source_index) }
      end

      # Return detached strings as well as a detached array so callers cannot
      # mutate any preview state retained by the plan.
      def preview_lines : Array(String)
        @preview.map(&.dup)
      end

      def changed? : Bool
        @changed
      end

      # Build a lazy projection over the sealed roots captured by this plan.
      # The projection is display-only; only apply_document_edits can adopt
      # the candidate and open an undo transaction.
      def inline_preview(title : String = "Proposed edit preview") : InlineEditPreview::Model
        InlineEditPreview::Model.new(@original_source, @candidate, @preview_spans, title, @source_edits.size.to_i32)
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

      protected def original_source_fork : Tui::PieceTreeBuffer
        @original_source.replace_fork
      end

      protected def selected_source_edits(ids : Array(Int32)) : Array(ParsedEdit)?
        return nil if ids.empty? || ids.uniq.size != ids.size

        preview = inline_preview
        return nil unless preview.selective_acceptance_available?

        selected = ids.sort
        valid_ids = @source_edits.map(&.source_index).sort
        return nil unless selected.all? { |id| valid_ids.includes?(id) }
        preview.source_edit_groups.each do |group|
          selected_in_group = group.count { |id| selected.includes?(id) }
          return nil unless selected_in_group == 0 || selected_in_group == group.size
        end

        @source_edits.select { |edit| selected.includes?(edit.source_index) }
      end
    end

    private struct AppliedEdit
      getter edit : ParsedEdit
      getter start_byte : Int32
      getter end_byte : Int32
      getter replacement_bytes : Int32

      def initialize(
        @edit : ParsedEdit,
        @start_byte : Int32,
        @end_byte : Int32,
        @replacement_bytes : Int32,
      )
      end

      def delta : Int64
        @replacement_bytes.to_i64 - (@end_byte - @start_byte).to_i64
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

    private def self.parse_edit!(value : JSON::Any, editor : EditingTextEditor, source_index : Int32) : ParsedEdit
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
        source_index,
        start_position,
        finish_position,
        replacement.dup,
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

    # Preview ranges are whole-line groups rather than the raw LSP ranges.
    # Including one neighbouring line on either side absorbs a replacement
    # that touches a CRLF seam and gives the lazy projection enough context to
    # trim equal prefixes/suffixes. Groups are merged before byte mapping so a
    # batch with adjacent edits cannot create a false context gap.
    private def self.build_preview_spans(
      original : Tui::PieceTreeBuffer,
      candidate : Tui::PieceTreeBuffer,
      edits : Array(ParsedEdit),
      applied : Array(AppliedEdit),
    ) : Array(InlineEditPreview::EditSpan)
      line_count = original.line_count
      raw_groups = [] of Tuple(Int32, Int32, Int32)
      edits.each do |edit|
        first = [edit.start.line - 1, 0].max
        # `last` is exclusive. The extra line after the finish absorbs the
        # suffix of a partially edited finish line and includes the logical
        # empty line after a final newline when the range reaches EOF.
        last = [edit.finish.line + 2, line_count].min
        last = [first + 1, last].max.clamp(0, line_count)
        raw_groups << {first, last, edit.source_index}
      end

      groups = [] of Tuple(Int32, Int32, Array(Int32))
      raw_groups.sort_by { |group| group[0] }.each do |group|
        if prior = groups.last?
          if group[0] <= prior[1]
            groups[-1] = {prior[0], Math.max(prior[1], group[1]), (prior[2] + [group[2]]).uniq.sort}
          else
            groups << {group[0], group[1], [group[2]]}
          end
        else
          groups << {group[0], group[1], [group[2]]}
        end
      end

      spans = [] of InlineEditPreview::EditSpan
      groups.each do |group|
        old_start_line = group[0]
        old_end_line = group[1]
        old_start_byte = original.line_start_offset(old_start_line)
        old_end_byte = if old_end_line < original.line_count
                         original.line_start_offset(old_end_line)
                       else
                         original.byte_length
                       end

        # The group starts before its edits and ends after them, so these
        # cumulative shifts map legal original line boundaries to candidate
        # boundaries. Insertions exactly at the start belong to the changed
        # side; insertions exactly at the end are included in the changed
        # side. Non-empty edits use their original end for both rules.
        new_start_byte = mapped_preview_boundary(old_start_byte, applied, candidate, false)
        new_end_byte = mapped_preview_boundary(old_end_byte, applied, candidate, true)
        new_start_byte = preview_boundary(candidate, new_start_byte, true)
        new_end_byte = preview_boundary(candidate, new_end_byte, false)
        new_end_byte = new_start_byte if new_end_byte < new_start_byte

        new_start_line = candidate.line_index_at_offset(new_start_byte)
        new_end_line = preview_line_end(candidate, new_end_byte, old_end_line == original.line_count)
        new_end_line = [new_end_line, candidate.line_count].min.clamp(new_start_line, candidate.line_count)
        spans << InlineEditPreview::EditSpan.new(
          old_start_line,
          old_end_line,
          new_start_line,
          new_end_line,
          group[2],
        )
      end
      spans
    end

    private def self.mapped_preview_boundary(
      boundary : Int32,
      applied : Array(AppliedEdit),
      candidate : Tui::PieceTreeBuffer,
      include_at_boundary : Bool,
    ) : Int32
      shift = 0_i64
      applied.each do |item|
        edit = item.edit
        include_edit = if edit.original_start_byte == edit.original_end_byte
                         include_at_boundary ? edit.original_start_byte <= boundary : edit.original_start_byte < boundary
                       else
                         edit.original_end_byte <= boundary
                       end
        shift += item.delta if include_edit
      end
      (boundary.to_i64 + shift).clamp(0, candidate.byte_length.to_i64).to_i32
    end

    private def self.preview_line_end(
      buffer : Tui::PieceTreeBuffer,
      boundary : Int32,
      include_final_empty : Bool,
    ) : Int32
      if boundary >= buffer.byte_length
        # EOF is also the start of the logical empty line after a final
        # newline. Preserve whether the original group included that line;
        # a byte boundary alone cannot distinguish the two half-open spans.
        return buffer.line_count if include_final_empty
        return buffer.line_index_at_offset(buffer.byte_length)
      end

      line = buffer.line_index_at_offset(boundary)
      if buffer.line_start_offset(line) == boundary
        line
      else
        [line + 1, buffer.line_count].min
      end
    end

    # A replacement may itself end in CR immediately before an untouched LF.
    # The resulting candidate then has a CRLF seam even when the original LSP
    # range was an LF-only insertion. Keep line lookup on a legal tree
    # boundary and include the seam in the affected virtual span.
    private def self.preview_boundary(buffer : Tui::PieceTreeBuffer, offset : Int32, start : Bool) : Int32
      return offset unless offset > 0 && offset < buffer.byte_length
      if buffer.byte_at_offset(offset) == '\n'.ord.to_u8 && buffer.byte_at_offset(offset - 1) == '\r'.ord.to_u8
        return start ? offset - 1 : offset + 1
      end
      offset
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
      original_source = editor.safe_document_edits_replace_fork
      parsed = [] of ParsedEdit
      replacement_bytes = 0_i64
      edits.each_with_index do |raw, index|
        edit = parse_edit!(raw, editor, index.to_i32)
        replacement_bytes += edit.replacement.bytesize
        argument_error("replacement bytes exceed #{MAX_REPLACEMENT_BYTES}") if replacement_bytes > MAX_REPLACEMENT_BYTES
        parsed << edit
      end
      reject_overlaps!(parsed)

      compose_plan(editor, original_snapshot, original_source, parsed)
    end

    # Recompose a chosen source-edit subset from the plan's captured original
    # root. The incoming ids are checked against indivisible display groups,
    # then the already parsed ranges/replacements are carried forward; the
    # live editor is never reparsed into a new coordinate frame.
    def self.prepare_selected(
      editor : EditingTextEditor,
      plan : Plan,
      selected_ids : Array(Int32),
    ) : Plan?
      return nil unless plan.current_for?(editor)
      selected = plan.selected_source_edits(selected_ids)
      return nil unless selected

      reindexed = selected.not_nil!.each_with_index.map do |edit, index|
        edit.with_source_index(index.to_i32)
      end.to_a
      compose_plan(editor, plan.original_snapshot, plan.original_source_fork, reindexed)
    rescue ex : ArgumentError | IndexError
      nil
    end

    private def self.compose_plan(
      editor : EditingTextEditor,
      original_snapshot : Tui::PieceTreeBuffer::Snapshot,
      original_source : Tui::PieceTreeBuffer,
      parsed : Array(ParsedEdit),
    ) : Plan
      original_bytes = original_source.byte_length.to_i64
      output_limit = Math.min(Int32::MAX.to_i64, original_bytes + MAX_OUTPUT_GROWTH_BYTES)
      candidate = original_source.replace_fork
      applied = [] of AppliedEdit

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
        applied << AppliedEdit.new(edit, start_byte, finish_byte, replacement.bytesize.to_i32)
      end

      # Compare bytes rather than roots: a sequence of individually changing
      # edits can still be a net no-op and must not open an undo transaction.
      # This is necessarily O(document bytes) for a net no-op, but the
      # boundary-safe chunks keep transient comparison memory bounded.
      changed = !same_bytes?(original_source, candidate)
      line_ending = editor.safe_document_edits_replacement_line_ending(candidate)
      previews = build_previews(original_source, parsed)
      preview_spans = build_preview_spans(original_source, candidate, parsed, applied)
      unless editor.safe_document_edits_state_same?(original_snapshot)
        argument_error("document changed during preparation")
      end

      Plan.new(
        editor,
        original_snapshot,
        original_source,
        candidate,
        line_ending,
        previews,
        preview_spans,
        parsed,
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

    # Selective acceptance has the same one-transaction and exact-snapshot
    # guard as full acceptance. Invalid/empty/partial merged-group selections
    # are rejected before candidate construction can reach editor history.
    def apply_selected_document_edits(plan : SafeDocumentEdits::Plan, selected_ids : Array(Int32)) : Bool
      return false unless plan.owned_by?(self)
      return false unless plan.current_for?(self)
      selected_plan = SafeDocumentEdits.prepare_selected(self, plan, selected_ids)
      return false unless selected_plan
      applied = apply_document_edits(selected_plan.not_nil!)
      plan.mark_applied if applied
      applied
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
