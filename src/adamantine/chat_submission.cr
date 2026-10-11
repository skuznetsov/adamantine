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
    end

    # Owner-side, per-turn disclosure. It deliberately contains no editor or
    # file handle: transports receive only this immutable bounded snapshot.
    class SubmissionContext
      getter mode : ContextMode

      @label : String
      @text : String
      @buffer_id : String?
      @revision : String?

      def initialize(@mode : ContextMode = ContextMode::None,
                     label : String = "None",
                     text : String = "",
                     buffer_id : String? = nil,
                     revision : String? = nil)
        @label = bounded_label(label)
        @text = bounded_text(text)
        @buffer_id = bounded_identifier(buffer_id, "buffer ID")
        @revision = bounded_identifier(revision, "buffer revision")
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

      def bytesize : Int32
        @text.bytesize
      end

      def ==(other : SubmissionContext) : Bool
        @mode == other.@mode && @label == other.@label && @text == other.@text &&
          @buffer_id == other.@buffer_id && @revision == other.@revision
      end

      private def validate_shape! : Nil
        case @mode
        when ContextMode::None
          unless @label == "None" && @text.empty? && @buffer_id.nil? && @revision.nil?
            raise ArgumentError.new("None context cannot include editor data")
          end
        when ContextMode::Selection
          unless !@text.empty? && @buffer_id && @revision
            raise ArgumentError.new("selection context requires non-empty text, buffer ID and revision")
          end
        when ContextMode::ActiveBuffer
          unless @buffer_id && @revision
            raise ArgumentError.new("active-buffer context requires buffer ID and revision")
          end
        when ContextMode::BufferTools
          unless @text.empty? && @buffer_id && @revision
            raise ArgumentError.new("buffer tools context requires only buffer ID and revision")
          end
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
