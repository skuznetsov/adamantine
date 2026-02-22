module CrystalEditor
  module InputModeController
    class ModeStack
      @stack : Array(InputMode) = [] of InputMode

      def initialize
        @stack = [] of InputMode
      end

      def enter(mode : InputMode) : Nil
        @stack.delete(mode)
        @stack << mode
      end

      def exit(mode : InputMode) : Nil
        index = @stack.rindex { |item| item == mode }
        @stack.delete_at(index) if index
      end

      def active : InputMode
        @stack.last? || InputMode::Normal
      end

      def snapshot : Array(InputMode)
        @stack.dup
      end

      def restore(stack : Array(InputMode) | Nil) : Nil
        @stack = stack || [] of InputMode
      end

      def clear : Nil
        @stack.clear
      end
    end

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

    private def input_mode_controller : ModeStack
      @input_mode_controller
    end

    private def with_input_mode_guard(mode : InputMode, &)
      previous_stack = input_mode_controller.snapshot
      enter_input_mode(mode)
      yield
    rescue ex
      input_mode_controller.restore(previous_stack)
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
      input_mode_controller.active
    end

    private def enter_input_mode(mode : InputMode) : Nil
      input_mode_controller.enter(mode)
    end

    private def exit_input_mode(mode : InputMode) : Nil
      input_mode_controller.exit(mode)
    end

    protected def input_mode_stack_snapshot : Array(InputMode)
      input_mode_controller.snapshot
    end
  end
end
