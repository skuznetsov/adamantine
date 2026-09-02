require "crystal_tui"
require "../adamantine/modal_state"
require "../adamantine/project_search"

module Adamantine
  class SearchState
    include ModalState

    enum Scope
      ThisFile
      Project
    end

    enum Focus
      Query
      Results
    end

    property open : Bool = false
    property overlay : Tui::OverlayRenderer? = nil
    property query : String = ""
    property query_cursor : Int32 = 0
    property scope : Scope = Scope::ThisFile
    property focus : Focus = Focus::Query
    property ignore_case : Bool = false
    property matches : Array(ProjectSearch::Match) = [] of ProjectSearch::Match
    property selected_index : Int32 = 0
    property scroll : Int32 = 0
    property truncated : Bool = false
    property forward : Bool = true
  end
end
