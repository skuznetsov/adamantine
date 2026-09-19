require "./lexical_highlighter"

module Adamantine
  module LexicalController
    @lexical_shutdown : Bool = false

    private def configure_lexical_highlighting(buffer : OpenBuffer) : Nil
      return unless buffer.crystal_family?
      return if buffer.lexical_highlighter
      if editor = buffer.editor.as?(EditingTextEditor)
        buffer.lexical_highlighter = LexicalHighlighter.new(editor.search_source)
      end
    end

    private def lexical_buffer_changed(buffer : OpenBuffer, change : Tui::TextEditor::TextChange) : Nil
      highlighter = buffer.lexical_highlighter
      editor = buffer.editor.as?(EditingTextEditor)
      return unless highlighter && editor
      highlighter.invalidate(editor.search_source, change.start.try(&.line) || 0)
      buffer.lexical_requested_lines.clear
      # Rendering requests only the lines it actually visits, including folds.
      # No full-document pass is started merely because text changed.
    end

    private def lexical_token_at(buffer : OpenBuffer, line : Int32, column : Int32) : String?
      highlighter = buffer.lexical_highlighter
      return nil unless highlighter
      return nil if @lexical_shutdown
      if editor = buffer.editor.as?(EditingTextEditor)
        if buffer.lexical_view_line != editor.session_scroll_y
          buffer.lexical_view_line = editor.session_scroll_y
          buffer.lexical_requested_lines.clear
        end
      end
      # Request each visible row once per viewport/revision. A viewport with
      # more tokens than the cache can retain must degrade to plain text,
      # not alternate eviction/rescanning forever on each repaint.
      requested = buffer.lexical_requested_lines
      unless requested.includes?(line) || requested.size >= LexicalHighlighter::DEFAULT_MAX_CACHED_LINES
        requested << line
        start_lexical_worker(buffer) if highlighter.request(line)
      end
      highlighter.name_at(line, column)
    end

    private def start_lexical_worker(buffer : OpenBuffer) : Nil
      return if buffer.lexical_worker_running || @lexical_shutdown
      buffer.lexical_worker_running = true
      spawn(name: "lexical-highlighting") do
        begin
          loop do
            break if @lexical_shutdown
            break unless @document_session.open_buffers[buffer.path.to_s]?.try(&.same?(buffer))
            highlighter = buffer.lexical_highlighter
            break unless highlighter
            # advance never yields internally. Edits between batches update
            # the source/cache before any further work, so old spans cannot
            # be republished over a newer version.
            more = highlighter.advance(4096)
            buffer.editor.mark_dirty!
            mark_dirty!
            wakeup
            break unless more
            sleep 1.millisecond
          end
        rescue ex
          buffer.lexical_highlighter = nil
          @status_log.warning("Lexical highlighting stopped: #{ex.message || ex.class}")
        ensure
          buffer.lexical_worker_running = false
        end
      end
    end
  end
end
