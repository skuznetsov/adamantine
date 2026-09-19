require "crystal_tui"

require "./document_types"
require "./inline_edit_preview"

module Adamantine
  # An immutable authority capture for one explicit external-change action.
  #
  # The buffer/editor references identify the live object, while version,
  # watch token and conflict generation identify the exact state for which the
  # disk observation was made.  The preview owns persistent forks of OURS and
  # THEIRS; callers may move its viewport, but neither fork aliases a future
  # editor mutation.
  class ExternalChangeReview
    getter buffer : OpenBuffer
    getter editor : Tui::TextEditor
    getter version : Int32
    getter watch_token : ExternalFileMonitor::WatchToken
    getter conflict_generation : UInt64
    getter event : ExternalFileMonitor::Event
    getter disk : FileRevision::Result
    getter event_label : String
    getter status_label : String
    getter preview_status : String
    getter preview : InlineEditPreview::Model?

    def initialize(
      @buffer : OpenBuffer,
      @editor : Tui::TextEditor,
      @version : Int32,
      @watch_token : ExternalFileMonitor::WatchToken,
      @conflict_generation : UInt64,
      @event : ExternalFileMonitor::Event,
      @disk : FileRevision::Result,
      @event_label : String,
      @status_label : String,
      @preview_status : String,
      @preview : InlineEditPreview::Model?,
    )
    end

    # Compatibility-friendly name for callers that describe the observation
    # as the current candidate rather than the disk side of the review.
    def current : FileRevision::Result
      @disk
    end

    def disk_fingerprint : String?
      @disk.digest
    end

    def disk_stamp : FileRevision::Stamp
      @disk.stamp
    end

    def path : Path
      @buffer.path
    end

    def preview_available? : Bool
      !@preview.nil?
    end

    def stable_disk? : Bool
      @disk.stable?
    end
  end
end
