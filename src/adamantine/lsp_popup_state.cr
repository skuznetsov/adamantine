require "crystal_tui"
require "json"
require "../adamantine/modal_state"
require "../adamantine/lsp_action"
require "../adamantine/safe_document_edits"
require "../adamantine/inline_edit_preview"

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
    property formatting_preview : InlineEditPreview::Model? = nil
    property formatting_top : Int32 = 0
    property formatting_max_lines : Int32 = 0
    # Rename and Quick Fix reuse the guarded formatting preview surface but
    # keep their request/plan separate so existing formatting state and tests
    # remain source compatible.
    property refactor_request : InteractiveLspRequest? = nil
    property refactor_plan : SafeDocumentEdits::Plan? = nil
    property refactor_preview : InlineEditPreview::Model? = nil
    property refactor_title : String = ""
    property refactor_top : Int32 = 0
    property refactor_max_lines : Int32 = 0
    # Quick Fix has a picker phase before it installs a refactor preview.
    # Invalid/over-limit server actions are counted and shown in the popup
    # instead of disappearing silently.
    property quick_fix_actions : Array(JSON::Any)? = nil
    property quick_fix_request : InteractiveLspRequest? = nil
    property quick_fix_index : Int32 = 0
    property quick_fix_top : Int32 = 0
    property quick_fix_max_lines : Int32 = 0
    property quick_fix_omitted_count : Int32 = 0
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

    def refactor_open? : Bool
      !@refactor_request.nil? && !@refactor_plan.nil?
    end

    def edit_preview_open? : Bool
      formatting_open? || refactor_open?
    end

    def edit_preview : InlineEditPreview::Model?
      @formatting_preview || @refactor_preview
    end

    def quick_fix_open? : Bool
      !@quick_fix_actions.nil? && !@quick_fix_request.nil?
    end

    def clear_formatting : Nil
      @formatting_request = nil
      @formatting_plan = nil
      @formatting_preview = nil
      @formatting_top = 0
      @formatting_max_lines = 0
    end

    def clear_refactor : Nil
      @refactor_request = nil
      @refactor_plan = nil
      @refactor_preview = nil
      @refactor_title = ""
      @refactor_top = 0
      @refactor_max_lines = 0
    end

    def clear_quick_fix : Nil
      @quick_fix_actions = nil
      @quick_fix_request = nil
      @quick_fix_index = 0
      @quick_fix_top = 0
      @quick_fix_max_lines = 0
      @quick_fix_omitted_count = 0
    end
  end
end
