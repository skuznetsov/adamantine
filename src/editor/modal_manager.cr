require "crystal_tui"

module CrystalEditor
  module ModalManager
    CONTEXT_MENU_MIN_WIDTH      = 12
    LSP_POPUP_MAX_WIDTH         = 90
    LSP_POPUP_DEFAULT_MAX_LINES = 16

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
      if action_pressed?("lsp.popup_close", event)
        close_lsp_popup
        return true
      end
      false
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
      close_context_menu
      @lsp_popup.title = title
      @lsp_popup.lines = lines

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

    private def close_lsp_popup : Nil
      close_modal(@lsp_popup, InputModeController::InputMode::LspPopup)
      @lsp_popup.title = ""
      @lsp_popup.lines = [] of String
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
      return if @lsp_popup.lines.empty?

      body_lines = @lsp_popup.lines
      content_lines = body_lines[0, max_lines] || [] of String
      line_width = content_lines.map(&.size).max || 1
      popup_width = [line_width + 4, LSP_POPUP_MAX_WIDTH].min
      popup_height = content_lines.size + 4

      editor = current_editor
      base_rect = editor ? editor.rect : @body_split.rect
      popup_x = (base_rect.x + base_rect.width - popup_width - 2).clamp(clip.x, [clip.right - popup_width, clip.x].max)
      popup_y = (base_rect.y + 1).clamp(clip.y, [clip.bottom - popup_height, clip.y].max)

      fg_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)
      header = @lsp_popup.title.empty? ? "LSP" : @lsp_popup.title

      draw_box_border(buffer, clip, popup_x, popup_y, popup_width, popup_height, fg_style, fg_style, header, title_style)

      content_lines.each_with_index do |line, index|
        y = popup_y + 1 + index
        break if y >= popup_y + popup_height - 1
        draw_text_line(buffer, clip, popup_x + 2, y, line, fg_style, popup_width - 3)
      end

      if content_lines.size < body_lines.size
        indicator = "… #{body_lines.size - content_lines.size} more"
        y = popup_y + popup_height - 2
        draw_text_line(buffer, clip, popup_x + 2, y, indicator, fg_style, popup_width - 3)
      end
    end
  end
end
