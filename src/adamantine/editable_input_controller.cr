require "crystal_tui"

require "../adamantine/clipboard"
require "../adamantine/editable_input"
require "../adamantine/input_mode_controller"

module Adamantine
  # App adapter for the pure EditableInput model. Key bindings, clipboard
  # authority, modal identity, and change callbacks remain outside the model.
  module EditableInputController
    private struct EditableInputPasteTarget
      getter input : EditableInput
      getter mode : InputModeController::InputMode
      getter revision : UInt64
      getter cursor : Int32
      getter selection : {Int32, Int32}?
      getter generation : UInt64

      def initialize(
        @input : EditableInput,
        @mode : InputModeController::InputMode,
        @generation : UInt64,
      )
        @revision = input.revision
        @cursor = input.cursor
        @selection = input.selection_range
      end
    end

    private def handle_editable_input_key(
      input : EditableInput,
      event : Tui::KeyEvent,
      on_change : Proc(Nil),
      on_reject : Proc(Nil)? = nil,
    ) : Bool
      text_event = editable_input_text_event?(event)
      if !text_event && action_pressed?("app.copy", event)
        if selected = input.selected_text
          unless @clipboard.remember(selected)
            @status_log.warning("Selection is too large or is not valid UTF-8; copy skipped")
          end
        end
        mark_dirty!
        return true
      end

      if !text_event && action_pressed?("app.cut", event)
        if selected = input.selected_text
          if @clipboard.remember(selected)
            input.delete_selection
            on_change.call
          else
            @status_log.warning("Selection is too large or is not valid UTF-8; cut skipped")
          end
        end
        mark_dirty!
        return true
      end

      if !text_event && action_pressed?("app.paste", event)
        request_editable_input_paste(input, on_change, on_reject)
        return true
      end

      handled = true
      before = input.revision
      extend_selection = event.modifiers.shift?
      word = event.modifiers.alt? || event.modifiers.ctrl?

      case event.key
      when .left?
        word ? input.move_word_left(extend_selection: extend_selection) : input.move_left(extend_selection: extend_selection)
      when .right?
        word ? input.move_word_right(extend_selection: extend_selection) : input.move_right(extend_selection: extend_selection)
      when .home?
        input.move_home(extend_selection: extend_selection)
      when .end?
        input.move_end(extend_selection: extend_selection)
      when .backspace?
        if event.modifiers.alt? || event.modifiers.ctrl?
          input.delete_word_backward
        else
          input.delete_backward
        end
      when .delete?
        if event.modifiers.alt? || event.modifiers.ctrl?
          input.delete_word_forward
        else
          input.delete_forward
        end
      else
        handled = handle_editable_input_named_key(input, event, extend_selection)
      end

      return false unless handled

      if input.revision != before
        on_change.call
      elsif editable_input_insert_event?(event)
        on_reject.try(&.call)
      end
      mark_dirty!
      true
    end

    private def handle_editable_input_paste(
      input : EditableInput,
      text : String,
      on_change : Proc(Nil),
      on_reject : Proc(Nil)? = nil,
    ) : Bool
      before = input.revision
      inserted = input.insert_paste(text)
      on_change.call if input.revision != before
      on_reject.try(&.call) if !inserted && !text.empty?
      mark_dirty!
      true
    end

    private def handle_editable_input_named_key(
      input : EditableInput,
      event : Tui::KeyEvent,
      extend_selection : Bool,
    ) : Bool
      if event.matches?("ctrl+a")
        input.select_all
        return true
      end
      if event.matches?("ctrl+b")
        input.move_left(extend_selection: extend_selection)
        return true
      end
      if event.matches?("ctrl+f")
        input.move_right(extend_selection: extend_selection)
        return true
      end
      if event.matches?("ctrl+e")
        input.move_end(extend_selection: extend_selection)
        return true
      end
      if event.matches?("ctrl+u")
        input.clear_to_beginning
        return true
      end
      if event.matches?("ctrl+k")
        input.clear_to_end
        return true
      end
      if event.matches?("alt+b")
        input.move_word_left(extend_selection: extend_selection)
        return true
      end
      if event.matches?("alt+f")
        input.move_word_right(extend_selection: extend_selection)
        return true
      end
      if event.matches?("alt+d")
        input.delete_word_forward
        return true
      end

      # Modified printable keys belong to the modal command layer; they must
      # not leak a character into the line or fall through to the editor.
      return true if event.modifiers.ctrl? || event.modifiers.alt? || event.modifiers.meta?

      if char = event.char
        return true unless char.printable? && char.ord != 127
        input.insert(char.to_s)
        return true
      end

      if event.matches?("space")
        input.insert(" ")
        return true
      end

      false
    end

    private def editable_input_text_event?(event : Tui::KeyEvent) : Bool
      return false if event.modifiers.ctrl? || event.modifiers.alt? || event.modifiers.meta?
      char = event.char
      !char.nil? && char.not_nil!.printable? && char.not_nil!.ord != 127
    end

    private def editable_input_insert_event?(event : Tui::KeyEvent) : Bool
      editable_input_text_event?(event) ||
        (!event.modifiers.ctrl? && !event.modifiers.alt? && !event.modifiers.meta? && event.matches?("space"))
    end

    private def request_editable_input_paste(
      input : EditableInput,
      on_change : Proc(Nil),
      on_reject : Proc(Nil)? = nil,
    ) : Nil
      target = EditableInputPasteTarget.new(input, active_input_mode, @clipboard_paste_generation)
      if @clipboard.pending_write? || @clipboard.external_sync_failed?
        apply_editable_input_clipboard_text(target, @clipboard.value, on_change, on_reject)
        return
      end

      @clipboard.read_async do |result|
        text = result.success? ? result.text : @clipboard.value
        apply_editable_input_clipboard_text(target, text, on_change, on_reject)
      end
    end

    private def apply_editable_input_clipboard_text(
      target : EditableInputPasteTarget,
      text : String?,
      on_change : Proc(Nil),
      on_reject : Proc(Nil)?,
    ) : Nil
      return unless text
      return if text.empty? || text.bytesize > Clipboard::MAX_BYTES || !text.valid_encoding?
      return unless editable_input_paste_target_current?(target)

      before = target.input.revision
      inserted = target.input.insert_paste(text)
      on_change.call if target.input.revision != before
      on_reject.try(&.call) unless inserted
      mark_dirty!
      wakeup
    end

    private def editable_input_paste_target_current?(target : EditableInputPasteTarget) : Bool
      return false unless target.generation == @clipboard_paste_generation
      return false unless active_input_mode == target.mode
      return false unless target.input.revision == target.revision
      return false unless target.input.cursor == target.cursor
      return false unless target.input.selection_range == target.selection

      case target.mode
      when InputModeController::InputMode::CommandPalette
        @command_palette.open && @command_palette.input_field.same?(target.input)
      when InputModeController::InputMode::QuickOpen
        @quick_open.open && @quick_open.query_input.same?(target.input)
      when InputModeController::InputMode::SearchPanel
        @search.open && @search.query_input.same?(target.input)
      else
        false
      end
    end
  end
end
