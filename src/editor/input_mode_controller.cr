module CrystalEditor
  module InputModeController
    enum InputMode
      Normal
      CommandPalette
      Settings
      ContextMenu
      LspPopup
    end

    private def set_command_palette_active_mode : Nil
      enter_input_mode(InputMode::CommandPalette)
    end

    private def set_command_palette_inactive_mode : Nil
      exit_input_mode(InputMode::CommandPalette)
    end

    private def with_input_mode_guard(mode : InputMode, &)
      previous_stack = input_mode_stack_snapshot
      enter_input_mode(mode)
      yield
    rescue ex
      @input_mode_stack = previous_stack.not_nil!
      raise ex
    end

    private def command_palette_active? : Bool
      active_input_mode == InputMode::CommandPalette
    end

    private def settings_mode_active? : Bool
      active_input_mode == InputMode::Settings
    end

    private def context_menu_mode_active? : Bool
      active_input_mode == InputMode::ContextMenu
    end

    private def lsp_popup_mode_active? : Bool
      active_input_mode == InputMode::LspPopup
    end

    private def active_input_mode : InputMode
      @input_mode_stack.last? || InputMode::Normal
    end

    private def enter_input_mode(mode : InputMode) : Nil
      @input_mode_stack.delete(mode)
      @input_mode_stack << mode
    end

    private def exit_input_mode(mode : InputMode) : Nil
      index = @input_mode_stack.rindex { |item| item == mode }
      @input_mode_stack.delete_at(index) if index
    end

    private def input_mode_stack_snapshot : Array(InputMode)
      @input_mode_stack.dup
    end
  end
end
