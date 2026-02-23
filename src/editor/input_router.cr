require "crystal_tui"
require "./keyboard_mode_engine"

module CrystalEditor
  module InputRouter
    include KeyboardModeEngine

    private alias KeyRoute = NamedTuple(action: String, handler: Proc(Bool), label: String)

    private def route_key_event(event : Tui::KeyEvent) : Bool
      if event.key != Tui::Key::Escape
        @command_palette.last_escape_ms = 0
      end

      return true if route_key_modes(event, key_mode_routes)

      false
    end

    private def key_mode_routes : Array(KeyModeRoute)
      [
        KeyModeRoute.new(
          "command_palette_active",
          ->(_event : Tui::KeyEvent) { command_palette_active? },
          ->(inner_event : Tui::KeyEvent) { handle_command_palette_input(inner_event) },
        ),
        KeyModeRoute.new(
          "command_palette_open",
          ->(inner_event : Tui::KeyEvent) { action_pressed?("app.command_palette", inner_event) || command_palette_double_escape?(inner_event) },
          ->(_inner_event : Tui::KeyEvent) { open_command_palette; true },
        ),
        KeyModeRoute.new(
          "settings_active",
          ->(_inner_event : Tui::KeyEvent) { settings_mode_active? },
          ->(inner_event : Tui::KeyEvent) { handle_settings_input(inner_event) },
        ),
        KeyModeRoute.new(
          "context_menu_active",
          ->(_inner_event : Tui::KeyEvent) { context_menu_mode_active? },
          ->(inner_event : Tui::KeyEvent) { handle_context_menu_input(inner_event) },
        ),
        KeyModeRoute.new(
          "lsp_popup_active",
          ->(_inner_event : Tui::KeyEvent) { lsp_popup_mode_active? },
          ->(inner_event : Tui::KeyEvent) { handle_lsp_popup_input(inner_event) },
        ),
        KeyModeRoute.new(
          "global_fallback",
          ->(_inner_event : Tui::KeyEvent) { true },
          ->(inner_event : Tui::KeyEvent) { route_global_key_actions(inner_event) },
        ),
      ]
    end

    protected def key_mode_route_labels : Array(String)
      key_mode_routes.map(&.label)
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
        {action: "app.open_file_tree", handler: -> { open_file_tree_action }, label: "app.open_file_tree"},
        {action: "app.next_tab", handler: -> { switch_to_next_tab_action }, label: "app.next_tab"},
        {action: "app.previous_tab", handler: -> { switch_to_previous_tab_action }, label: "app.previous_tab"},
        {action: "app.goto_tab_1", handler: -> { switch_to_tab_by_position_action(0) }, label: "app.goto_tab_1"},
        {action: "app.goto_tab_2", handler: -> { switch_to_tab_by_position_action(1) }, label: "app.goto_tab_2"},
        {action: "app.goto_tab_3", handler: -> { switch_to_tab_by_position_action(2) }, label: "app.goto_tab_3"},
        {action: "app.goto_tab_4", handler: -> { switch_to_tab_by_position_action(3) }, label: "app.goto_tab_4"},
        {action: "app.goto_tab_5", handler: -> { switch_to_tab_by_position_action(4) }, label: "app.goto_tab_5"},
        {action: "app.goto_tab_6", handler: -> { switch_to_tab_by_position_action(5) }, label: "app.goto_tab_6"},
        {action: "app.goto_tab_7", handler: -> { switch_to_tab_by_position_action(6) }, label: "app.goto_tab_7"},
        {action: "app.goto_tab_8", handler: -> { switch_to_tab_by_position_action(7) }, label: "app.goto_tab_8"},
        {action: "app.goto_tab_9", handler: -> { switch_to_tab_by_position_action(8) }, label: "app.goto_tab_9"},
        {action: "app.quick_actions", handler: -> { open_quick_actions_action }, label: "app.quick_actions"},
        {action: "lsp.goto_definition", handler: -> { goto_definition_action }, label: "lsp.goto_definition"},
        {action: "lsp.hover", handler: -> { show_hover_hint_action }, label: "lsp.hover"},
        {action: "lsp.references", handler: -> { show_references_hint_action }, label: "lsp.references"},
        {action: "lsp.signature", handler: -> { show_signature_hint_action }, label: "lsp.signature"},
        {action: "lsp.context_menu", handler: -> { open_lsp_context_menu_action }, label: "lsp.context_menu"},
        {action: "app.settings", handler: -> { open_settings_dialog_action }, label: "app.settings"},
        {action: "app.save", handler: -> { save_active_action }, label: "app.save"},
        {action: "app.close_tab", handler: -> { close_active_tab_action }, label: "app.close_tab"},
        {action: "lsp.status", handler: -> { show_lsp_status_action }, label: "lsp.status"},
        {action: "app.focus_tree", handler: -> { focus_tree_action }, label: "app.focus_tree"},
        {action: "app.focus_editor", handler: -> { focus_editor_action }, label: "app.focus_editor"},
        {action: "app.refresh_tree", handler: -> { refresh_file_tree_action }, label: "app.refresh_tree"},
        {action: "app.reload_theme", handler: -> { reload_theme_action }, label: "app.reload_theme"},
        {action: "app.help", handler: -> { show_help_action }, label: "app.help"},
        {action: "app.quit", handler: -> { quit_action }, label: "app.quit"},
        {action: "app.jump_back", handler: -> { jump_back_action }, label: "app.jump_back"},
        {action: "app.jump_forward", handler: -> { jump_forward_action }, label: "app.jump_forward"},
      ] of KeyRoute
    end

    protected def global_key_route_labels : Array(String)
      key_routes.map(&.[]("label"))
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
