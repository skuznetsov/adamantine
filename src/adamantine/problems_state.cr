require "crystal_tui"

module Adamantine
  # State for the open-files Problems modal. Diagnostics in this state are
  # already editor-codepoint ranges (see OpenBuffer#diagnostics). Each row
  # carries the authority needed to revalidate its exact live target.
  class ProblemsState
    include ModalState

    struct Row
      getter diagnostic : Lsp::Diagnostic
      getter source_index : Int32
      getter buffer_path : String
      getter display_path : String
      getter buffer_id : UInt64
      getter editor_id : UInt64
      getter version : Int32
      getter diagnostics_generation : UInt64

      def initialize(
        @diagnostic : Lsp::Diagnostic,
        @source_index : Int32,
        @buffer_path : String,
        @display_path : String,
        @buffer_id : UInt64,
        @editor_id : UInt64,
        @version : Int32,
        @diagnostics_generation : UInt64,
      )
      end
    end

    property open : Bool
    property overlay : Tui::OverlayRenderer?
    property rows : Array(Row)
    property selected : Int32
    property top : Int32
    property partial : Bool
    property client_id : UInt64?

    def initialize
      @open = false
      @overlay = nil
      @rows = [] of Row
      @selected = 0
      @top = 0
      @partial = false
      @client_id = nil
    end

    def reset_snapshot : Nil
      @rows = [] of Row
      @selected = 0
      @top = 0
      @partial = false
      @client_id = nil
    end
  end
end
