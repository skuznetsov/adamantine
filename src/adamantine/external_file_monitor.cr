require "./file_revision"

module Adamantine
  # A single cooperative poller for all open files. The monitor owns no UI or
  # editor state: callers receive typed events and decide how to resolve them.
  class ExternalFileMonitor
    DEFAULT_CHUNK_SIZE = FileRevision::DEFAULT_CHUNK_SIZE

    struct WatchToken
      getter path : Path
      getter generation : UInt64

      def initialize(@path : Path, @generation : UInt64)
      end

      def ==(other : WatchToken) : Bool
        @path == other.path && @generation == other.generation
      end

      def to_s(io : IO) : Nil
        io << @path << "@" << @generation
      end
    end

    struct Event
      enum Kind
        Changed
        Deleted
        Unreadable
        NonRegular
        Replaced
        SymlinkRetargeted
        TooLarge
      end

      getter kind : Kind
      getter token : WatchToken
      getter previous : FileRevision::Result
      getter current : FileRevision::Result

      def initialize(@kind : Kind, @token : WatchToken, @previous : FileRevision::Result, @current : FileRevision::Result)
      end

      def type : Kind
        @kind
      end

      def path : Path
        @token.path
      end

      def generation : UInt64
        @token.generation
      end

      def revision : FileRevision?
        @current.revision
      end

      def previous_revision : FileRevision?
        @previous.revision
      end

      def digest : String?
        @current.digest
      end

      def stamp : FileRevision::Stamp
        @current.stamp
      end

      def status : FileRevision::Status
        @current.status
      end

      def changed? : Bool
        @kind == Kind::Changed
      end

      def deleted? : Bool
        @kind == Kind::Deleted
      end

      def unreadable? : Bool
        @kind == Kind::Unreadable
      end

      def non_regular? : Bool
        @kind == Kind::NonRegular
      end

      def replaced? : Bool
        @kind == Kind::Replaced
      end

      def symlink_retargeted? : Bool
        @kind == Kind::SymlinkRetargeted
      end

      def too_large? : Bool
        @kind == Kind::TooLarge
      end
    end

    # Classifies two independently obtained observations without mutating a
    # watch. This is also used by save paths which must compare their exact
    # pre-save baseline with a mandatory capture at save time.
    def self.event_kind(previous : FileRevision::Result, current : FileRevision::Result) : Event::Kind?
      # A reader which could not establish a stable byte sequence is not an
      # external revision candidate yet. Callers can retry with a later
      # capture; publishing a partial read would make a false conflict.
      return nil if current.unstable?

      # Retargeting a still-present symlink is a more specific fact than the
      # resulting status (including a broken target), so preserve that signal.
      if previous.stable? && previous.revision
        old_stamp = previous.revision.not_nil!.stamp
        if old_stamp.symlink? && old_stamp.symlink_target_changed?(current.stamp)
          return Event::Kind::SymlinkRetargeted
        end
      end

      case current.status
      when FileRevision::Status::Missing
        Event::Kind::Deleted
      when FileRevision::Status::Unreadable
        Event::Kind::Unreadable
      when FileRevision::Status::NonRegular
        Event::Kind::NonRegular
      when FileRevision::Status::TooLarge
        Event::Kind::TooLarge
      when FileRevision::Status::Unstable
        nil
      when FileRevision::Status::Stable
        return Event::Kind::Changed unless previous.stable?
        old_revision = previous.revision
        new_revision = current.revision
        return Event::Kind::Changed unless old_revision && new_revision

        old_stamp = old_revision.not_nil!.stamp
        new_stamp = new_revision.not_nil!.stamp
        if old_stamp.symlink_target_changed?(new_stamp)
          Event::Kind::SymlinkRetargeted
        elsif old_stamp.identity_changed?(new_stamp)
          Event::Kind::Replaced
        elsif old_revision.not_nil!.digest != new_revision.not_nil!.digest
          Event::Kind::Changed
        end
      end
    end

    # Builds the same immutable event value used by the monitor callback,
    # without changing a watch baseline. A nil result means the two results do
    # not constitute an external conflict (for example, identical content).
    def self.event_for(token : WatchToken, previous : FileRevision::Result, current : FileRevision::Result) : Event?
      kind = event_kind(previous, current)
      kind ? Event.new(kind.not_nil!, token, previous, current) : nil
    end

    NOOP_CALLBACK = ->(_event : Event) { }

    private class WatchState
      getter token : WatchToken
      property baseline : FileRevision::Result?
      property epoch : UInt64

      def initialize(@token : WatchToken, @baseline : FileRevision::Result? = nil)
        @epoch = 0_u64
      end
    end

    getter chunk_size : Int32
    getter max_bytes : Int64?
    getter hash_passes : UInt64

    @on_event : Proc(Event, Nil)
    @watches : Hash(String, WatchState)
    @next_generation : UInt64
    @run_generation : UInt64
    @running : Bool
    @worker : Fiber?

    def initialize(
      @on_event : Proc(Event, Nil) = NOOP_CALLBACK,
      @chunk_size : Int32 = DEFAULT_CHUNK_SIZE,
      @max_bytes : Int64? = nil,
    )
      raise ArgumentError.new("chunk_size must be positive") unless @chunk_size > 0
      if limit = @max_bytes
        raise ArgumentError.new("max_bytes must not be negative") if limit < 0
      end

      @watches = {} of String => WatchState
      @next_generation = 0_u64
      @run_generation = 0_u64
      @hash_passes = 0_u64
      @running = false
      @worker = nil
    end

    def watch(path : Path | String, baseline : FileRevision? = nil) : WatchToken
      normalized = path.is_a?(Path) ? path : Path.new(path)
      token = WatchToken.new(normalized, next_generation)
      state = WatchState.new(token)
      key = normalized.to_s
      # Replacing the entry invalidates every in-flight operation for the old
      # open instance before the new baseline is read.
      @watches[key] = state

      result = if baseline && usable_baseline?(normalized, baseline.not_nil!)
                 baseline_result(normalized, baseline.not_nil!)
               else
                 capture(normalized)
               end

      if current_state?(state)
        state.baseline = result
      end
      token
    end

    def unwatch(token : WatchToken) : Bool
      key = token.path.to_s
      state = @watches[key]?
      return false unless state && state.not_nil!.token == token
      @watches.delete(key)
      true
    end

    def watched?(token : WatchToken) : Bool
      state = @watches[token.path.to_s]?
      !!state && state.not_nil!.token == token
    end

    def watch_count : Int32
      @watches.size
    end

    # Polls every current watch. Metadata-only probes are used when possible;
    # each changed stamp gets one bounded digest pass.
    def poll : Int32
      events = 0
      @watches.values.dup.each do |state|
        next unless current_state?(state)
        events += 1 if inspect(state, force: false)
      end
      events
    end

    # Hashes one current watch regardless of its stamp. A nil result means the
    # token was stale (for example, after close/reopen) and was discarded.
    def force_recheck(token : WatchToken) : FileRevision::Result?
      state = @watches[token.path.to_s]?
      return nil unless state && state.not_nil!.token == token
      epoch = state.not_nil!.epoch
      @hash_passes += 1_u64
      result = capture(token.path)
      return nil unless current_state?(state.not_nil!, epoch)
      publish(state.not_nil!, result, epoch)
      result
    end

    # Accept an exact revision already obtained by a successful save or reload.
    # This path performs no second read and invalidates an in-flight stale hash.
    def acknowledge(token : WatchToken, revision : FileRevision) : Bool
      state = @watches[token.path.to_s]?
      return false unless state && state.not_nil!.token == token
      return false unless usable_baseline?(token.path, revision)

      state = state.not_nil!
      state.epoch &+= 1_u64
      state.baseline = baseline_result(token.path, revision)
      true
    end

    def acknowledge(token : WatchToken, result : FileRevision::Result) : Bool
      revision = result.revision
      return false unless revision
      acknowledge(token, revision.not_nil!)
    end

    def start(interval : Time::Span = 250.milliseconds) : Bool
      return false if @running
      raise ArgumentError.new("poll interval must be positive") unless interval > Time::Span.zero
      @running = true
      @run_generation &+= 1_u64
      run_generation = @run_generation
      @worker = spawn do
        run_loop(interval, run_generation)
      end
      true
    end

    def run(interval : Time::Span = 250.milliseconds) : Nil
      raise ArgumentError.new("poll interval must be positive") unless interval > Time::Span.zero
      raise "external file monitor is already running" if @running
      @running = true
      @run_generation &+= 1_u64
      run_loop(interval, @run_generation)
    end

    def stop : Bool
      was_running = @running
      @running = false
      @run_generation &+= 1_u64
      @watches.each_value { |state| state.epoch &+= 1_u64 }
      @worker = nil
      was_running
    end

    def running? : Bool
      @running
    end

    private def run_loop(interval : Time::Span, run_generation : UInt64) : Nil
      while @running && @run_generation == run_generation
        poll
        sleep interval
      end
    ensure
      if @run_generation == run_generation
        @running = false
        @worker = nil
      end
    end

    private def inspect(state : WatchState, force : Bool) : Bool
      baseline = state.baseline
      return false unless baseline
      baseline = baseline.not_nil!

      stamp = FileRevision.probe(state.token.path)
      return false unless force || !baseline.stamp.same_as?(stamp)

      epoch = state.epoch
      @hash_passes += 1_u64
      result = capture(state.token.path, stamp)
      return false unless current_state?(state, epoch)
      publish(state, result, epoch)
    end

    private def publish(state : WatchState, result : FileRevision::Result, epoch : UInt64) : Bool
      return false unless current_state?(state, epoch)
      previous = state.baseline
      return false unless previous
      previous = previous.not_nil!

      # A changing writer is retried on a later poll. Publishing an unstable
      # partial read would create a false conflict candidate.
      return false if result.unstable?

      kind = self.class.event_kind(previous, result)
      state.baseline = result
      return false unless kind

      event = Event.new(kind.not_nil!, state.token, previous, result)
      @on_event.call(event)
      true
    end

    private def capture(path : Path, stamp : FileRevision::Stamp? = nil) : FileRevision::Result
      FileRevision.capture(
        path,
        max_bytes: @max_bytes,
        chunk_size: @chunk_size,
        expected_stamp: stamp,
      )
    end

    private def baseline_result(path : Path, revision : FileRevision) : FileRevision::Result
      FileRevision::Result.new(
        path,
        FileRevision::Status::Stable,
        nil,
        revision,
        revision.stamp,
        revision.stamp,
      )
    end

    private def usable_baseline?(path : Path, revision : FileRevision) : Bool
      return false unless revision.path == path
      return false unless revision.stamp.regular?
      if limit = @max_bytes
        return false if revision.stamp.size > limit
      end
      true
    end

    private def current_state?(state : WatchState, epoch : UInt64? = nil) : Bool
      current = @watches[state.token.path.to_s]?
      return false unless current && current.not_nil!.token == state.token
      epoch.nil? || current.not_nil!.epoch == epoch
    end

    private def next_generation : UInt64
      @next_generation &+= 1_u64
      @next_generation
    end
  end
end
