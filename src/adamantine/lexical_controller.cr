require "./lexical_highlighter"

module Adamantine
  module LexicalController
    private class SecondaryView
      getter buffer : OpenBuffer
      getter editor : EditingTextEditor
      getter highlighter : LexicalHighlighter
      getter requested_lines = Set(Int32).new
      property view_line : Int32 = -1
      property worker_running : Bool = false
      property failed : Bool = false

      def initialize(@buffer : OpenBuffer, @editor : EditingTextEditor)
        @highlighter = LexicalHighlighter.new(@editor.search_source)
      end
    end

    @lexical_shutdown : Bool = false
    @lexical_secondary_views = [] of SecondaryView

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
      highlighter.invalidate(editor.search_source, change.start.try(&.line) || 0) if highlighter && editor
      buffer.lexical_requested_lines.clear
      @lexical_secondary_views.each do |view|
        next unless view.buffer.same?(buffer)
        view.highlighter.invalidate(view.editor.search_source, change.start.try(&.line) || 0)
        view.requested_lines.clear
      end
      # Rendering requests only the lines it actually visits, including folds.
      # No full-document pass is started merely because text changed.
    end

    private def lexical_token_at(buffer : OpenBuffer, editor : EditingTextEditor, line : Int32, column : Int32) : String?
      return nil if @lexical_shutdown
      unless editor.same?(buffer.editor)
        view = @lexical_secondary_views.find { |candidate| candidate.buffer.same?(buffer) && candidate.editor.same?(editor) }
        unless view
          view = SecondaryView.new(buffer, editor)
          @lexical_secondary_views << view
        end
        return nil if view.failed
        if view.view_line != editor.session_scroll_y
          view.view_line = editor.session_scroll_y
          view.requested_lines.clear
        end
        unless view.requested_lines.includes?(line) || view.requested_lines.size >= LexicalHighlighter::DEFAULT_MAX_CACHED_LINES
          view.requested_lines << line
          start_lexical_secondary_worker(view) if view.highlighter.request(line)
        end
        return view.highlighter.name_at(line, column)
      end

      highlighter = buffer.lexical_highlighter
      return nil unless highlighter
      if buffer.lexical_view_line != editor.session_scroll_y
        buffer.lexical_view_line = editor.session_scroll_y
        buffer.lexical_requested_lines.clear
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

    private def lexical_view_closed(buffer : OpenBuffer, editor : Tui::TextEditor) : Nil
      @lexical_secondary_views.reject! { |view| view.buffer.same?(buffer) && view.editor.same?(editor) }
    end

    private def start_lexical_secondary_worker(view : SecondaryView) : Nil
      return if view.worker_running || @lexical_shutdown
      view.worker_running = true
      spawn(name: "lexical-highlighting-view") do
        begin
          loop do
            break if @lexical_shutdown
            break unless @document_session.views_for(view.buffer).any?(&.same?(view.editor))
            break unless @lexical_secondary_views.any?(&.same?(view))
            more = view.highlighter.advance(4096)
            view.editor.mark_dirty!
            mark_dirty!
            wakeup
            break unless more
            sleep 1.millisecond
          end
        rescue ex
          view.failed = true
          @status_log.warning("Lexical highlighting stopped for a view: #{ex.message || ex.class}")
        ensure
          view.worker_running = false
        end
      end
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
