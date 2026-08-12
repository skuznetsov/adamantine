require "./semantic_tokens"

module CrystalEditor
  class OpenBuffer
    property path : Path
    property editor : Tui::TextEditor
    property version : Int32
    property language_id : String?
    property uri : String
    property diagnostics : Array(Lsp::Diagnostic)
    property semantic_overlay : SemanticOverlay
    property semantic_generation : Int32
    property fold_generation : Int32

    def initialize(@path : Path, @editor : Tui::TextEditor, @language_id : String?, @uri : String)
      @version = 1
      @diagnostics = [] of Lsp::Diagnostic
      @semantic_overlay = SemanticOverlay.empty
      @semantic_generation = 0
      @fold_generation = 0
    end

    def crystal_family? : Bool
      case @language_id
      when "crystal", "ruby", "adamas"
        true
      else
        false
      end
    end
  end

  struct NavigationLocation
    property uri : String
    property line : Int32
    property character : Int32

    def initialize(@uri : String, @line : Int32, @character : Int32)
    end
  end

  struct CommandEntry
    property aliases : Array(String)
    property description : String

    def initialize(@aliases : Array(String), @description : String)
    end
  end

  struct CommandMark
    property uri : String
    property line : Int32
    property character : Int32

    def initialize(@uri : String, @line : Int32, @character : Int32)
    end
  end

  struct LspContextAction
    property label : String
    property shortcut : String
    property action : Proc(Nil)

    def initialize(@label : String, @shortcut : String, @action : Proc(Nil))
    end
  end
end
