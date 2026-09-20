require "crystal_tui"

require "./document_types"
require "./editing_text_editor"
require "./file_revision"
require "./inline_edit_preview"
require "./recovery_review"

module Adamantine
  # Builds one detached recovery review from already-authorized checkpoint
  # bytes.  This class has no recovery-copy or discard authority.
  class RecoveryReviewController
    alias BufferLookup = Proc(Hash(String, OpenBuffer))
    alias Reporter = Proc(String, Nil)

    MAX_DISK_BYTES = 16_i64 * 1024 * 1024

    # Recovery review has no affirmative action.  These strings are supplied
    # to a renderer as width-specific alternatives; every key other than the
    # navigation keys is intentionally consumed without advertising a verb.
    FOOTER_FULL    = "Tab next | Shift-Tab previous | arrows scroll | PgUp/PgDn page | Home/End | Esc close"
    FOOTER_NARROW  = "Tab next | Shift-Tab previous | Esc close"
    FOOTER_COMPACT = "Tab next | Esc close"
    FOOTER_TINY    = "Esc close"

    struct RenderState
      getter title : String
      getter scope : String
      getter model : InlineEditPreview::Model?
      getter message : String?

      def initialize(@title : String, @scope : String, @model : InlineEditPreview::Model?, @message : String?)
      end
    end

    @project : Path
    @buffers : BufferLookup
    @report : Reporter
    @review : RecoveryReview? = nil

    def initialize(project : Path | String, @buffers : BufferLookup, @report : Reporter = ->(_message : String) { })
      @project = Path.new(File.expand_path(project.to_s))
    end

    # Build a detached review without changing the controller's modal state.
    # App integration can use this for a pending overlay, while `open` below
    # is the simple stateful lifecycle used by the modal route.

    def build(preview : RecoveryController::RecoveryPreview) : RecoveryReview
      candidate = preview.candidate
      checkpoint = capture_checkpoint(preview)
      editor = capture_editor(preview.authorized_source_path)
      disk = capture_disk(preview.authorized_source_path)
      RecoveryReview.new(candidate, editor, disk, checkpoint)
    rescue ex
      @report.call("Recovery review unavailable: #{ex.message || ex.class}")
      fallback_review(preview, "review capture failed")
    end

    # Opening always captures afresh.  Once returned, all roots held by the
    # review are detached from the live editor and disk; later source changes
    # cannot silently replace the active comparison.
    def open(preview : RecoveryController::RecoveryPreview) : RecoveryReview
      @review = build(preview)
      @review.not_nil!
    end

    def close : Nil
      @review = nil
      nil
    end

    def active? : Bool
      !@review.nil?
    end

    def review : RecoveryReview?
      @review
    end

    def active_view : RecoveryReview::View?
      @review.try(&.active_view)
    end

    def active_title : String
      active_view.try(&.title) || "Recovery review"
    end

    def active_scope : String
      @review.try(&.scope) || ""
    end

    def render_state : RenderState
      view = active_view
      RenderState.new(
        active_title,
        active_scope,
        view.try(&.model),
        view.try(&.message)
      )
    end

    def footer_controls : NamedTuple(full: String, narrow: String, compact: String, tiny: String)
      {
        full:    FOOTER_FULL,
        narrow:  FOOTER_NARROW,
        compact: FOOTER_COMPACT,
        tiny:    FOOTER_TINY,
      }
    end

    # Every event is consumed while the controller is active.  Enter,
    # printable keys, remapped keys, paste, and mouse events deliberately have
    # no action; only the bounded review navigation below changes state.
    def handle_input(event : Tui::Event, page_rows : Int32 = 1) : Bool
      return true unless active?

      case event
      when Tui::KeyEvent
        if event.matches?("escape") || event.matches?("esc")
          close
          return true
        end

        active = @review.not_nil!
        case
        when event.matches?("tab")
          active.next_view(1)
        when event.matches?("shift+tab")
          active.next_view(-1)
        when event.matches?("up")
          active.active_view.model.try(&.scroll_by(-1))
        when event.matches?("down")
          active.active_view.model.try(&.scroll_by(1))
        when event.matches?("pageup")
          active.active_view.model.try(&.scroll_page(-1, [page_rows, 1].max))
        when event.matches?("pagedown")
          active.active_view.model.try(&.scroll_page(1, [page_rows, 1].max))
        when event.matches?("home")
          active.active_view.model.try(&.home)
        when event.matches?("end")
          active.active_view.model.try(&.finish)
        end
      end
      true
    end

    private def capture_checkpoint(preview : RecoveryController::RecoveryPreview) : RecoveryReview::Snapshot
      content = preview.content
      unless text_content?(content)
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Checkpoint,
          "Checkpoint",
          "unavailable: non-text content"
        )
      end

      root = Tui::PieceTreeBuffer.new(content)
      RecoveryReview::Snapshot.new(
        RecoveryReview::Source::Checkpoint,
        "Checkpoint",
        checkpoint_status(preview.candidate),
        root
      )
    end

    private def capture_editor(source_path : Path?) : RecoveryReview::Snapshot
      unless source_path
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Editor,
          "Editor",
          "unavailable: source path is not authorized"
        )
      end

      authorization = authorize_disk_path(source_path.not_nil!)
      unless authorization.nil?
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Editor,
          "Editor",
          "unavailable: #{authorization}"
        )
      end

      buffer = @buffers.call.values.find do |candidate|
        candidate.path.expand == source_path.not_nil!.expand
      end
      unless buffer
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Editor,
          "Editor",
          "unavailable: source is not open"
        )
      end

      editor = buffer.not_nil!.editor.as?(EditingTextEditor)
      unless editor
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Editor,
          "Editor",
          "unavailable: editor snapshot is not supported"
        )
      end

      # Capture the persistent root before returning.  Keep object/version
      # evidence descriptive only; review never treats it as mutation
      # authority.
      root = editor.not_nil!.external_review_source
      RecoveryReview::Snapshot.new(
        RecoveryReview::Source::Editor,
        "Editor",
        "available (version #{buffer.not_nil!.version})",
        root,
        buffer.not_nil!.object_id,
        buffer.not_nil!.version
      )
    rescue ex
      @report.call("Recovery editor snapshot unavailable: #{ex.message || ex.class}")
      RecoveryReview::Snapshot.new(
        RecoveryReview::Source::Editor,
        "Editor",
        "unavailable: snapshot failed"
      )
    end

    def capture_disk(path : Path?) : RecoveryReview::Snapshot
      unless path
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Disk,
          "Disk",
          "unavailable: source path is not authorized"
        )
      end

      authorization = authorize_disk_path(path.not_nil!)
      unless authorization.nil?
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Disk,
          "Disk",
          "unavailable: #{authorization}"
        )
      end

      observed = FileRevision.probe(path.not_nil!)
      if observed.symlink?
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Disk,
          "Disk",
          "unavailable: symlink target rejected"
        )
      end
      unless observed.stable?
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Disk,
          "Disk",
          "unavailable: #{disk_status_label(observed.status)}"
        )
      end
      result = FileRevision.read(
        path.not_nil!,
        max_bytes: MAX_DISK_BYTES,
        expected_stamp: observed,
      )
      unless result.stable?
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Disk,
          "Disk",
          "unavailable: #{disk_status_label(result.status)}"
        )
      end

      # The bounded reader protects the bytes it captured, but the path is
      # still untrusted metadata.  Re-check the lexical/canonical guard before
      # exposing the snapshot so a concurrent replacement with a symlink or a
      # path outside the project cannot become review state.
      authorization = authorize_disk_path(path.not_nil!)
      unless authorization.nil?
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Disk,
          "Disk",
          "unavailable: #{authorization}"
        )
      end

      content = result.content
      unless content && text_content?(content.not_nil!)
        return RecoveryReview::Snapshot.new(
          RecoveryReview::Source::Disk,
          "Disk",
          "unavailable: non-text content"
        )
      end

      RecoveryReview::Snapshot.new(
        RecoveryReview::Source::Disk,
        "Disk",
        "available (captured)",
        Tui::PieceTreeBuffer.new(content.not_nil!)
      )
    rescue ex
      @report.call("Recovery disk snapshot unavailable: #{ex.message || ex.class}")
      RecoveryReview::Snapshot.new(
        RecoveryReview::Source::Disk,
        "Disk",
        "unavailable: read failed"
      )
    end

    private def fallback_review(
      preview : RecoveryController::RecoveryPreview,
      reason : String,
    ) : RecoveryReview
      checkpoint = if text_content?(preview.content)
                     RecoveryReview::Snapshot.new(
                       RecoveryReview::Source::Checkpoint,
                       "Checkpoint",
                       checkpoint_status(preview.candidate),
                       Tui::PieceTreeBuffer.new(preview.content)
                     )
                   else
                     RecoveryReview::Snapshot.new(
                       RecoveryReview::Source::Checkpoint,
                       "Checkpoint",
                       "unavailable: #{reason}"
                     )
                   end
      unavailable_editor = RecoveryReview::Snapshot.new(
        RecoveryReview::Source::Editor,
        "Editor",
        "unavailable: #{reason}"
      )
      unavailable_disk = RecoveryReview::Snapshot.new(
        RecoveryReview::Source::Disk,
        "Disk",
        "unavailable: #{reason}"
      )
      RecoveryReview.new(preview.candidate, unavailable_editor, unavailable_disk, checkpoint)
    end

    private def checkpoint_status(candidate : RecoveryController::RecoveryCandidate) : String
      if version = candidate.version
        "available (version #{version})"
      else
        "available"
      end
    end

    private def text_content?(content : String) : Bool
      content.valid_encoding? && !content.to_slice.includes?(0_u8)
    end

    private def disk_status_label(status : FileRevision::Status) : String
      case status
      when FileRevision::Status::Missing    then "missing"
      when FileRevision::Status::Unreadable then "unreadable"
      when FileRevision::Status::NonRegular then "non-regular file"
      when FileRevision::Status::TooLarge   then "too large"
      when FileRevision::Status::Unstable   then "changed during capture"
      else                                       "unavailable"
      end
    end

    # The backend path is only lexical metadata.  Before opening it, require
    # the existing target (or deepest existing parent for a missing file) to
    # remain below the canonical project root and reject symlink/non-regular
    # targets.  Returning only a reason keeps untrusted paths out of the UI.
    private def authorize_disk_path(path : Path) : String?
      root = canonical_project_root
      return "outside authorized project" unless root
      root = root.not_nil!
      candidate = Path.new(File.expand_path(path.to_s))
      unless within_root?(candidate.to_s, root.to_s)
        return "outside authorized project"
      end

      relative = candidate.to_s[root.to_s.size..]?
      return "outside authorized project" unless relative
      current = root
      segments = relative.not_nil!.split('/').reject(&.empty?)
      segments.each_with_index do |segment, index|
        current /= segment
        info = File.info?(current.to_s, follow_symlinks: false)
        next unless info

        return "symlink target rejected" if info.not_nil!.type == File::Type::Symlink
        if index < segments.size - 1
          return "non-regular parent" unless info.not_nil!.type.directory?
        else
          return "non-regular file" unless info.not_nil!.type.file?
        end
      end

      if File.info?(candidate.to_s, follow_symlinks: false)
        real = Path.new(File.realpath(candidate.to_s))
        return "outside authorized project" unless within_root?(real.to_s, root.to_s)
      end
      nil
    rescue
      "outside authorized project"
    end

    private def canonical_project_root : Path?
      Path.new(File.realpath(@project.to_s))
    rescue
      nil
    end

    private def within_root?(candidate : String, root : String) : Bool
      candidate == root || candidate.starts_with?(root + "/")
    end
  end
end
