require "./semantic_tokens"
require "./lexical_highlighter"
require "./external_file_conflict"

module Adamantine
  class OpenBuffer
    property path : Path
    property editor : Tui::TextEditor
    property version : Int32
    property language_id : String?
    property uri : String
    # Stored after LSP-boundary conversion: line/character/end_character are
    # editor codepoint columns, even though the wire Diagnostic uses UTF-16.
    # Keep this distinction explicit so renderers and Problems consumers do
    # not convert an already-consumed range a second time.  Problems consumes
    # these ranges directly and never interprets them as wire coordinates.
    property diagnostics : Array(Lsp::Diagnostic)
    property diagnostics_partial : Bool
    # Incremented whenever diagnostics are cleared or published.  A Problems
    # snapshot retains this generation so an old modal row cannot authorize a
    # jump after a newer notification or edit.
    property diagnostics_generation : UInt64
    # Per-open-buffer token for an in-flight conversion batch.  It avoids a
    # URI history map and lets edits invalidate a yielding callback cheaply.
    property diagnostics_notification_generation : UInt64
    property semantic_overlay : SemanticOverlay
    property semantic_generation : Int32
    property lexical_highlighter : LexicalHighlighter? = nil
    property lexical_worker_running : Bool = false
    property lexical_view_line : Int32 = -1
    getter lexical_requested_lines = Set(Int32).new
    property fold_generation : Int32
    property disk_revision : FileRevision?
    property watch_token : ExternalFileMonitor::WatchToken?
    property external_conflict : ExternalFileConflict?
    property external_conflict_generation : UInt64

    def initialize(@path : Path, @editor : Tui::TextEditor, @language_id : String?, @uri : String)
      @version = 1
      @diagnostics = [] of Lsp::Diagnostic
      @diagnostics_partial = false
      @diagnostics_generation = 0_u64
      @diagnostics_notification_generation = 0_u64
      @semantic_overlay = SemanticOverlay.empty
      @semantic_generation = 0
      @fold_generation = 0
      @disk_revision = nil
      @watch_token = nil
      @external_conflict = nil
      @external_conflict_generation = 0_u64
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
    property title : String
    property action : String
    property aliases : Array(String)
    property description : String
    property argument_hint : String
    property shortcut_action : String
    property default_action : Bool

    def initialize(
      @title : String,
      @action : String,
      @aliases : Array(String),
      @description : String,
      @argument_hint : String = "",
      @shortcut_action : String = "",
      @default_action : Bool = false,
    )
    end

    def requires_argument? : Bool
      !@argument_hint.empty?
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
    property availability : Proc(String?)?

    def initialize(
      @label : String,
      @shortcut : String,
      @action : Proc(Nil),
      @availability : Proc(String?)? = nil,
    )
    end

    def disabled_reason : String?
      @availability.try(&.call)
    end
  end
end
