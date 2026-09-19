require "./lsp_client"
require "./document_types"
require "./text_coordinates"

module Adamantine
  enum InteractiveLspAction
    Hover
    Completion
    Signature
    References
    Definition
    Declaration
    TypeDefinition
    Implementation
    Hyperclick
    CodeAction
  end

  class InteractiveLspRequest
    getter action : InteractiveLspAction
    getter client : Lsp::Client
    getter buffer : OpenBuffer
    # Capture the concrete editor instance at request time. OpenBuffer#editor
    # is mutable when a tab is rebuilt; using it for a later completion
    # acceptance would otherwise authorize an edit in a replacement widget.
    getter editor : Tui::TextEditor
    getter project_root : Path
    getter uri : String
    getter line : Int32
    getter character : Int32
    getter version : Int32
    getter generation : UInt64
    getter selection_present : Bool

    def initialize(
      @action : InteractiveLspAction,
      @client : Lsp::Client,
      @buffer : OpenBuffer,
      @project_root : Path,
      @uri : String,
      @line : Int32,
      @character : Int32,
      @version : Int32,
      @generation : UInt64,
      editor : Tui::TextEditor? = nil,
      capture_selection : Bool = false,
    )
      @editor = editor || @buffer.editor
      @selection_present = if capture_selection
                             if provider = @editor.as?(TextCoordinates::SelectionProvider)
                               provider.selection_present?
                             else
                               # A compatibility editor has no bounded
                               # selection query. Fail closed instead of
                               # materializing a potentially whole-document
                               # selection just to take this snapshot.
                               true
                             end
                           else
                             false
                           end
    end

    # Request snapshots retain public codepoint coordinates for stale guards
    # and history.  Convert only when a request crosses into LSP transport.
    def utf16_character : Int32
      TextCoordinates.codepoint_to_utf16(@editor, @line, @character)
    end
  end
end
