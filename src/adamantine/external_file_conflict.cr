require "./external_file_monitor"

module Adamantine
  enum ExternalConflictAction
    Reload
    Keep
    Overwrite
  end

  # The latest unresolved external observation for one open buffer.
  #
  # `generation` belongs to the candidate rather than to the file watch. It
  # invalidates dialog actions as soon as a newer external observation arrives.
  struct ExternalFileConflict
    getter event : ExternalFileMonitor::Event
    getter generation : UInt64

    def initialize(@event : ExternalFileMonitor::Event, @generation : UInt64)
    end

    def watch_token : ExternalFileMonitor::WatchToken
      @event.token
    end

    def path : Path
      @event.path
    end
  end
end
