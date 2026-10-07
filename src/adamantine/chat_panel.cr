require "crystal_tui"
require "mutex"
require "./theme"
require "./chat_frontend"
require "./chat_composer"

module Adamantine
  module Chat
    class Panel < Tui::Widget
      class PasteTarget
        getter generation : UInt64
        getter context_epoch : String
        getter composer_id : UInt64
        getter composer_revision : UInt64
        getter lifetime_revision : UInt64
        getter text_snapshot : String
        getter cursor_line : Int32
        getter cursor_col : Int32
        getter selection_present : Bool
        getter selection_snapshot : String?

        def initialize(@generation : UInt64, context_epoch : String, @composer_id : UInt64,
                       @composer_revision : UInt64, @lifetime_revision : UInt64,
                       text_snapshot : String, @cursor_line : Int32, @cursor_col : Int32,
                       @selection_present : Bool, selection_snapshot : String?)
          @context_epoch = context_epoch.dup
          @text_snapshot = text_snapshot.dup
          @selection_snapshot = selection_snapshot.try(&.dup)
        end
      end

      private struct PendingPaste
        getter target : PasteTarget
        getter text : String?
        getter oversized : Bool

        def initialize(@target : PasteTarget, text : String?, @oversized : Bool)
          @text = text.try(&.dup)
        end
      end

      enum View
        Chat
        Log
      end

      getter composer : Composer
      getter log : Tui::Log
      getter view : View
      getter frontend : Frontend

      @on_view_change : Proc(View, Nil)?
      @paste_lock = Mutex.new
      @pending_paste : PendingPaste?

      def initialize(@frontend : Frontend, @log : Tui::Log)
        super("bottom-chat-panel")
        @view = View::Log
        @composer = Composer.new
        @log.visible = true
        @composer.visible = false
        @composer.on_change do
          @frontend.set_draft(@composer.text)
          mark_dirty!
        end
        @composer.on_status_change { |_message| mark_dirty! }
      end

      def compose : Array(Tui::Widget)
        [@log, @composer] of Tui::Widget
      end

      def on_view_change(&block : View -> Nil) : Nil
        @on_view_change = block
      end

      def select_chat(focus : Bool = true) : Nil
        set_view(View::Chat)
        synchronize_child_rects
        @composer.focus if focus && visible? && !@composer.rect.empty?
      end

      def select_log(focus : Bool = true) : Nil
        set_view(View::Log)
        synchronize_child_rects
        @log.focus if focus && visible? && !@log.rect.empty?
      end

      def owns_focus? : Bool
        focused = Tui::Widget.focused_widget
        focused == @composer || focused == @log
      end

      def composer_focused? : Bool
        Tui::Widget.focused_widget == @composer && @view.chat? && visible? && !@composer.rect.empty?
      end

      def toggle_view : View
        if @view.chat?
          select_log
        else
          select_chat
        end
        @view
      end

      def sync_from_frontend : Nil
        current = @frontend.draft
        @composer.text = current unless @composer.text == current
        mark_dirty!
      end

      # Keep child geometry current before input routing, not only during paint.
      # This makes a resize/focus action safe even if another key arrives before
      # the next render pass.
      def synchronize_child_rects : Nil
        unless visible? && !@rect.empty?
          @log.rect = Tui::Rect.zero
          @composer.rect = Tui::Rect.zero
          @log.visible = false
          @composer.visible = false
          return
        end

        if @rect.height <= 1
          @log.rect = Tui::Rect.zero
          @composer.rect = Tui::Rect.zero
          @log.visible = @view.log?
          @composer.visible = @view.chat?
          return
        end
        content = Tui::Rect.new(@rect.x, @rect.y + 1, @rect.width, @rect.height - 1)
        if @view.log?
          @log.rect = content
          @composer.rect = Tui::Rect.zero
          @log.visible = true
          @composer.visible = false
        else
          @log.rect = Tui::Rect.zero
          @log.visible = false
          @composer.visible = true
          _transcript, _status, composer_area = chat_areas(content)
          @composer.synchronize_viewport(composer_area)
        end
      end

      # The asynchronous system-clipboard callback may only enqueue bounded
      # immutable input. App-owner draining revalidates all captured state
      # before mutating the composer.
      def capture_paste_target(generation : UInt64, context_epoch : String) : PasteTarget?
        return nil unless visible? && @rect.height > 1 && @view.chat?
        return nil unless Tui::Widget.focused_widget == @composer

        selected = @composer.copy
        PasteTarget.new(generation, context_epoch, @composer.object_id,
          @composer.mutation_revision, @frontend.lifetime_revision,
          @composer.text, @composer.cursor_line, @composer.cursor_col,
          !selected.nil?, selected)
      end

      def enqueue_paste_result(target : PasteTarget, text : String?) : Nil
        oversized = text.try(&.bytesize).try { |size| size > MAX_DRAFT_BYTES } || false
        bounded = if oversized || (text && !text.not_nil!.valid_encoding?)
                    nil
                  else
                    text
                  end
        @paste_lock.synchronize do
          existing = @pending_paste
          if existing.nil? || target.generation >= existing.not_nil!.target.generation
            @pending_paste = PendingPaste.new(target, bounded, oversized)
          end
        end
      end

      def drain_paste(generation : UInt64, context_epoch : String) : Bool
        pending = @paste_lock.synchronize do
          value = @pending_paste
          @pending_paste = nil
          value
        end
        return false unless pending

        target = pending.not_nil!.target
        return false unless target.generation == generation
        return false unless target.context_epoch == context_epoch
        return false unless target.composer_id == @composer.object_id
        return false unless target.composer_revision == @composer.mutation_revision
        return false unless target.lifetime_revision == @frontend.lifetime_revision
        return false unless visible? && !@rect.empty? && @view.chat?
        return false unless Tui::Widget.focused_widget == @composer
        return false unless @composer.text == target.text_snapshot
        return false unless @composer.cursor_line == target.cursor_line
        return false unless @composer.cursor_col == target.cursor_col

        selected = @composer.copy
        return false unless (!selected.nil?) == target.selection_present
        if snapshot = target.selection_snapshot
          return false unless selected == snapshot
        end

        if pending.not_nil!.oversized
          @composer.reject_oversized_paste
          return true
        end
        if text = pending.not_nil!.text
          @composer.paste(text)
          return true
        end
        false
      end

      def submit : Bool
        @frontend.set_draft(@composer.text)
        submitted = @frontend.submit
        sync_from_frontend if submitted
        mark_dirty!
        submitted
      end

      def new_conversation : Nil
        @frontend.new_conversation
        @composer.text = ""
        mark_dirty!
      end

      def cancel_request : Bool
        cancelled = @frontend.cancel
        mark_dirty! if cancelled
        cancelled
      end

      def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
        return unless visible?
        return if @rect.empty?
        return unless panel_clip = clip.intersect(@rect)

        draw_header(buffer, panel_clip)
        return if @rect.height <= 1

        content = Tui::Rect.new(@rect.x, @rect.y + 1, @rect.width, @rect.height - 1)
        return unless content_clip = panel_clip.intersect(content)

        synchronize_child_rects
        if @view.log?
          @log.render(buffer, content_clip)
        else
          render_chat(buffer, content, content_clip)
        end
      end

      def on_event(event : Tui::Event) : Bool
        return false unless event.is_a?(Tui::MouseEvent)
        return false unless event.action.press? && event.y == @rect.y

        chat_end = @rect.x + " Chat ".size
        log_start = chat_end + 1
        log_end = log_start + " Log ".size
        if event.x >= @rect.x && event.x < chat_end
          select_chat
        elsif event.x >= log_start && event.x < log_end
          select_log
        else
          return false
        end
        event.stop!
        true
      end

      private def set_view(view : View) : Nil
        return if @view == view
        previous = @view
        @view = view
        @log.visible = view.log?
        @composer.visible = view.chat?
        if previous.chat? && Tui::Widget.focused_widget == @composer
          @composer.blur
        end
        @on_view_change.try(&.call(view))
        mark_dirty!
      end

      private def draw_header(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
        y = @rect.y
        base = Tui::Style.new(fg: Theme::Status.info, bg: Theme::Status.bg)
        @rect.width.times do |offset|
          x = @rect.x + offset
          buffer.set(x, y, ' ', base) if clip.contains?(x, y)
        end

        chat_style = tab_style(View::Chat)
        log_style = tab_style(View::Log)
        cursor = @rect.x
        cursor += draw_text(buffer, clip, cursor, y, " Chat ", chat_style)
        cursor += draw_text(buffer, clip, cursor, y, " ", base)
        cursor += draw_text(buffer, clip, cursor, y, " Log ", log_style)

        notice = if @view.chat?
                   "Enter send | Shift/Alt+Enter newline"
                 else
                   @composer.status.empty? ? @frontend.status : @composer.status
                 end
        notice = Tui::Unicode.truncate(notice, [@rect.right - cursor - 1, 0].max)
        draw_text(buffer, clip, cursor + 1, y, notice, base) unless notice.empty?
      end

      private def render_chat(buffer : Tui::Buffer, content : Tui::Rect, clip : Tui::Rect) : Nil
        return if content.empty?

        transcript, status_y, composer_area = chat_areas(content)
        draw_transcript(buffer, clip, transcript)

        status = @composer.status.empty? ? @frontend.status : @composer.status
        draw_line(buffer, clip, content.x, status_y, status, Tui::Style.new(fg: Theme::Status.timestamp)) if status_y >= content.y && status_y < content.bottom

        @composer.synchronize_viewport(composer_area)
        @composer.visible = true
        if composer_clip = clip.intersect(composer_area)
          @composer.render(buffer, composer_clip)
        end
      end

      private def chat_areas(content : Tui::Rect) : {Tui::Rect, Int32, Tui::Rect}
        if content.height == 1
          return {Tui::Rect.zero, content.y, content}
        end

        draft_lines = [@composer.text.count('\n') + 1, 2].max
        composer_height = draft_lines.clamp(1, content.height - 1)
        status_y = content.bottom - composer_height - 1
        transcript = Tui::Rect.new(content.x, content.y, content.width,
          [status_y - content.y, 0].max)
        composer_area = Tui::Rect.new(content.x, status_y + 1, content.width,
          content.bottom - status_y - 1)
        {transcript, status_y, composer_area}
      end

      private def draw_transcript(buffer : Tui::Buffer, clip : Tui::Rect, area : Tui::Rect) : Nil
        return if area.empty?

        rows = [] of {String, Tui::Style}
        @frontend.messages.reverse_each do |message|
          break if rows.size >= area.height
          prefix = message.role.user? ? "You: " : "Assistant: "
          style = message.role.user? ? Tui::Style.new(fg: Theme::Status.info) : Tui::Style.new(fg: Theme::Status.success)
          trailing_lines(message.text, area.height - rows.size).each do |line, first|
            rows << {first ? "#{prefix}#{line}" : "  #{line}", style}
          end
        end

        rows.reverse!

        if rows.empty?
          draw_line(buffer, clip, area.x, area.y, "No messages yet.", Tui::Style.new(fg: Theme::Status.timestamp))
          return
        end

        visible = rows.last(area.height)
        start_y = area.bottom - visible.size
        visible.each_with_index do |row, index|
          draw_line(buffer, clip, area.x, start_y + index, row[0], row[1])
        end
      end

      # Return only the newest lines, newest first, without splitting the full
      # bounded transcript message into an array of every line on each paint.
      private def trailing_lines(text : String, limit : Int32) : Array({String, Bool})
        rows = [] of {String, Bool}
        return rows if limit <= 0

        finish = text.bytesize
        if finish == 0
          rows << {"", true}
          return rows
        end

        while rows.size < limit
          # `String#rindex(Char, offset)` takes a character offset for valid
          # UTF-8 strings. Here `finish` and `byte_slice` are byte offsets, so
          # search the backing byte slice to keep the coordinate system
          # consistent (and avoid IndexError when a streamed response contains
          # non-ASCII text before the newline).
          newline = finish > 0 ? text.to_slice.rindex('\n'.ord.to_u8, finish - 1) : nil
          start = newline ? newline.not_nil! + 1 : 0
          rows << {text.byte_slice(start, finish - start) || "", start == 0}
          break unless newline
          finish = newline.not_nil!
        end
        rows
      end

      private def tab_style(view : View) : Tui::Style
        if @view == view
          Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)
        else
          Tui::Style.new(fg: Theme::Status.timestamp, bg: Theme::Status.bg)
        end
      end

      private def draw_line(buffer : Tui::Buffer, clip : Tui::Rect, x : Int32, y : Int32,
                            text : String, style : Tui::Style) : Nil
        return unless clip.contains?(x, y)
        draw_text(buffer, clip, x, y, Tui::Unicode.truncate(text, @rect.right - x), style)
      end

      private def draw_text(buffer : Tui::Buffer, clip : Tui::Rect, x : Int32, y : Int32,
                            text : String, style : Tui::Style) : Int32
        offset = 0
        text.each_grapheme do |grapheme|
          glyph = grapheme.to_s
          width = Tui::Unicode.grapheme_width(glyph)
          break if x + offset + width > @rect.right
          buffer.set(x + offset, y, glyph, style) if clip.contains?(x + offset, y)
          offset += width
        end
        offset
      end
    end
  end
end
