require "crystal_tui"
require "../adamantine/modal_state"
require "../adamantine/quick_open_search"
require "../adamantine/editable_input"

module Adamantine
  # State owned by the quick-open modal.  The index is deliberately scoped to
  # one popup/root lifetime: it is not a project-wide cache and never retains
  # file contents.
  class QuickOpenState
    include ModalState

    MAX_QUERY_CODEPOINTS = 256

    property open : Bool = false
    property overlay : Tui::OverlayRenderer? = nil
    getter query_input : EditableInput = EditableInput.new("", max_codepoints: MAX_QUERY_CODEPOINTS)
    property matches : Array(QuickOpenSearch::FilePathMatch) = [] of QuickOpenSearch::FilePathMatch
    property selected_index : Int32 = 0
    property scroll : Int32 = 0
    property searching : Bool = false
    property partial : Bool = false
    property status : String = ""
    property generation : UInt64 = 0_u64
    property root : Path? = nil
    property index : QuickOpenSearch::FileIndex? = nil
    property cancellation : QuickOpenSearch::Cancellation? = nil
    property pending_query : String? = nil
    property worker_active : Bool = false

    def query : String
      @query_input.value
    end

    def query=(value : String) : String
      @query_input.value = value
    end

    def query_cursor : Int32
      @query_input.cursor
    end

    def query_cursor=(value : Int32) : Int32
      @query_input.cursor = value
    end
  end
end
