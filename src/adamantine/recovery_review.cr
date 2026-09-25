require "crystal_tui"

require "./inline_edit_preview"
require "./recovery_controller"

module Adamantine
  # Immutable, read-only state for one recovery review.  The controller builds
  # this object once when the menu action is selected; later editor and disk
  # changes cannot replace any source root held by the review.
  class RecoveryReview
    enum Source
      Editor
      Disk
      Checkpoint
    end

    class Snapshot
      getter source : Source
      getter label : String
      getter status : String
      getter root : Tui::PieceTreeBuffer?
      getter buffer_id : UInt64?
      getter version : Int32?

      def initialize(
        @source : Source,
        @label : String,
        @status : String,
        @root : Tui::PieceTreeBuffer? = nil,
        @buffer_id : UInt64? = nil,
        @version : Int32? = nil,
      )
      end

      def available? : Bool
        !@root.nil?
      end

      def scope_label : String
        suffix = @status.empty? ? "" : ": #{@status}"
        "#{source_label}#{suffix}"
      end

      def source_label : String
        case @source
        when Source::Editor     then "Editor"
        when Source::Disk       then "Disk"
        when Source::Checkpoint then "Checkpoint"
        else
          raise ArgumentError.new("unknown recovery review source")
        end
      end
    end

    class View
      getter left : Source?
      getter right : Source?
      getter title : String
      getter model : InlineEditPreview::Model?
      getter message : String?

      def initialize(
        @left : Source?,
        @right : Source?,
        @title : String,
        @model : InlineEditPreview::Model? = nil,
        @message : String? = nil,
      )
      end

      def standalone? : Bool
        @left.nil? && @right == Source::Checkpoint
      end

      def available? : Bool
        !@model.nil?
      end
    end

    getter candidate : RecoveryController::RecoveryCandidate
    getter editor : Snapshot
    getter disk : Snapshot
    getter checkpoint : Snapshot
    getter views : Array(View)
    getter index : Int32

    def initialize(
      @candidate : RecoveryController::RecoveryCandidate,
      @editor : Snapshot,
      @disk : Snapshot,
      @checkpoint : Snapshot,
    )
      @views = [] of View
      append_pair(Source::Editor, Source::Checkpoint)
      append_pair(Source::Disk, Source::Checkpoint)
      append_pair(Source::Editor, Source::Disk)
      append_checkpoint_view
      @index = 0
    end

    def active_view : View
      @views[@index.clamp(0, [@views.size - 1, 0].max)]
    end

    def next_view(delta : Int32 = 1) : Int32
      return @index if @views.size < 2
      @index = (@index + delta) % @views.size
      @index += @views.size if @index < 0
      @index
    end

    def scope : String
      [@editor.scope_label, @disk.scope_label, @checkpoint.scope_label].join(" · ")
    end

    private def append_pair(left : Source, right : Source) : Nil
      left_snapshot = snapshot(left)
      right_snapshot = snapshot(right)
      return unless left_snapshot.available? && right_snapshot.available?

      left_root = left_snapshot.root.not_nil!
      right_root = right_snapshot.root.not_nil!
      span = InlineEditPreview::EditSpan.new(
        0,
        left_root.line_count,
        0,
        right_root.line_count,
      )
      title = "#{left_snapshot.source_label} -> #{right_snapshot.source_label}"
      model = InlineEditPreview::Model.new(left_root, right_root, [span], title)
      @views << View.new(left, right, title, model)
    end

    private def append_checkpoint_view : Nil
      if root = @checkpoint.root
        # This is a document projection, not a comparison.  An empty edit list
        # maps the persistent root directly to context rows and avoids an O(n)
        # self-diff when the original file is gone or unavailable.
        model = InlineEditPreview::Model.new(
          root,
          root,
          [] of InlineEditPreview::EditSpan,
          "Checkpoint contents"
        )
        @views << View.new(nil, Source::Checkpoint, "Checkpoint contents", model)
      else
        @views << View.new(
          nil,
          Source::Checkpoint,
          "Checkpoint contents",
          nil,
          "Checkpoint contents unavailable: #{@checkpoint.status}"
        )
      end
    end

    private def snapshot(source : Source) : Snapshot
      case source
      when Source::Editor     then @editor
      when Source::Disk       then @disk
      when Source::Checkpoint then @checkpoint
      else
        raise ArgumentError.new("unknown recovery review source")
      end
    end
  end
end
