require "crystal_tui"
require "./editing_text_editor"
require "./chat_frontend"

module Adamantine
  module Chat
    # Multiline composer adapter. It deliberately bypasses EditableInput's
    # single-line paste normalization while keeping all mutations inside the
    # existing Unicode-aware TextEditor model.
    class Composer < EditingTextEditor
      getter status : String
      getter mutation_revision : UInt64
      @on_status_change : Proc(String, Nil)?
      @on_change_handler : Proc(Nil)?

      def initialize(id : String? = "chat-composer")
        super(id)
        @status = ""
        @mutation_revision = 0_u64
        @on_change_handler = nil
        @on_change = -> {
          @mutation_revision &+= 1_u64
          @on_change_handler.try(&.call)
        }
        self.show_line_numbers = false
        self.show_fold_gutter = false
        self.show_scrollbar = false
        self.word_wrap = true
        self.auto_indent = false
        self.on_change { }
      end

      def on_status_change(&block : String -> Nil) : Nil
        @on_status_change = block
      end

      # TextEditor invokes this callback for edits, deletion, undo, redo and
      # replacement. A monotonic revision detects ABA edits even when the
      # visible text and cursor later return to their previous values.
      def on_change(&block : -> Nil) : Nil
        @on_change_handler = block
      end

      def insert_char(char : Char, record_undo : Bool = true) : Nil
        prepared = prepare_insert(char.to_s)
        return unless prepared
        return if prepared.not_nil!.empty?

        clear_status
        super(char, record_undo)
      end

      def insert_text(text : String) : Nil
        prepared = prepare_insert(text)
        return unless prepared

        clear_status
        super(prepared.not_nil!)
      end

      def insert_newline : Nil
        prepared = prepare_insert("\n")
        return unless prepared

        clear_status
        super
      end

      def paste(text : String) : Nil
        insert_text(text)
      end

      # A panel resize can shrink the viewport without changing the draft or
      # cursor. Recompute scrolling from geometry alone so the active caret
      # remains reachable; this does not mutate text, selection, or revision.
      def synchronize_viewport(rect : Tui::Rect) : Nil
        self.rect = rect
        ensure_cursor_visible unless rect.empty?
      end

      def reject_oversized_paste : Nil
        set_status("Draft exceeds 16 KiB.")
      end

      def text=(content : String) : Nil
        prepared = prepare_replacement(content)
        return unless prepared

        clear_status
        super(prepared.not_nil!)
      end

      private def prepare_insert(raw : String) : String?
        normalized = sanitize(raw)
        unless normalized
          set_status(DRAFT_UTF8_STATUS)
          return nil
        end

        selected_bytes = copy.try(&.bytesize) || 0
        projected = text.bytesize - selected_bytes + normalized.not_nil!.bytesize
        if projected > MAX_DRAFT_BYTES
          set_status("Draft exceeds 16 KiB.")
          return nil
        end
        normalized
      end

      private def prepare_replacement(raw : String) : String?
        normalized = sanitize(raw)
        unless normalized
          set_status(DRAFT_UTF8_STATUS)
          return nil
        end
        if normalized.not_nil!.bytesize > MAX_DRAFT_BYTES
          set_status("Draft exceeds 16 KiB.")
          return nil
        end
        normalized
      end

      private def sanitize(raw : String) : String?
        return nil unless raw.valid_encoding?

        normalized = raw.gsub("\r\n", "\n").gsub("\r", "\n")
        String.build do |output|
          normalized.each_char do |char|
            codepoint = char.ord
            if char == '\n' || char == '\t'
              output << char
            elsif codepoint < 0x20 || (0x7f..0x9f).includes?(codepoint)
              next
            else
              output << char
            end
          end
        end
      end

      private def set_status(message : String) : Nil
        return if @status == message
        @status = message
        @on_status_change.try(&.call(@status))
        mark_dirty!
      end

      private def clear_status : Nil
        return if @status.empty?
        @status = ""
        @on_status_change.try(&.call(@status))
        mark_dirty!
      end
    end
  end
end
