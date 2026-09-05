require "./lsp_client"
require "./document_types"

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
  end
end
