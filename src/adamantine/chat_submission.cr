require "./editor_tools"

module Adamantine
  module Chat
    MAX_CONTEXT_BYTES    = 16 * 1024
    MAX_HISTORY_BYTES    = 64 * 1024
    MAX_HISTORY_MESSAGES = 16
    MAX_TOOL_ATTEMPTS    = 16

    enum ContextMode
      None
      Selection
      ActiveBuffer
      BufferTools
      BufferProposals
      SelectionProposals

      def tool_context? : Bool
        self.buffer_tools? || self.buffer_proposals? || self.selection_proposals?
      end

      def proposal_context? : Bool
        self.buffer_proposals? || self.selection_proposals?
      end
    end

    # Frozen source coordinates for an explicitly disclosed editor selection.
    # Lines are one-based and columns are zero-based Unicode codepoints; the
    # range is non-empty and half-open.
    struct SourceRange
      getter start_line : Int32
      getter start_column : Int32
      getter end_line : Int32
      getter end_column : Int32

      def initialize(@start_line : Int32, @start_column : Int32,
                     @end_line : Int32, @end_column : Int32)
        unless @start_line >= 1 && @end_line >= 1 && @start_column >= 0 && @end_column >= 0
          raise ArgumentError.new("source range coordinates are invalid")
        end
        unless position_before?(@start_line, @start_column, @end_line, @end_column)
          raise ArgumentError.new("source range must be non-empty and ordered")
        end
      end

      # The editor's selection API numbers lines from zero. Columns already
      # use Unicode codepoints and must not be converted to bytes or UTF-16.
      def to_editor_coordinates : Tuple(Int32, Int32, Int32, Int32)
        {@start_line - 1, @start_column, @end_line - 1, @end_column}
      end

      # Edit coordinates use one-based lines and zero-based codepoint columns.
      # Empty insertions are permitted at both selection endpoints.
      def contains_edit?(start_line : Int32, start_column : Int32,
                         end_line : Int32, end_column : Int32) : Bool
        return false unless start_line >= 1 && end_line >= 1 && start_column >= 0 && end_column >= 0
        return false if position_before?(end_line, end_column, start_line, start_column)

        after_start = !position_before?(start_line, start_column, @start_line, @start_column)
        before_end = !position_before?(@end_line, @end_column, end_line, end_column)
        after_start && before_end
      end

      def ==(other : SourceRange) : Bool
        @start_line == other.@start_line && @start_column == other.@start_column &&
          @end_line == other.@end_line && @end_column == other.@end_column
      end

      private def position_before?(left_line : Int32, left_column : Int32,
                                   right_line : Int32, right_column : Int32) : Bool
        left_line < right_line || (left_line == right_line && left_column < right_column)
      end
    end

    # Provider-visible authorization receipt only. It excludes script source
    # and paths; the host keeps the reviewed catalog entry behind this value.
    class LuaScriptGrant
      @id : String
      @name : String
      @digest : String
      @effective_capabilities : Array(EditorTools::Capability)

      def initialize(id : String, name : String, digest : String,
                     effective_capabilities : Array(EditorTools::Capability))
        @id = bounded_metadata(id, "script ID", 64)
        @name = bounded_metadata(name, "script name", 128)
        unless digest.matches?(/\A[0-9a-fA-F]{64}\z/)
          raise ArgumentError.new("script digest must be a SHA-256 hex digest")
        end
        @digest = digest.downcase.dup
        allowed = [EditorTools::Capability::ReadEditor, EditorTools::Capability::ProposeEdits]
        if effective_capabilities.any? { |capability| !allowed.includes?(capability) }
          raise ArgumentError.new("Chat script grant contains an unsupported capability")
        end
        unless effective_capabilities.uniq == effective_capabilities
          raise ArgumentError.new("Chat script grant repeats a capability")
        end
        @effective_capabilities = effective_capabilities.dup
      end

      def id : String
        @id.dup
      end

      def name : String
        @name.dup
      end

      def digest : String
        @digest.dup
      end

      def effective_capabilities : Array(EditorTools::Capability)
        @effective_capabilities.dup
      end

      def ==(other : LuaScriptGrant) : Bool
        @id == other.@id && @name == other.@name && @digest == other.@digest &&
          @effective_capabilities == other.@effective_capabilities
      end

      def clone : LuaScriptGrant
        LuaScriptGrant.new(@id, @name, @digest, @effective_capabilities)
      end

      private def bounded_metadata(value : String, label : String, max_bytes : Int32) : String
        unless value.valid_encoding? && !value.empty? && value.bytesize <= max_bytes
          raise ArgumentError.new("#{label} is invalid or too long")
        end
        if value.each_char.any? { |char| EditorTools.control_char?(char) }
          raise ArgumentError.new("#{label} contains a control character")
        end
        value.dup
      end
    end

    # Owner-side, per-turn disclosure. It deliberately contains no editor or
    # file handle: transports receive only this immutable bounded snapshot.
    class SubmissionContext
      getter mode : ContextMode

      @label : String
      @text : String
      @buffer_id : String?
      @revision : String?
      @lua_script_grant : LuaScriptGrant?
      @source_path : String?
      @source_range : SourceRange?

      def initialize(@mode : ContextMode = ContextMode::None,
                     label : String = "None",
                     text : String = "",
                     buffer_id : String? = nil,
                     revision : String? = nil,
                     lua_script_grant : LuaScriptGrant? = nil,
                     source_path : String? = nil,
                     @source_range : SourceRange? = nil)
        @label = bounded_label(label)
        @text = bounded_text(text)
        @buffer_id = bounded_identifier(buffer_id, "buffer ID")
        @revision = bounded_identifier(revision, "buffer revision")
        @lua_script_grant = lua_script_grant.try(&.clone)
        @source_path = bounded_source_path(source_path)
        validate_shape!
      end

      def self.none : SubmissionContext
        new
      end

      def label : String
        @label.dup
      end

      def text : String
        @text.dup
      end

      def buffer_id : String?
        @buffer_id.try(&.dup)
      end

      def revision : String?
        @revision.try(&.dup)
      end

      def lua_script_grant : LuaScriptGrant?
        @lua_script_grant.try(&.clone)
      end

      def source_path : String?
        @source_path.try(&.dup)
      end

      def source_range : SourceRange?
        @source_range
      end

      def bytesize : Int32
        @text.bytesize
      end

      def ==(other : SubmissionContext) : Bool
        @mode == other.@mode && @label == other.@label && @text == other.@text &&
          @buffer_id == other.@buffer_id && @revision == other.@revision &&
          @lua_script_grant == other.@lua_script_grant &&
          @source_path == other.@source_path && @source_range == other.@source_range
      end

      private def validate_shape! : Nil
        case @mode
        when ContextMode::None
          unless @label == "None" && @text.empty? && @buffer_id.nil? && @revision.nil? &&
                 @lua_script_grant.nil? && @source_path.nil? && @source_range.nil?
            raise ArgumentError.new("None context cannot include editor data")
          end
        when ContextMode::Selection
          unless !@text.empty? && @buffer_id && @revision && @lua_script_grant.nil? && @source_path && @source_range
            raise ArgumentError.new("selection context requires non-empty text, buffer ID, revision, path and range")
          end
        when ContextMode::ActiveBuffer
          unless @buffer_id && @revision && @lua_script_grant.nil? && @source_path
            raise ArgumentError.new("active-buffer context requires buffer ID, revision and path")
          end
        when ContextMode::BufferTools, ContextMode::BufferProposals
          unless @text.empty? && @buffer_id && @revision && @source_path
            raise ArgumentError.new("buffer tool context requires buffer ID, revision and path")
          end
          if @mode.buffer_tools? && @lua_script_grant.try(&.effective_capabilities.includes?(EditorTools::Capability::ProposeEdits))
            raise ArgumentError.new("read-only buffer context cannot grant script proposals")
          end
        when ContextMode::SelectionProposals
          unless !@text.empty? && @buffer_id && @revision && @source_path && @source_range
            raise ArgumentError.new("selection proposal context requires non-empty text, buffer ID, revision, path and range")
          end
        else
          raise ArgumentError.new("unsupported chat context mode")
        end

        if @mode != ContextMode::None && @source_path.nil?
          raise ArgumentError.new("explicit file context requires a canonical project-relative path")
        end
      end

      private def bounded_text(value : String) : String
        unless value.valid_encoding?
          raise ArgumentError.new("context must be valid UTF-8")
        end
        if value.bytesize > MAX_CONTEXT_BYTES
          raise ArgumentError.new("context exceeds 16 KiB")
        end
        value.dup
      end

      private def bounded_label(value : String) : String
        unless value.valid_encoding? && value.bytesize <= 256
          raise ArgumentError.new("context label must be valid UTF-8 and at most 256 bytes")
        end
        if value.each_char.any? { |char| char.control? }
          raise ArgumentError.new("context label cannot contain control characters")
        end
        value.dup
      end

      private def bounded_identifier(value : String?, label : String) : String?
        return unless value
        unless value.not_nil!.valid_encoding? && !value.not_nil!.empty? && value.not_nil!.bytesize <= 128
          raise ArgumentError.new("#{label} must be valid UTF-8 and at most 128 bytes")
        end
        if value.not_nil!.each_char.any? { |char| char.control? }
          raise ArgumentError.new("#{label} cannot contain control characters")
        end
        value.not_nil!.dup
      end

      private def bounded_source_path(value : String?) : String?
        return unless value
        path = value.not_nil!
        unless path.valid_encoding? && !path.empty? && path.bytesize <= 4096
          raise ArgumentError.new("source path must be valid UTF-8 and at most 4096 bytes")
        end
        if path.each_char.any? { |char| EditorTools.control_char?(char) }
          raise ArgumentError.new("source path cannot contain control characters")
        end
        if path.starts_with?("/") || path.includes?('\\') || path.matches?(/\A[A-Za-z]:/)
          raise ArgumentError.new("source path must be project-relative and use canonical separators")
        end
        segments = path.split('/')
        if segments.empty? || segments.any? { |segment| segment.empty? || segment == "." || segment == ".." }
          raise ArgumentError.new("source path must use canonical project-relative segments")
        end
        path.dup
      end
    end

    # A review is one exact proposed export. App confirms its captured source
    # revisions again before approval; this value cannot authorize later input.
    class SubmissionReview
      getter request : Request
      getter provider_revision : UInt64
      getter root_identity : String
      getter composer_revision : UInt64

      def initialize(@request : Request,
                     @provider_revision : UInt64,
                     root_identity : String,
                     @composer_revision : UInt64)
        @root_identity = root_identity.dup
      end

      def root_identity : String
        @root_identity.dup
      end

      def matches?(request : Request,
                   provider_revision : UInt64,
                   root_identity : String,
                   composer_revision : UInt64) : Bool
        @request.turn_id == request.turn_id && @request.text == request.text &&
          @request.context == request.context &&
          @request.history.map { |message| {message.role, message.text} } ==
            request.history.map { |message| {message.role, message.text} } &&
          @provider_revision == provider_revision && @root_identity == root_identity &&
          @composer_revision == composer_revision
      end
    end
  end
end
