require "crystal_tui"
require "json"

module Adamantine
  module ModalManager
    CONTEXT_MENU_MIN_WIDTH      = 12
    LSP_POPUP_MAX_WIDTH         = 90
    LSP_POPUP_DEFAULT_MAX_LINES = 16

    private def completion_popup_active? : Bool
      @lsp_popup.completion_open? && lsp_popup_mode_active?
    end

    private def completion_key_event?(event : Tui::KeyEvent) : Bool
      return false unless completion_popup_active?
      action_pressed?("lsp.completion_up", event) ||
        action_pressed?("lsp.completion_down", event) ||
        action_pressed?("lsp.completion_accept", event) ||
        action_pressed?("lsp.completion_cancel", event)
    end

    # Formatting uses the LSP popup as a hard modal preview.  Keep these
    # predicates separate from completion so App's capture path can consume
    # paste/mouse/unrelated keys without invalidating the request generation.
    private def formatting_popup_active? : Bool
      @lsp_popup.edit_preview_open? && lsp_popup_mode_active?
    end

    private def formatting_key_event?(event : Tui::KeyEvent) : Bool
      return false unless formatting_popup_active?
      formatting_up_key_event?(event) ||
        formatting_down_key_event?(event) ||
        formatting_page_up_key_event?(event) ||
        formatting_page_down_key_event?(event) ||
        formatting_home_key_event?(event) ||
        formatting_end_key_event?(event) ||
        formatting_next_change_key_event?(event) ||
        formatting_previous_change_key_event?(event) ||
        formatting_apply_key_event?(event) ||
        formatting_cancel_key_event?(event)
    end

    private def quick_fix_popup_active? : Bool
      @lsp_popup.quick_fix_open? && lsp_popup_mode_active?
    end

    private def quick_fix_key_event?(event : Tui::KeyEvent) : Bool
      return false unless quick_fix_popup_active?
      quick_fix_up_key_event?(event) ||
        quick_fix_down_key_event?(event) ||
        quick_fix_accept_key_event?(event) ||
        quick_fix_cancel_key_event?(event)
    end

    private def quick_fix_accept_key_event?(event : Tui::KeyEvent) : Bool
      event.matches?("enter") || event.matches?("return")
    end

    private def quick_fix_up_key_event?(event : Tui::KeyEvent) : Bool
      action_pressed?("lsp.completion_up", event) || event.matches?("up")
    end

    private def quick_fix_down_key_event?(event : Tui::KeyEvent) : Bool
      action_pressed?("lsp.completion_down", event) || event.matches?("down")
    end

    private def quick_fix_cancel_key_event?(event : Tui::KeyEvent) : Bool
      action_pressed?("lsp.completion_cancel", event) || event.matches?("escape") || event.matches?("esc")
    end

    private def formatting_apply_key_event?(event : Tui::KeyEvent) : Bool
      # Formatting deliberately accepts only the advertised raw Enter/Return.
      # The completion action also defaults to Tab, which must remain a
      # consumed/unrelated key in this hard modal rather than applying edits.
      event.matches?("enter") || event.matches?("return")
    end

    private def formatting_up_key_event?(event : Tui::KeyEvent) : Bool
      action_pressed?("lsp.completion_up", event) || event.matches?("up")
    end

    private def formatting_down_key_event?(event : Tui::KeyEvent) : Bool
      action_pressed?("lsp.completion_down", event) || event.matches?("down")
    end

    private def formatting_page_up_key_event?(event : Tui::KeyEvent) : Bool
      event.matches?("pageup")
    end

    private def formatting_page_down_key_event?(event : Tui::KeyEvent) : Bool
      event.matches?("pagedown")
    end

    private def formatting_home_key_event?(event : Tui::KeyEvent) : Bool
      event.matches?("home")
    end

    private def formatting_end_key_event?(event : Tui::KeyEvent) : Bool
      event.matches?("end")
    end

    private def formatting_next_change_key_event?(event : Tui::KeyEvent) : Bool
      event.matches?("tab")
    end

    private def formatting_previous_change_key_event?(event : Tui::KeyEvent) : Bool
      event.matches?("shift+tab")
    end

    private def formatting_cancel_key_event?(event : Tui::KeyEvent) : Bool
      action_pressed?("lsp.completion_cancel", event) || event.matches?("escape") || event.matches?("esc")
    end

    private def handle_context_menu_input(event : Tui::KeyEvent) : Bool
      if action_pressed?("app.menu_close", event)
        close_context_menu
        return true
      end

      case
      when action_pressed?("app.menu_up", event)
        move_context_menu_selection(-1)
        mark_dirty!
        return true
      when action_pressed?("app.menu_down", event)
        move_context_menu_selection(1)
        mark_dirty!
        return true
      when action_pressed?("app.menu_select", event)
        execute_selected_context_action
        return true
      when action_pressed?("app.menu_first", event)
        @context_menu.index = 0
        mark_dirty!
        return true
      when action_pressed?("app.menu_last", event)
        @context_menu.index = @context_menu.actions.size - 1
        mark_dirty!
        return true
      end

      if char = event.char
        if char >= '1' && char <= '9'
          index = (char - '1')
          if index >= 0 && index < @context_menu.actions.size
            @context_menu.index = index
            execute_selected_context_action
            return true
          end
        end
      end

      false
    end

    private def handle_lsp_popup_input(event : Tui::KeyEvent) : Bool
      if @lsp_popup.edit_preview_open?
        case
        when formatting_apply_key_event?(event)
          accept_document_edit_preview
          return true
        when formatting_cancel_key_event?(event)
          close_lsp_popup
          return true
        when formatting_up_key_event?(event)
          move_document_edit_scroll(-1)
          mark_dirty!
          return true
        when formatting_down_key_event?(event)
          move_document_edit_scroll(1)
          mark_dirty!
          return true
        when formatting_page_up_key_event?(event)
          move_document_edit_page(-1)
          mark_dirty!
          return true
        when formatting_page_down_key_event?(event)
          move_document_edit_page(1)
          mark_dirty!
          return true
        when formatting_home_key_event?(event)
          move_document_edit_home
          mark_dirty!
          return true
        when formatting_end_key_event?(event)
          move_document_edit_end
          mark_dirty!
          return true
        when formatting_next_change_key_event?(event)
          move_document_edit_change(1)
          mark_dirty!
          return true
        when formatting_previous_change_key_event?(event)
          move_document_edit_change(-1)
          mark_dirty!
          return true
        else
          # A formatting preview is an authority boundary. Unrelated keys
          # are consumed so the underlying editor cannot change the snapshot
          # between preview and explicit Enter.
          return true
        end
      end

      if @lsp_popup.quick_fix_open?
        case
        when quick_fix_accept_key_event?(event)
          accept_quick_fix_selection
          return true
        when quick_fix_cancel_key_event?(event)
          close_lsp_popup
          return true
        when quick_fix_up_key_event?(event)
          move_quick_fix_selection(-1)
          mark_dirty!
          return true
        when quick_fix_down_key_event?(event)
          move_quick_fix_selection(1)
          mark_dirty!
          return true
        else
          # The picker is also a hard modal. It is intentionally limited to
          # navigation/selection/cancel; paste, mouse, Tab, and editor keys
          # cannot mutate the captured document underneath it.
          return true
        end
      end

      if @lsp_popup.completion_open?
        case
        when action_pressed?("lsp.completion_up", event)
          move_completion_selection(-1)
          mark_dirty!
          return true
        when action_pressed?("lsp.completion_down", event)
          move_completion_selection(1)
          mark_dirty!
          return true
        when action_pressed?("lsp.completion_accept", event)
          accept_completion_selection
          return true
        when action_pressed?("lsp.completion_cancel", event)
          close_lsp_popup
          return true
        else
          # A completion popup is a hard modal boundary. In particular, do
          # not let editing keys reach the focused editor beneath the overlay.
          return true
        end
      end

      if action_pressed?("lsp.popup_close", event)
        close_lsp_popup
        return true
      end
      true
    end

    private def move_context_menu_selection(delta : Int32) : Nil
      return if @context_menu.actions.empty?

      @context_menu.index += delta
      if @context_menu.index < 0
        @context_menu.index = @context_menu.actions.size - 1
      elsif @context_menu.index >= @context_menu.actions.size
        @context_menu.index = 0
      end
    end

    private def execute_selected_context_action : Nil
      return if @context_menu.actions.empty?

      index = @context_menu.index.clamp(0, @context_menu.actions.size - 1)
      action = @context_menu.actions[index]?
      return unless action

      close_context_menu
      action.action.call
    end

    private def open_quick_actions_menu : Nil
      open_context_menu("Quick Actions", build_quick_actions_menu)
    end

    private def open_lsp_context_menu : Nil
      open_context_menu("LSP Actions", build_lsp_context_menu_actions)
    end

    private def open_context_menu(title : String, actions : Array(LspContextAction)) : Nil
      return if close_confirmation_active?
      if actions.empty?
        if title == "LSP Actions"
          @status_log.warning("No LSP actions available for this cursor")
        end
        return
      end

      close_lsp_popup
      with_input_mode_guard(InputModeController::InputMode::ContextMenu) do
        @context_menu.title = title
        @context_menu.index = 0

        previous_overlay = @context_menu.overlay

        @context_menu.actions = actions
        @context_menu.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_lsp_context_menu(buffer, clip)
        }
        @context_menu.overlay = open_overlay(previous_overlay, @context_menu.overlay.not_nil!)
        @context_menu.open = true
        mark_dirty!
      end
    end

    private def close_context_menu : Nil
      close_modal(@context_menu, InputModeController::InputMode::ContextMenu)
      @context_menu.actions = [] of LspContextAction
      @context_menu.index = 0
      @context_menu.title = "Actions"
    end

    private def open_lsp_popup(title : String, lines : Array(String), max_lines : Int32 = LSP_POPUP_DEFAULT_MAX_LINES) : Nil
      return if close_confirmation_active?
      close_context_menu
      @lsp_popup.title = title
      @lsp_popup.lines = lines
      @lsp_popup.clear_completion
      @lsp_popup.clear_quick_fix
      # Generic/read-only popups supersede a formatting preview.  Formatting
      # state is set only by open_formatting_popup after this reset.
      @lsp_popup.clear_formatting
      @lsp_popup.clear_refactor

      with_input_mode_guard(InputModeController::InputMode::LspPopup) do
        previous_overlay = @lsp_popup.overlay
        @lsp_popup.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_lsp_popup(buffer, clip, max_lines)
        }
        @lsp_popup.overlay = open_overlay(previous_overlay, @lsp_popup.overlay.not_nil!)
        @lsp_popup.open = true
        mark_dirty!
      end
    end

    private def open_completion_popup(
      request : InteractiveLspRequest,
      items : Array(Lsp::CompletionItem),
      lines : Array(String),
      max_lines : Int32 = 20,
    ) : Nil
      close_context_menu
      @lsp_popup.title = "Completion"
      @lsp_popup.lines = lines
      @lsp_popup.clear_formatting
      @lsp_popup.clear_refactor
      @lsp_popup.clear_quick_fix
      @lsp_popup.completion_items = items
      @lsp_popup.completion_request = request
      @lsp_popup.completion_index = 0
      @lsp_popup.completion_top = 0
      @lsp_popup.completion_max_lines = [max_lines, 1].max

      with_input_mode_guard(InputModeController::InputMode::LspPopup) do
        previous_overlay = @lsp_popup.overlay
        @lsp_popup.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_lsp_popup(buffer, clip, @lsp_popup.completion_max_lines)
        }
        @lsp_popup.overlay = open_overlay(previous_overlay, @lsp_popup.overlay.not_nil!)
        @lsp_popup.open = true
        mark_dirty!
      end
    end

    # Install a validated detached plan only after open_lsp_popup has cleared
    # stale completion/formatting state. Enter always applies this complete
    # plan; the visible rows are display-only and may be scrolled.
    private def open_formatting_popup(
      request : InteractiveLspRequest,
      plan : SafeDocumentEdits::Plan,
      max_lines : Int32 = LSP_POPUP_DEFAULT_MAX_LINES,
    ) : Nil
      # A stale paste callback may already be queued while the server was
      # formatting. Invalidate it at the exact moment the hard modal opens.
      preview_title = "Format proposed edits"
      preview = plan.inline_preview(preview_title)
      @clipboard_paste_generation &+= 1_u64
      open_lsp_popup(preview_title, plan.preview_lines, max_lines)
      @lsp_popup.formatting_request = request
      @lsp_popup.formatting_plan = plan
      @lsp_popup.formatting_preview = preview
      @lsp_popup.formatting_top = 0
      @lsp_popup.formatting_max_lines = [max_lines, 1].max
      mark_dirty!
    end

    private def open_refactor_popup(
      request : InteractiveLspRequest,
      plan : SafeDocumentEdits::Plan,
      title : String,
      max_lines : Int32 = LSP_POPUP_DEFAULT_MAX_LINES,
    ) : Nil
      # The refactor preview is the same hard modal and clipboard boundary as
      # formatting, but its request/plan are kept in their own state slot so
      # formatting callers retain their existing API and tests.
      preview_title = "#{title} proposed edits"
      preview = plan.inline_preview(preview_title)
      @clipboard_paste_generation &+= 1_u64
      open_lsp_popup(preview_title, plan.preview_lines, max_lines)
      @lsp_popup.refactor_request = request
      @lsp_popup.refactor_plan = plan
      @lsp_popup.refactor_preview = preview
      @lsp_popup.refactor_title = preview_title
      @lsp_popup.refactor_top = 0
      @lsp_popup.refactor_max_lines = [max_lines, 1].max
      mark_dirty!
    end

    private def open_quick_fix_popup(
      request : InteractiveLspRequest,
      actions : Array(JSON::Any),
      lines : Array(String),
      omitted_count : Int32 = 0,
      max_lines : Int32 = 18,
    ) : Nil
      # A clipboard callback may have been started before the async response
      # arrived. Opening the picker is the authority boundary, so invalidate
      # that callback before exposing the modal to input.
      @clipboard_paste_generation &+= 1_u64
      close_context_menu
      @lsp_popup.title = if omitted_count > 0
                           "#{omitted_count} unavailable/omitted · Quick Fix"
                         else
                           "Quick Fix"
                         end
      @lsp_popup.lines = lines
      @lsp_popup.clear_completion
      @lsp_popup.clear_formatting
      @lsp_popup.clear_refactor
      @lsp_popup.quick_fix_actions = actions
      @lsp_popup.quick_fix_request = request
      @lsp_popup.quick_fix_index = 0
      @lsp_popup.quick_fix_top = 0
      @lsp_popup.quick_fix_max_lines = [max_lines, 1].max
      @lsp_popup.quick_fix_omitted_count = omitted_count

      with_input_mode_guard(InputModeController::InputMode::LspPopup) do
        previous_overlay = @lsp_popup.overlay
        @lsp_popup.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_lsp_popup(buffer, clip, @lsp_popup.quick_fix_max_lines)
        }
        @lsp_popup.overlay = open_overlay(previous_overlay, @lsp_popup.overlay.not_nil!)
        @lsp_popup.open = true
        mark_dirty!
      end
    end

    private def close_lsp_popup(invalidate_actions : Bool = true) : Nil
      invalidate_lsp_actions if invalidate_actions
      close_modal(@lsp_popup, InputModeController::InputMode::LspPopup)
      @lsp_popup.title = ""
      @lsp_popup.lines = [] of String
      @lsp_popup.clear_completion
      @lsp_popup.clear_formatting
      @lsp_popup.clear_refactor
      @lsp_popup.clear_quick_fix
    end

    private def move_completion_selection(delta : Int32) : Nil
      items = @lsp_popup.completion_items
      return unless items && !items.empty?

      count = items.size
      index = @lsp_popup.completion_index + delta
      index = count - 1 if index < 0
      index = 0 if index >= count
      @lsp_popup.completion_index = index

      visible = @lsp_popup.completion_max_lines.clamp(1, count)
      if index < @lsp_popup.completion_top
        @lsp_popup.completion_top = index
      elsif index >= @lsp_popup.completion_top + visible
        @lsp_popup.completion_top = index - visible + 1
      end
    end

    private def move_formatting_scroll(delta : Int32) : Nil
      return unless @lsp_popup.edit_preview_open?

      preview = @lsp_popup.edit_preview
      return unless preview
      preview.scroll_by(delta)
      sync_document_edit_scroll(preview)
    end

    private def move_document_edit_scroll(delta : Int32) : Nil
      move_formatting_scroll(delta)
    end

    private def move_document_edit_page(delta : Int32) : Nil
      preview = @lsp_popup.edit_preview
      return unless preview

      page_rows = if editor = current_editor
                    [editor.rect.height - 2, 1].max
                  else
                    1
                  end
      preview.scroll_page(delta, page_rows)
      sync_document_edit_scroll(preview)
    end

    private def move_document_edit_home : Nil
      preview = @lsp_popup.edit_preview
      return unless preview
      preview.home
      sync_document_edit_scroll(preview)
    end

    private def move_document_edit_end : Nil
      preview = @lsp_popup.edit_preview
      return unless preview
      preview.finish
      sync_document_edit_scroll(preview)
    end

    private def move_document_edit_change(delta : Int32) : Nil
      preview = @lsp_popup.edit_preview
      return unless preview
      if delta < 0
        preview.previous_change
      else
        preview.next_change
      end
      sync_document_edit_scroll(preview)
    end

    private def sync_document_edit_scroll(preview : InlineEditPreview::Model) : Nil
      if @lsp_popup.formatting_open?
        @lsp_popup.formatting_top = preview.top
      elsif @lsp_popup.refactor_open?
        @lsp_popup.refactor_top = preview.top
      end
    end

    private def move_quick_fix_selection(delta : Int32) : Nil
      actions = @lsp_popup.quick_fix_actions
      return unless actions && !actions.empty?

      count = actions.size
      index = @lsp_popup.quick_fix_index + delta
      index = count - 1 if index < 0
      index = 0 if index >= count
      @lsp_popup.quick_fix_index = index

      visible = @lsp_popup.quick_fix_max_lines.clamp(1, count)
      if index < @lsp_popup.quick_fix_top
        @lsp_popup.quick_fix_top = index
      elsif index >= @lsp_popup.quick_fix_top + visible
        @lsp_popup.quick_fix_top = index - visible + 1
      end
    end

    private def render_lsp_context_menu(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return if @context_menu.actions.empty?

      menu_width = 60
      max_label = @context_menu.actions.map { |action| action.label.size }.max || 10
      max_shortcut = @context_menu.actions.map { |action| action.shortcut.size }.max || 0
      menu_width = [max_label + max_shortcut + 8, CONTEXT_MENU_MIN_WIDTH].max
      menu_height = @context_menu.actions.size + 2

      editor = current_editor
      base_rect = editor ? editor.rect : @body_split.rect
      menu_x = (base_rect.x + 2).clamp(clip.x, [clip.right - menu_width, clip.x].max)
      menu_y = (base_rect.y + 1).clamp(clip.y, [clip.bottom - menu_height, clip.y].max)

      fg_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      active_style = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
      header_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)
      title = @context_menu.title.empty? ? "Actions" : @context_menu.title

      draw_box_border(buffer, clip, menu_x, menu_y, menu_width, menu_height, fg_style, fg_style, title, header_style)

      @context_menu.actions.each_with_index do |action, index|
        y = menu_y + 1 + index
        is_selected = index == @context_menu.index
        row_style = is_selected ? active_style : fg_style
        line_text = "#{index + 1}) #{action.label} [#{action.shortcut}]"
        line_text = line_text.ljust(menu_width - 2)[0, menu_width - 2]

        # Fill row background for selected highlight
        (1...menu_width - 1).each do |dx|
          buffer.set(menu_x + dx, y, ' ', row_style) if clip.contains?(menu_x + dx, y)
        end
        draw_text_line(buffer, clip, menu_x + 1, y, line_text, row_style, menu_width - 2)
      end
    end

    private def render_lsp_popup(buffer : Tui::Buffer, clip : Tui::Rect, max_lines : Int32) : Nil
      if @lsp_popup.edit_preview_open?
        if preview = @lsp_popup.edit_preview
          render_inline_edit_preview(buffer, clip, preview)
          sync_document_edit_scroll(preview)
        end
        return
      end
      return if @lsp_popup.lines.empty?

      body_lines = @lsp_popup.lines
      completion = @lsp_popup.completion_open?
      formatting = @lsp_popup.edit_preview_open?
      quick_fix = @lsp_popup.quick_fix_open?
      visible_lines = if completion
                        # Leave room for title/borders and the overflow row.
                        # A popup is rendered inside `clip`, which can be much
                        # shorter than the configured completion limit.
                        [@lsp_popup.completion_max_lines, [clip.height - 4, 1].max].min
                      elsif formatting
                        max_lines_for_edit_preview = @lsp_popup.formatting_open? ? @lsp_popup.formatting_max_lines : @lsp_popup.refactor_max_lines
                        [max_lines_for_edit_preview, [clip.height - 4, 1].max].min
                      elsif quick_fix
                        [@lsp_popup.quick_fix_max_lines, [clip.height - 4, 1].max].min
                      else
                        max_lines
                      end
      if completion
        max_top = [body_lines.size - visible_lines, 0].max
        @lsp_popup.completion_top = @lsp_popup.completion_top.clamp(0, max_top)
        index = @lsp_popup.completion_index.clamp(0, [body_lines.size - 1, 0].max)
        if index < @lsp_popup.completion_top
          @lsp_popup.completion_top = index
        elsif index >= @lsp_popup.completion_top + visible_lines
          @lsp_popup.completion_top = index - visible_lines + 1
        end
      end
      if formatting
        max_top = [body_lines.size - visible_lines, 0].max
        if @lsp_popup.formatting_open?
          @lsp_popup.formatting_top = @lsp_popup.formatting_top.clamp(0, max_top)
        else
          @lsp_popup.refactor_top = @lsp_popup.refactor_top.clamp(0, max_top)
        end
      end
      if quick_fix
        max_top = [body_lines.size - visible_lines, 0].max
        @lsp_popup.quick_fix_top = @lsp_popup.quick_fix_top.clamp(0, max_top)
        index = @lsp_popup.quick_fix_index.clamp(0, [@lsp_popup.quick_fix_actions.not_nil!.size - 1, 0].max)
        if index < @lsp_popup.quick_fix_top
          @lsp_popup.quick_fix_top = index
        elsif index >= @lsp_popup.quick_fix_top + visible_lines
          @lsp_popup.quick_fix_top = index - visible_lines + 1
        end
      end
      start_line = if completion
                     @lsp_popup.completion_top
                   elsif formatting
                     @lsp_popup.formatting_open? ? @lsp_popup.formatting_top : @lsp_popup.refactor_top
                   elsif quick_fix
                     @lsp_popup.quick_fix_top
                   else
                     0
                   end
      content_lines = body_lines[start_line, visible_lines] || [] of String
      line_width = content_lines.map(&.size).max || 1
      return if (formatting || quick_fix) && clip.width < 4
      header = @lsp_popup.title.empty? ? "LSP" : @lsp_popup.title
      desired_width = line_width + 4
      # Quick Fix may carry its omission disclosure only in the title. Use
      # that bounded title when sizing the popup even if the visible body
      # window contains only short action rows; clip and the global maximum
      # still cap the final width.
      desired_width = [desired_width, header.size + 2].max if quick_fix
      popup_width = if formatting || quick_fix
                      [desired_width, LSP_POPUP_MAX_WIDTH, clip.width].min
                    else
                      [desired_width, LSP_POPUP_MAX_WIDTH].min
                    end
      popup_height = content_lines.size + 4

      editor = current_editor
      base_rect = editor ? editor.rect : @body_split.rect
      popup_x = (base_rect.x + base_rect.width - popup_width - 2).clamp(clip.x, [clip.right - popup_width, clip.x].max)
      popup_y = (base_rect.y + 1).clamp(clip.y, [clip.bottom - popup_height, clip.y].max)

      fg_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)

      draw_box_border(buffer, clip, popup_x, popup_y, popup_width, popup_height, fg_style, fg_style, header, title_style)

      content_lines.each_with_index do |line, index|
        y = popup_y + 1 + index
        break if y >= popup_y + popup_height - 1
        row_style = if completion && start_line + index == @lsp_popup.completion_index
                      Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
                    elsif quick_fix && start_line + index == @lsp_popup.quick_fix_index
                      Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
                    else
                      fg_style
                    end
        display_line = (formatting || quick_fix) ? formatting_display_line(line, popup_width - 3) : line
        draw_text_line(buffer, clip, popup_x + 2, y, display_line, row_style, popup_width - 3)
      end

      if start_line > 0 || start_line + content_lines.size < body_lines.size
        remaining = body_lines.size - (start_line + content_lines.size)
        indicator = if start_line > 0 && remaining > 0
                      "↑ #{start_line} more · ↓ #{remaining} more"
                    elsif start_line > 0
                      "↑ #{start_line} more"
                    else
                      "↓ #{remaining} more"
                    end
        y = popup_y + popup_height - 2
        draw_text_line(buffer, clip, popup_x + 2, y, indicator, fg_style, popup_width - 3)
      end
    end

    # draw_text_line intentionally clips ordinary popup content silently. A
    # formatting preview is a review surface, so an over-wide row must carry
    # a visible marker rather than look complete when the right side is hidden.
    private def formatting_display_line(text : String, max_width : Int32) : String
      return text if max_width <= 0

      width = 0
      clipped = false
      text.each_grapheme do |grapheme|
        width += Tui::Unicode.grapheme_width(grapheme.to_s)
        if width > max_width
          clipped = true
          break
        end
      end
      return text unless clipped

      marker = "…"
      marker_width = Tui::Unicode.grapheme_width(marker)
      return marker if marker_width >= max_width

      builder = String::Builder.new
      used = 0
      text.each_grapheme do |grapheme|
        glyph = grapheme.to_s
        glyph_width = Tui::Unicode.grapheme_width(glyph)
        break if used + glyph_width + marker_width > max_width
        builder << glyph
        used += glyph_width
      end
      builder << marker
      builder.to_s
    end
  end
end
