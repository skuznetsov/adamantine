require "crystal_tui"

module CrystalEditor
  module InputRouter
    private def route_key_event(event : Tui::KeyEvent) : Bool
      if event.key != Tui::Key::Escape
        @command_last_escape_ms = 0
      end

      if command_palette_active?
        return true if handle_command_palette_input(event)
      end

      if action_pressed?("app.command_palette", event) || command_palette_double_escape?(event)
        open_command_palette
        return true
      end

      if @settings_open
        return true if handle_settings_input(event)
      end

      if @context_menu_open
        return true if handle_context_menu_input(event)
      end

      if @lsp_popup_open
        return true if handle_lsp_popup_input(event)
      end

      if action_pressed?("app.open_file_tree", event)
        @file_panel.focus
        return true
      elsif action_pressed?("app.next_tab", event)
        switch_to_next_tab
        return true
      elsif action_pressed?("app.previous_tab", event)
        switch_to_previous_tab
        return true
      elsif action_pressed?("app.goto_tab_1", event)
        switch_to_tab_by_position(0)
        return true
      elsif action_pressed?("app.goto_tab_2", event)
        switch_to_tab_by_position(1)
        return true
      elsif action_pressed?("app.goto_tab_3", event)
        switch_to_tab_by_position(2)
        return true
      elsif action_pressed?("app.goto_tab_4", event)
        switch_to_tab_by_position(3)
        return true
      elsif action_pressed?("app.goto_tab_5", event)
        switch_to_tab_by_position(4)
        return true
      elsif action_pressed?("app.goto_tab_6", event)
        switch_to_tab_by_position(5)
        return true
      elsif action_pressed?("app.goto_tab_7", event)
        switch_to_tab_by_position(6)
        return true
      elsif action_pressed?("app.goto_tab_8", event)
        switch_to_tab_by_position(7)
        return true
      elsif action_pressed?("app.goto_tab_9", event)
        switch_to_tab_by_position(8)
        return true
      elsif action_pressed?("app.quick_actions", event)
        open_quick_actions_menu
        return true
      elsif action_pressed?("lsp.goto_definition", event)
        goto_definition
        return true
      elsif action_pressed?("lsp.hover", event)
        show_hover_hint
        return true
      elsif action_pressed?("lsp.references", event)
        show_references_hint
        return true
      elsif action_pressed?("lsp.signature", event)
        show_signature_hint
        return true
      elsif action_pressed?("lsp.context_menu", event)
        open_lsp_context_menu
        return true
      elsif action_pressed?("app.settings", event)
        open_settings_dialog
        return true
      elsif action_pressed?("app.save", event)
        save_active
        return true
      elsif action_pressed?("app.close_tab", event)
        close_active_tab
        return true
      elsif action_pressed?("lsp.status", event)
        show_lsp_status
        return true
      elsif action_pressed?("app.focus_tree", event)
        @file_panel.focus
        return true
      elsif action_pressed?("app.focus_editor", event)
        if @editor_tabs.active_tab_id
          focus_active_editor
        else
          @file_panel.focus
        end
        return true
      elsif action_pressed?("app.refresh_tree", event)
        refresh_file_tree
        return true
      elsif action_pressed?("app.reload_theme", event)
        reload_theme
        return true
      elsif action_pressed?("app.help", event)
        show_help
        return true
      elsif action_pressed?("app.quit", event)
        quit
        return true
      elsif action_pressed?("app.jump_back", event)
        jump_back
        return true
      elsif action_pressed?("app.jump_forward", event)
        jump_forward
        return true
      end

      false
    end
  end
end
