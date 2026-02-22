require "crystal_tui"

module CrystalEditor
  module ModalManager
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
        @context_menu_index = 0
        mark_dirty!
        return true
      when action_pressed?("app.menu_last", event)
        @context_menu_index = @context_menu_actions.size - 1
        mark_dirty!
        return true
      end

      if char = event.char
        if char >= '1' && char <= '9'
          index = (char - '1')
          if index >= 0 && index < @context_menu_actions.size
            @context_menu_index = index
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
      return if @context_menu_actions.empty?

      @context_menu_index += delta
      if @context_menu_index < 0
        @context_menu_index = @context_menu_actions.size - 1
      elsif @context_menu_index >= @context_menu_actions.size
        @context_menu_index = 0
      end
    end

    private def execute_selected_context_action : Nil
      return if @context_menu_actions.empty?

      index = @context_menu_index.clamp(0, @context_menu_actions.size - 1)
      action = @context_menu_actions[index]?
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
        @context_menu_title = title
        @context_menu_index = 0

        previous_overlay = @context_menu_overlay

        @context_menu_actions = actions
        @context_menu_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_lsp_context_menu(buffer, clip)
        }
        @context_menu_overlay = open_overlay(previous_overlay, @context_menu_overlay.not_nil!)
        @context_menu_open = true
        mark_dirty!
      end
    end

    private def close_context_menu : Nil
      return unless @context_menu_open

      close_overlay(@context_menu_overlay)

      @context_menu_open = false
      exit_input_mode(InputModeController::InputMode::ContextMenu)
      @context_menu_overlay = nil
      @context_menu_actions = [] of LspContextAction
      @context_menu_index = 0
      @context_menu_title = "Actions"
    end

    private def open_lsp_popup(title : String, lines : Array(String), max_lines : Int32 = 16) : Nil
      close_context_menu
      @lsp_popup_title = title
      @lsp_popup_lines = lines

      with_input_mode_guard(InputModeController::InputMode::LspPopup) do
        previous_overlay = @lsp_popup_overlay
        @lsp_popup_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_lsp_popup(buffer, clip, max_lines)
        }
        @lsp_popup_overlay = open_overlay(previous_overlay, @lsp_popup_overlay.not_nil!)
        @lsp_popup_open = true
        mark_dirty!
      end
    end

    private def close_lsp_popup : Nil
      return unless @lsp_popup_open

      close_overlay(@lsp_popup_overlay)

      @lsp_popup_open = false
      exit_input_mode(InputModeController::InputMode::LspPopup)
      @lsp_popup_title = ""
      @lsp_popup_lines = [] of String
      @lsp_popup_overlay = nil
    end

    private def render_lsp_context_menu(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return if @context_menu_actions.empty?

      menu_width = 60
      max_label = @context_menu_actions.map { |action| action.label.size }.max || 10
      max_shortcut = @context_menu_actions.map { |action| action.shortcut.size }.max || 0
      menu_width = [max_label + max_shortcut + 8, 12].max
      menu_height = @context_menu_actions.size + 2

      editor = current_editor
      base_rect = editor ? editor.rect : @body_split.rect
      menu_x = (base_rect.x + 2).clamp(clip.x, [clip.right - menu_width, clip.x].max)
      menu_y = (base_rect.y + 1).clamp(clip.y, [clip.bottom - menu_height, clip.y].max)

      fg_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      active_style = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
      header_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)
      title = @context_menu_title.empty? ? "Actions" : @context_menu_title

      # Border top
      buffer.set(menu_x, menu_y, '┌', fg_style) if clip.contains?(menu_x, menu_y)
      (1...menu_width - 1).each do |dx|
        buffer.set(menu_x + dx, menu_y, '─', fg_style) if clip.contains?(menu_x + dx, menu_y)
      end
      buffer.set(menu_x + menu_width - 1, menu_y, '┐', fg_style) if clip.contains?(menu_x + menu_width - 1, menu_y)

      # Header
      title_x = menu_x + 1
      title.each_char_with_index do |char, idx|
        break if title_x + idx >= menu_x + menu_width - 1
        buffer.set(title_x + idx, menu_y, char, header_style) if clip.contains?(title_x + idx, menu_y)
      end

      @context_menu_actions.each_with_index do |action, index|
        y = menu_y + 1 + index
        is_selected = index == @context_menu_index
        row_style = is_selected ? active_style : fg_style
        line_text = "#{index + 1}) #{action.label} [#{action.shortcut}]"
        line_text = line_text.ljust(menu_width - 2)[0, menu_width - 2]

        buffer.set(menu_x, y, '│', fg_style) if clip.contains?(menu_x, y)
        (1...menu_width - 1).each do |dx|
          buffer.set(menu_x + dx, y, ' ', row_style) if clip.contains?(menu_x + dx, y)
        end
        line_text.each_char_with_index do |char, idx|
          break if idx >= menu_width - 2
          buffer.set(menu_x + 1 + idx, y, char, row_style) if clip.contains?(menu_x + 1 + idx, y)
        end
        buffer.set(menu_x + menu_width - 1, y, '│', fg_style) if clip.contains?(menu_x + menu_width - 1, y)
      end

      bottom_y = menu_y + menu_height - 1
      buffer.set(menu_x, bottom_y, '└', fg_style) if clip.contains?(menu_x, bottom_y)
      (1...menu_width - 1).each do |dx|
        buffer.set(menu_x + dx, bottom_y, '─', fg_style) if clip.contains?(menu_x + dx, bottom_y)
      end
      buffer.set(menu_x + menu_width - 1, bottom_y, '┘', fg_style) if clip.contains?(menu_x + menu_width - 1, bottom_y)
    end

    private def render_lsp_popup(buffer : Tui::Buffer, clip : Tui::Rect, max_lines : Int32) : Nil
      return if @lsp_popup_lines.empty?

      body_lines = @lsp_popup_lines
      content_lines = body_lines[0, max_lines] || [] of String
      line_width = content_lines.map(&.size).max || 1
      popup_width = [line_width + 4, 90].min
      popup_height = content_lines.size + 4

      editor = current_editor
      base_rect = editor ? editor.rect : @body_split.rect
      popup_x = (base_rect.x + base_rect.width - popup_width - 2).clamp(clip.x, [clip.right - popup_width, clip.x].max)
      popup_y = (base_rect.y + 1).clamp(clip.y, [clip.bottom - popup_height, clip.y].max)

      fg_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)

      buffer.set(popup_x, popup_y, '┌', fg_style) if clip.contains?(popup_x, popup_y)
      (1...popup_width - 1).each do |dx|
        buffer.set(popup_x + dx, popup_y, '─', fg_style) if clip.contains?(popup_x + dx, popup_y)
      end
      buffer.set(popup_x + popup_width - 1, popup_y, '┐', fg_style) if clip.contains?(popup_x + popup_width - 1, popup_y)

      header = @lsp_popup_title.empty? ? "LSP" : @lsp_popup_title
      header.each_char_with_index do |char, idx|
        break if idx >= popup_width - 2
        buffer.set(popup_x + 1 + idx, popup_y, char, title_style) if clip.contains?(popup_x + 1 + idx, popup_y)
      end

      (1..popup_height - 2).each do |row|
        y = popup_y + row
        if y >= clip.bottom
          break
        end
        buffer.set(popup_x, y, '│', fg_style) if clip.contains?(popup_x, y)
        (1...popup_width - 1).each do |dx|
          buffer.set(popup_x + dx, y, ' ', fg_style) if clip.contains?(popup_x + dx, y)
        end
        buffer.set(popup_x + popup_width - 1, y, '│', fg_style) if clip.contains?(popup_x + popup_width - 1, y)
      end

      content_lines.each_with_index do |line, index|
        y = popup_y + 1 + index
        break if y >= popup_y + popup_height - 1
        line.each_char_with_index do |char, idx|
          break if idx >= popup_width - 3
          buffer.set(popup_x + 2 + idx, y, char, fg_style) if clip.contains?(popup_x + 2 + idx, y)
        end
      end

      if content_lines.size < body_lines.size
        indicator = "… #{body_lines.size - content_lines.size} more"
        y = popup_y + popup_height - 2
        indicator.each_char_with_index do |char, idx|
          break if idx >= popup_width - 3
          buffer.set(popup_x + 2 + idx, y, char, fg_style) if clip.contains?(popup_x + 2 + idx, y)
        end
      end

      bottom = popup_y + popup_height - 1
      if bottom < clip.bottom
        buffer.set(popup_x, bottom, '└', fg_style) if clip.contains?(popup_x, bottom)
        (1...popup_width - 1).each do |dx|
          buffer.set(popup_x + dx, bottom, '─', fg_style) if clip.contains?(popup_x + dx, bottom)
        end
        buffer.set(popup_x + popup_width - 1, bottom, '┘', fg_style) if clip.contains?(popup_x + popup_width - 1, bottom)
      end
    end
  end
end
