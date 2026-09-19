require "crystal_tui"

module Adamantine
  # State for the current-document Problems modal.  Diagnostics in this
  # state are already editor-codepoint ranges (see OpenBuffer#diagnostics).
  class ProblemsState
    include ModalState

    struct Row
      getter diagnostic : Lsp::Diagnostic
      getter source_index : Int32

      def initialize(@diagnostic : Lsp::Diagnostic, @source_index : Int32)
      end
    end

    property open : Bool
    property overlay : Tui::OverlayRenderer?
    property rows : Array(Row)
    property selected : Int32
    property top : Int32
    property partial : Bool
    property buffer_id : UInt64?
    property editor_id : UInt64?
    property version : Int32?
    property diagnostics_generation : UInt64?
    property client_id : UInt64?

    def initialize
      @open = false
      @overlay = nil
      @rows = [] of Row
      @selected = 0
      @top = 0
      @partial = false
      @buffer_id = nil
      @editor_id = nil
      @version = nil
      @diagnostics_generation = nil
      @client_id = nil
    end

    def reset_snapshot : Nil
      @rows = [] of Row
      @selected = 0
      @top = 0
      @partial = false
      @buffer_id = nil
      @editor_id = nil
      @version = nil
      @diagnostics_generation = nil
      @client_id = nil
    end
  end
end
