require "crystal_tui"
require "../adamantine/modal_state"
require "../adamantine/lsp_action"

module Adamantine
  class LspPopupState
    include ModalState

    property open : Bool = false
    property title : String = ""
    property lines : Array(String) = [] of String
    # Completion rows keep their structured items separate from the generic
    # read-only popup text. This lets selection/scrolling change presentation
    # without losing the captured request authority used on acceptance.
    property completion_items : Array(Lsp::CompletionItem)? = nil
    property completion_request : InteractiveLspRequest? = nil
    property completion_index : Int32 = 0
    property completion_top : Int32 = 0
    property completion_max_lines : Int32 = 0
    property overlay : Tui::OverlayRenderer? = nil

    def completion_open? : Bool
      !@completion_items.nil? && !@completion_request.nil?
    end

    def clear_completion : Nil
      @completion_items = nil
      @completion_request = nil
      @completion_index = 0
      @completion_top = 0
      @completion_max_lines = 0
    end
  end
end
