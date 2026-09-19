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
    getter project_root : Path
    getter uri : String
    getter line : Int32
    getter character : Int32
    getter version : Int32
    getter generation : UInt64

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
    )
    end

    # Request snapshots retain public codepoint coordinates for stale guards
    # and history.  Convert only when a request crosses into LSP transport.
    def utf16_character : Int32
      TextCoordinates.codepoint_to_utf16(@buffer.editor, @line, @character)
    end
  end
end
