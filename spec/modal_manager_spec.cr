require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

class ModalManagerTestApp < Adamantine::App
  def open_context_menu_public(title : String, actions : Array(Adamantine::LspContextAction)) : Nil
    open_context_menu(title, actions)
  end

  def open_lsp_popup_public(title : String, lines : Array(String)) : Nil
    open_lsp_popup(title, lines)
  end

  def close_context_menu_public : Nil
    close_context_menu
  end

  def close_lsp_popup_public : Nil
    close_lsp_popup
  end

  def context_menu_open? : Bool
    @context_menu.open
  end

  def context_menu_index : Int32
    @context_menu.index
  end

  def context_menu_index=(value : Int32) : Nil
    @context_menu.index = value
  end

  def context_menu_actions_size : Int32
    @context_menu.actions.size
  end

  def lsp_popup_open? : Bool
    @lsp_popup.open
  end

  def handle_context_menu_input_public(event : Tui::KeyEvent) : Bool
    handle_context_menu_input(event)
  end

  def handle_lsp_popup_input_public(event : Tui::KeyEvent) : Bool
    handle_lsp_popup_input(event)
  end

  def move_context_menu_selection_public(delta : Int32) : Nil
    move_context_menu_selection(delta)
  end

  def execute_selected_context_action_public : Nil
    execute_selected_context_action
  end
end

def with_temp_workspace(prefix : String = "editor-modal-manager-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::App do
  describe "ModalManager" do
    describe "move_context_menu_selection" do
      it "wraps from first to last when moving up" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          actions = [
            Adamantine::LspContextAction.new("A", "1", -> { }),
            Adamantine::LspContextAction.new("B", "2", -> { }),
            Adamantine::LspContextAction.new("C", "3", -> { }),
          ]
          app.open_context_menu_public("Test", actions)
          raise "menu should be open" unless app.context_menu_open?
          raise "index should start at 0" unless app.context_menu_index == 0

          app.move_context_menu_selection_public(-1)
          raise "should wrap to last (2)" unless app.context_menu_index == 2
        end
      end

      it "wraps from last to first when moving down" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          actions = [
            Adamantine::LspContextAction.new("A", "1", -> { }),
            Adamantine::LspContextAction.new("B", "2", -> { }),
            Adamantine::LspContextAction.new("C", "3", -> { }),
          ]
          app.open_context_menu_public("Test", actions)
          app.context_menu_index = 2

          app.move_context_menu_selection_public(1)
          raise "should wrap to first (0)" unless app.context_menu_index == 0
        end
      end

      it "does nothing when actions are empty" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          # Don't open menu, just call move directly
          app.move_context_menu_selection_public(1)
          raise "index should remain 0" unless app.context_menu_index == 0
        end
      end

      it "moves forward normally" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          actions = [
            Adamantine::LspContextAction.new("A", "1", -> { }),
            Adamantine::LspContextAction.new("B", "2", -> { }),
            Adamantine::LspContextAction.new("C", "3", -> { }),
          ]
          app.open_context_menu_public("Test", actions)

          app.move_context_menu_selection_public(1)
          raise "should be 1" unless app.context_menu_index == 1

          app.move_context_menu_selection_public(1)
          raise "should be 2" unless app.context_menu_index == 2
        end
      end
    end

    describe "execute_selected_context_action" do
      it "calls the action callback and closes menu" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          called = false
          actions = [
            Adamantine::LspContextAction.new("Action", "1", -> { called = true }),
          ]
          app.open_context_menu_public("Test", actions)
          raise "menu should be open" unless app.context_menu_open?

          app.execute_selected_context_action_public
          raise "action should have been called" unless called
          raise "menu should be closed" if app.context_menu_open?
        end
      end

      it "does nothing when actions are empty" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          # No menu opened, actions empty
          app.execute_selected_context_action_public
          # Should not raise
        end
      end

      it "clamps index to valid range" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          called = false
          actions = [
            Adamantine::LspContextAction.new("Only", "1", -> { called = true }),
          ]
          app.open_context_menu_public("Test", actions)
          app.context_menu_index = 99

          app.execute_selected_context_action_public
          raise "should still call clamped action" unless called
        end
      end
    end

    describe "context menu open/close" do
      it "does not open menu with empty actions" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          app.open_context_menu_public("Empty", [] of Adamantine::LspContextAction)
          raise "menu should not open with empty actions" if app.context_menu_open?
        end
      end

      it "closes context menu and resets state" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          actions = [
            Adamantine::LspContextAction.new("A", "1", -> { }),
          ]
          app.open_context_menu_public("Test", actions)
          raise "should be open" unless app.context_menu_open?

          app.close_context_menu_public
          raise "should be closed" if app.context_menu_open?
          raise "actions should be cleared" unless app.context_menu_actions_size == 0
          raise "index should be reset" unless app.context_menu_index == 0
        end
      end
    end

    describe "LSP popup open/close" do
      it "opens and closes popup" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          app.open_lsp_popup_public("Test", ["line1", "line2"])
          raise "popup should be open" unless app.lsp_popup_open?

          app.close_lsp_popup_public
          raise "popup should be closed" if app.lsp_popup_open?
        end
      end

      it "closing already-closed popup is a no-op" do
        with_temp_workspace do |tmp|
          app = ModalManagerTestApp.new(project_root: tmp, lsp_command: "")
          raise "should start closed" if app.lsp_popup_open?
          app.close_lsp_popup_public
          raise "should remain closed" if app.lsp_popup_open?
        end
      end
    end
  end
end
