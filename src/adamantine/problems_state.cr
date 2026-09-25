require "crystal_tui"
require "./file_revision"

module Adamantine
  # State shared by the open-files and server-workspace Problems snapshots.
  # Open-buffer rows use editor-codepoint ranges; unopened workspace rows keep
  # LSP UTF-16 coordinates until a concrete editor is ready to be committed.
  class ProblemsState
    include ModalState

    enum Coverage
      OpenFiles
      ServerWorkspace
    end

    enum Target
      OpenBuffer
      WorkspaceFile
    end

    struct Row
      getter diagnostic : Lsp::Diagnostic
      getter source_index : Int32
      getter buffer_path : String
      getter display_path : String
      getter buffer_id : UInt64?
      getter editor_id : UInt64?
      getter version : Int32?
      getter diagnostics_generation : UInt64?
      getter target : Target
      getter uri : String?
      getter stamp : FileRevision::Stamp?
      getter request_generation : UInt64
      getter root_identity : String?

      def initialize(
        @diagnostic : Lsp::Diagnostic,
        @source_index : Int32,
        @buffer_path : String,
        @display_path : String,
        @buffer_id : UInt64?,
        @editor_id : UInt64?,
        @version : Int32?,
        @diagnostics_generation : UInt64?,
        @target : Target = Target::OpenBuffer,
        @uri : String? = nil,
        @stamp : FileRevision::Stamp? = nil,
        @request_generation : UInt64 = 0_u64,
        @root_identity : String? = nil,
      )
      end

      def self.workspace_file(
        diagnostic : Lsp::Diagnostic,
        source_index : Int32,
        path : Path,
        display_path : String,
        uri : String,
        version : Int32?,
        stamp : FileRevision::Stamp,
        request_generation : UInt64,
        root_identity : String,
      ) : Row
        new(
          diagnostic,
          source_index,
          path.to_s,
          display_path,
          nil,
          nil,
          version,
          nil,
          Target::WorkspaceFile,
          uri,
          stamp,
          request_generation,
          root_identity,
        )
      end

      def open_buffer? : Bool
        @target.open_buffer?
      end

      def workspace_file? : Bool
        @target.workspace_file?
      end
    end

    property open : Bool
    property overlay : Tui::OverlayRenderer?
    property rows : Array(Row)
    property selected : Int32
    property top : Int32
    property partial : Bool
    property client_id : UInt64?
    property coverage : Coverage
    property loading : Bool
    property request_generation : UInt64
    property root_identity : String?

    def initialize
      @open = false
      @overlay = nil
      @rows = [] of Row
      @selected = 0
      @top = 0
      @partial = false
      @client_id = nil
      @coverage = Coverage::OpenFiles
      @loading = false
      @request_generation = 0_u64
      @root_identity = nil
    end

    def reset_snapshot : Nil
      @rows = [] of Row
      @selected = 0
      @top = 0
      @partial = false
      @client_id = nil
      @coverage = Coverage::OpenFiles
      @loading = false
      @request_generation = 0_u64
      @root_identity = nil
    end
  end
end
