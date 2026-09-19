require "crystal_tui"
require "../adamantine/modal_state"
require "../adamantine/lsp_action"
require "../adamantine/safe_document_edits"

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
    # Formatting owns the same modal surface as other LSP previews, but keeps
    # its validated detached plan separate from display-only rows.  The plan
    # is the only authority accepted by Enter; preview scrolling never edits
    # or reconstructs it.
    property formatting_request : InteractiveLspRequest? = nil
    property formatting_plan : SafeDocumentEdits::Plan? = nil
    property formatting_top : Int32 = 0
    property formatting_max_lines : Int32 = 0
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

    def formatting_open? : Bool
      !@formatting_request.nil? && !@formatting_plan.nil?
    end

    def clear_formatting : Nil
      @formatting_request = nil
      @formatting_plan = nil
      @formatting_top = 0
      @formatting_max_lines = 0
    end
  end
end
