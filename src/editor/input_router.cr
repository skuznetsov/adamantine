require "crystal_tui"
require "./keyboard_mode_engine"

module CrystalEditor
  module InputRouter
    include KeyboardModeEngine

    private alias KeyRoute = NamedTuple(action: String, handler: Proc(Bool))

    private def route_key_event(event : Tui::KeyEvent) : Bool
      if event.key != Tui::Key::Escape
        @command_last_escape_ms = 0
      end

      return true if route_key_modes(event, key_mode_routes(event))

      false
    end

    private def key_mode_routes(event : Tui::KeyEvent) : Array(KeyModeRoute)
      [
        KeyModeRoute.new(
          ->(_event : Tui::KeyEvent) { command_palette_active? },
          ->(inner_event : Tui::KeyEvent) { handle_command_palette_input(inner_event) },
        ),
        KeyModeRoute.new(
          ->(inner_event : Tui::KeyEvent) { action_pressed?("app.command_palette", inner_event) || command_palette_double_escape?(inner_event) },
          ->(_inner_event : Tui::KeyEvent) { open_command_palette; true },
        ),
        KeyModeRoute.new(
          ->(_inner_event : Tui::KeyEvent) { settings_mode_active? },
          ->(inner_event : Tui::KeyEvent) { handle_settings_input(inner_event) },
        ),
        KeyModeRoute.new(
          ->(_inner_event : Tui::KeyEvent) { context_menu_mode_active? },
          ->(inner_event : Tui::KeyEvent) { handle_context_menu_input(inner_event) },
        ),
        KeyModeRoute.new(
          ->(_inner_event : Tui::KeyEvent) { lsp_popup_mode_active? },
          ->(inner_event : Tui::KeyEvent) { handle_lsp_popup_input(inner_event) },
        ),
        KeyModeRoute.new(
          ->(_inner_event : Tui::KeyEvent) { true },
          ->(inner_event : Tui::KeyEvent) { route_global_key_actions(inner_event) },
        ),
      ]
    end

    private def route_global_key_actions(event : Tui::KeyEvent) : Bool
      key_routes.each do |route|
        next unless action_pressed?(route[:action], event)
        return route[:handler].call
      end

      false
    end

    private def key_routes : Array(KeyRoute)
      [
        {action: "app.open_file_tree", handler: -> { open_file_tree_action }},
        {action: "app.next_tab", handler: -> { switch_to_next_tab_action }},
        {action: "app.previous_tab", handler: -> { switch_to_previous_tab_action }},
        {action: "app.goto_tab_1", handler: -> { switch_to_tab_by_position_action(0) }},
        {action: "app.goto_tab_2", handler: -> { switch_to_tab_by_position_action(1) }},
        {action: "app.goto_tab_3", handler: -> { switch_to_tab_by_position_action(2) }},
        {action: "app.goto_tab_4", handler: -> { switch_to_tab_by_position_action(3) }},
        {action: "app.goto_tab_5", handler: -> { switch_to_tab_by_position_action(4) }},
        {action: "app.goto_tab_6", handler: -> { switch_to_tab_by_position_action(5) }},
        {action: "app.goto_tab_7", handler: -> { switch_to_tab_by_position_action(6) }},
        {action: "app.goto_tab_8", handler: -> { switch_to_tab_by_position_action(7) }},
        {action: "app.goto_tab_9", handler: -> { switch_to_tab_by_position_action(8) }},
        {action: "app.quick_actions", handler: -> { open_quick_actions_action }},
        {action: "lsp.goto_definition", handler: -> { goto_definition_action }},
        {action: "lsp.hover", handler: -> { show_hover_hint_action }},
        {action: "lsp.references", handler: -> { show_references_hint_action }},
        {action: "lsp.signature", handler: -> { show_signature_hint_action }},
        {action: "lsp.context_menu", handler: -> { open_lsp_context_menu_action }},
        {action: "app.settings", handler: -> { open_settings_dialog_action }},
        {action: "app.save", handler: -> { save_active_action }},
        {action: "app.close_tab", handler: -> { close_active_tab_action }},
        {action: "lsp.status", handler: -> { show_lsp_status_action }},
        {action: "app.focus_tree", handler: -> { focus_tree_action }},
        {action: "app.focus_editor", handler: -> { focus_editor_action }},
        {action: "app.refresh_tree", handler: -> { refresh_file_tree_action }},
        {action: "app.reload_theme", handler: -> { reload_theme_action }},
        {action: "app.help", handler: -> { show_help_action }},
        {action: "app.quit", handler: -> { quit_action }},
        {action: "app.jump_back", handler: -> { jump_back_action }},
        {action: "app.jump_forward", handler: -> { jump_forward_action }},
      ] of KeyRoute
    end

    private def open_file_tree_action : Bool
      @file_panel.focus
      true
    end

    private def switch_to_next_tab_action : Bool
      switch_to_next_tab
      true
    end

    private def switch_to_previous_tab_action : Bool
      switch_to_previous_tab
      true
    end

    private def switch_to_tab_by_position_action(position : Int32) : Bool
      switch_to_tab_by_position(position)
      true
    end

    private def open_quick_actions_action : Bool
      open_quick_actions_menu
      true
    end

    private def goto_definition_action : Bool
      goto_definition
      true
    end

    private def show_hover_hint_action : Bool
      show_hover_hint
      true
    end

    private def show_references_hint_action : Bool
      show_references_hint
      true
    end

    private def show_signature_hint_action : Bool
      show_signature_hint
      true
    end

    private def open_lsp_context_menu_action : Bool
      open_lsp_context_menu
      true
    end

    private def open_settings_dialog_action : Bool
      open_settings_dialog
      true
    end

    private def save_active_action : Bool
      save_active
      true
    end

    private def close_active_tab_action : Bool
      close_active_tab
      true
    end

    private def show_lsp_status_action : Bool
      show_lsp_status
      true
    end

    private def focus_tree_action : Bool
      @file_panel.focus
      true
    end

    private def focus_editor_action : Bool
      if @editor_tabs.active_tab_id
        focus_active_editor
      else
        @file_panel.focus
      end
      true
    end

    private def refresh_file_tree_action : Bool
      refresh_file_tree
      true
    end

    private def reload_theme_action : Bool
      reload_theme
      true
    end

    private def show_help_action : Bool
      show_help
      true
    end

    private def quit_action : Bool
      quit
      true
    end

    private def jump_back_action : Bool
      jump_back
      true
    end

    private def jump_forward_action : Bool
      jump_forward
      true
    end
  end
end
