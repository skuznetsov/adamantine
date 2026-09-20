require "crystal_tui"
require "set"

require "./lsp_client"
require "./document_session"
require "./document_types"
require "./recovery_store"

module Adamantine
  # Coordinates the editor-facing part of draft recovery.
  #
  # Construction is deliberately inert.  The store (and therefore its
  # private directory and session lock) is opened only by +initialize_session+
  # or +start+.  This keeps App.new safe for headless specs and embedders.
  class RecoveryController
    alias BufferLookup = Proc(Hash(String, OpenBuffer))
    alias Reporter = Proc(String, Nil)
    alias SnapshotWriter = Proc(Path, Int64, Proc(Bool), Proc(IO, Nil), Bool)
    alias ReleaseClean = Proc(Path, Nil)
    alias CloseSession = Proc(Nil)

    CHECKPOINT_INTERVAL = 2.seconds
    # A force quit must not wait indefinitely for a slow filesystem.  The
    # already accepted checkpoint remains the fallback if this budget expires.
    FINAL_CHECKPOINT_BUDGET = 250.milliseconds

    struct RecoveryCandidate
      getter source_path : Path
      getter path : Path
      getter version : Int64?
      getter session_id : String
      getter captured_at : Time
      getter file_name : String
      getter project : String
      getter modified : Bool
      getter bytes : Int64
      getter digest : String

      def initialize(
        @source_path : Path,
        @path : Path,
        @version : Int64?,
        @session_id : String = "",
        @captured_at : Time = Time.utc,
        @file_name : String = "",
        @project : String = "",
        @modified : Bool = true,
        @bytes : Int64 = 0_i64,
        @digest : String = "",
      )
      end

      def label : String
        version = @version ? "version #{@version}" : "unknown version"
        session_id = short_session_id
        session = session_id.empty? ? "unknown session" : "session #{session_id}"
        "#{@source_path} (#{version}, #{session}, #{@captured_at})"
      end

      private def short_session_id : String
        return "" if @session_id.empty?
        return @session_id[8, 8] if @session_id.starts_with?("session-") && @session_id.size > 8
        @session_id[0, 8]
      end
    end

    # Immutable checkpoint bytes captured for a read-only review.  The
    # authorized source path is lexical metadata for a later disk capture;
    # this backend never opens it or treats it as read authority.
    struct RecoveryPreview
      getter candidate : RecoveryCandidate
      getter content : String
      getter authorized_source_path : Path?

      def initialize(
        @candidate : RecoveryCandidate,
        @content : String,
        @authorized_source_path : Path?,
      )
      end

      def checkpoint : RecoveryCandidate
        @candidate
      end
    end

    getter project : String
    getter root : Path?
    getter enabled : Bool
    getter last_warnings : Array(String)
    property before_publish : Proc(Path, Nil)?

    @buffers : BufferLookup
    @report : Reporter
    @store : RecoveryStore?
    @write_snapshot : SnapshotWriter?
    @release_clean : ReleaseClean?
    @close_session : CloseSession?
    @initialized : Bool = false
    @running : Bool = false
    @shutdown_started : Bool = false
    @tick_in_progress : Bool = false
    @tick_done : Channel(Nil) = Channel(Nil).new(1)
    @cached_versions : Hash(String, Int64) = {} of String => Int64
    @cached_buffers : Hash(String, OpenBuffer) = {} of String => OpenBuffer
    @last_warnings = [] of String

    def initialize(
      project : Path | String,
      @buffers : BufferLookup,
      @root : Path? = nil,
      @report : Reporter = ->(_message : String) { },
      enabled : Bool? = nil,
    )
      # Expand once so :cd cannot silently change the store's project
      # affiliation while this controller is alive.
      @project = Path.new(project.to_s).expand.to_s
      @enabled = enabled.nil? ? ENV["ADAMANTINE_RECOVERY"]? != "0" : enabled.not_nil!
    end

    def initialized? : Bool
      @initialized
    end

    def running? : Bool
      @running
    end

    # Opens the private recovery session and scans abandoned sessions.  This
    # is the only controller operation that may create recovery state.
    def initialize_session : Bool
      return false unless @enabled
      return false if @shutdown_started
      return @initialized if @initialized

      begin
        store = RecoveryStore.new(root: @root, project: @project)
        session = store.open_session

        @store = store
        @write_snapshot = ->(path : Path, version : Int64, freshness : Proc(Bool), writer : Proc(IO, Nil)) do
          result = session.write_snapshot(
            source_path: path,
            modified: true,
            version: version,
            freshness: freshness,
          ) do |io|
            writer.call(io)
          end
          !result.nil?
        end
        @release_clean = ->(path : Path) do
          session.release_clean(path)
          nil
        end
        @close_session = -> do
          session.close
          nil
        end
        @initialized = true
        true
      rescue ex
        @report.call("Recovery unavailable: #{ex.message || ex.class}")
        @store.try(&.close)
        @store = nil
        @write_snapshot = nil
        @release_clean = nil
        @close_session = nil
        false
      end
    end

    # Alias used by tests and by callers that want to make the lifecycle
    # boundary explicit without starting the periodic worker.
    def initialize_recovery : Bool
      initialize_session
    end

    # Starts one cooperative worker.  The worker processes buffers in stable
    # path order and never uses the materializing editor.text API.
    def start(interval : Time::Span = CHECKPOINT_INTERVAL) : Bool
      return false if @shutdown_started
      return false unless initialize_session
      return true if @running

      @running = true
      spawn do
        while @running
          tick
          break unless @running
          sleep interval
        end
      rescue ex
        @report.call("Recovery worker stopped: #{ex.message || ex.class}")
        @running = false
      end
      true
    end

    # Executes one deterministic checkpoint pass.  It is public so headless
    # tests and callers with their own event loop can drive recovery manually.
    # The return value counts accepted snapshots and successful retirements.
    def tick : Int32
      return 0 unless @initialized
      return 0 if @shutdown_started
      return 0 if @tick_in_progress

      checkpoint_pass
    end

    private def checkpoint_pass : Int32
      return 0 if @tick_in_progress

      @tick_in_progress = true

      begin
        current = @buffers.call
        changed = 0
        seen = Set(String).new

        current.values.sort_by { |buffer| buffer.path.to_s }.each do |buffer|
          key = buffer.path.to_s
          seen << key
          if buffer.editor.modified?
            changed += checkpoint_buffer(buffer, key)
          else
            changed += release_clean(key)
          end
        end

        # A closed buffer no longer appears in DocumentSession.  Only paths that
        # this session accepted are retired; another session's draft is never
        # touched by this pass.
        @cached_versions.keys.each do |key|
          next if seen.includes?(key)
          changed += release_clean(key)
        end

        changed
      rescue ex
        @report.call("Recovery checkpoint failed: #{ex.message || ex.class}")
        0
      ensure
        @tick_in_progress = false
        # Do not block a completed checkpoint on shutdown's waiter.  The
        # bounded channel carries at most one wakeup for the active pass.
        select
        when @tick_done.send(nil)
        else
        end
      end
    end

    # Stops the worker without joining an unbounded background fiber.  A force
    # stop makes one best-effort final pass, preserving the prior accepted
    # draft if a slow filesystem exceeds FINAL_CHECKPOINT_BUDGET.
    def stop(force : Bool = false) : Nil
      @running = false
      return unless @initialized
      return if @shutdown_started

      @shutdown_started = true

      shutdown_checkpoint(force)
    end

    def manual_tick : Int32
      tick
    end

    def candidates : Array(RecoveryCandidate)
      return [] of RecoveryCandidate unless @initialized

      @last_warnings.clear
      scan = @store.not_nil!.candidates(project: @project)
      apply_scan_warnings(scan)
      scan.candidates.map do |candidate|
        RecoveryCandidate.new(
          source_path: candidate.source_path,
          path: candidate.path,
          version: candidate.version,
          session_id: candidate.session_id,
          captured_at: candidate.captured_at,
          file_name: candidate.file_name,
          project: candidate.project,
          modified: candidate.modified,
          bytes: candidate.bytes,
          digest: candidate.digest,
        )
      end
    rescue ex
      @report.call("Recovery scan failed: #{ex.message || ex.class}")
      [] of RecoveryCandidate
    end

    # Captures checkpoint bytes only.  No source or disk read occurs here and
    # no recovered copy is created; the caller may use the authorized path to
    # perform its own separately guarded disk/editor captures.
    def preview(candidate : RecoveryCandidate) : RecoveryPreview?
      return nil unless @initialized

      raw = find_store_candidate(candidate)
      unless raw
        @report.call("Recovery checkpoint is no longer available: #{candidate.label}")
        return nil
      end

      content = @store.not_nil!.read_checkpoint_content(raw)
      RecoveryPreview.new(candidate, content, authorized_source_path(candidate.source_path))
    rescue ex
      @report.call("Recovery preview failed for #{candidate.label}: #{ex.message || ex.class}")
      nil
    end

    # Returns a private copy and intentionally leaves the checkpoint in place.
    # The caller should open the returned path as a new editor buffer.
    def recover(candidate : RecoveryCandidate) : Path?
      return nil unless @initialized

      raw = find_store_candidate(candidate)
      unless raw
        @report.call("Recovery checkpoint is no longer available: #{candidate.label}")
        return nil
      end

      copy = @store.not_nil!.recover(raw)
      path = copy.path
      @report.call("Recovered #{candidate.source_path} into private copy #{path}; original unchanged")
      path
    rescue ex
      @report.call("Recovery failed for #{candidate.label}: #{ex.message || ex.class}")
      nil
    end

    # Explicit discard is separate from recovery; callers should not combine
    # these actions in one UI operation.
    def discard(candidate : RecoveryCandidate) : Bool
      return false unless @initialized

      raw = find_store_candidate(candidate)
      unless raw
        @report.call("Recovery checkpoint is no longer available: #{candidate.label}")
        return false
      end

      result = @store.not_nil!.discard(raw)
      refresh_candidates
      case result
      when Bool
        result
      else
        true
      end
    rescue ex
      @report.call("Recovery discard failed for #{candidate.label}: #{ex.message || ex.class}")
      false
    end

    private def checkpoint_buffer(buffer : OpenBuffer, key : String) : Int32
      version = buffer.version.to_i64
      if cached_version = @cached_versions[key]?
        cached_buffer = @cached_buffers[key]?
        return 0 if cached_version == version && cached_buffer && cached_buffer.same?(buffer)
      end

      # This hook exists only for deterministic race tests.  The store's
      # freshness callback remains the authoritative pre-publish guard.
      @before_publish.try(&.call(buffer.path))

      freshness = -> do
        current = @buffers.call[key]?
        !current.nil? && current.not_nil!.same?(buffer) &&
        current.not_nil!.version.to_i64 == version && current.not_nil!.editor.modified?
      end
      writer = ->(io : IO) do
        buffer.editor.write_to(io)
        nil
      end

      accepted = @write_snapshot.not_nil!.call(buffer.path, version, freshness, writer)
      return 0 unless accepted

      # Cache state changes only after the store accepted the snapshot.  A
      # stale or failed write consequently cannot hide the previous draft.
      @cached_versions[key] = version
      @cached_buffers[key] = buffer
      1
    rescue ex
      @report.call("Recovery checkpoint failed for #{buffer.path}: #{ex.message || ex.class}")
      0
    end

    private def release_clean(key : String) : Int32
      return 0 unless @cached_versions.has_key?(key)

      @release_clean.not_nil!.call(Path.new(key))
      @cached_versions.delete(key)
      @cached_buffers.delete(key)
      1
    rescue ex
      @report.call("Recovery cleanup failed for #{key}: #{ex.message || ex.class}")
      0
    end

    private def refresh_candidates : Nil
      # Scans are explicit lifecycle/menu operations, never part of the
      # periodic writer pass.  This keeps an every-two-second checkpoint from
      # repeatedly traversing abandoned sessions.
      @last_warnings.clear
      scan = @store.not_nil!.candidates(project: @project)
      apply_scan_warnings(scan)
      nil
    rescue ex
      warning = "Recovery scan warning: #{ex.message || ex.class}"
      @last_warnings << warning
      @report.call(warning)
      nil
    end

    private def find_store_candidate(candidate : RecoveryCandidate)
      @last_warnings.clear
      scan = @store.not_nil!.candidates(project: @project)
      apply_scan_warnings(scan)
      scan.candidates.find do |raw|
        raw.path == candidate.path &&
          raw.source_path == candidate.source_path &&
          raw.version == candidate.version &&
          raw.session_id == candidate.session_id &&
          raw.captured_at == candidate.captured_at &&
          raw.file_name == candidate.file_name &&
          raw.project == candidate.project &&
          raw.modified == candidate.modified &&
          raw.bytes == candidate.bytes &&
          raw.digest == candidate.digest
      end
    end

    # Path authorization is deliberately lexical.  It prevents metadata from
    # escaping this controller's canonical project root without opening the
    # source, resolving symlinks, or otherwise turning checkpoint metadata into
    # filesystem authority.  A later disk capture must apply its own stable
    # regular-file/symlink checks.
    private def authorized_source_path(source : Path) : Path?
      project = Path.new(@project).expand
      candidate = source.expand
      project_string = project.to_s
      candidate_string = candidate.to_s
      return candidate if candidate_string == project_string
      return candidate if candidate_string.starts_with?(project_string + "/")
      nil
    end

    private def shutdown_checkpoint(force : Bool) : Nil
      done = Channel(Nil).new(1)

      # The final worker waits for any periodic pass already inside a streaming
      # write.  It owns session close, so a timeout can never unlock a session
      # while an earlier write still has the store's temporary file open.
      spawn do
        begin
          wait_for_tick
          if @initialized
            # Shutdown has already blocked public tick calls, so this private
            # pass is the sole writer allowed after the periodic worker drains.
            # Both ordinary and forced exits get one final serialized pass;
            # callers that need a bounded force quit are protected by the outer
            # budget while this worker drains in the background.
            checkpoint_pass
          end
          close_session
          signal(done)
        rescue ex
          @report.call("Recovery shutdown failed: #{ex.message || ex.class}")
          close_session
          signal(done)
        end
      end

      select
      when done.receive
      when timeout(FINAL_CHECKPOINT_BUDGET)
        @report.call("Recovery final checkpoint timed out; previous accepted drafts preserved")
      end
    rescue ex
      @report.call("Recovery shutdown failed: #{ex.message || ex.class}")
    end

    private def wait_for_tick : Nil
      while @tick_in_progress
        @tick_done.receive
      end
    end

    private def signal(channel : Channel(Nil)) : Nil
      select
      when channel.send(nil)
      else
      end
    end

    private def apply_scan_warnings(scan) : Nil
      scan.warnings.each do |warning|
        suffix = warning.path ? " (#{warning.path})" : ""
        message = "Recovery scan warning: #{warning.message}#{suffix}"
        @last_warnings << message unless @last_warnings.includes?(message)
        @report.call(message)
      end
      nil
    end

    private def close_session : Nil
      begin
        @close_session.try(&.call)
      rescue ex
        @report.call("Recovery shutdown failed: #{ex.message || ex.class}")
      ensure
        # A close failure must not leave this controller presenting stale
        # callbacks or cache state to a later run.  The store owns the actual
        # lock release and will retry/finish in its own close path.
        @close_session = nil
        @write_snapshot = nil
        @release_clean = nil
        @store = nil
        @initialized = false
        @shutdown_started = false
        @cached_versions.clear
        @cached_buffers.clear
        @last_warnings.clear
      end
    rescue ex
      @report.call("Recovery shutdown failed: #{ex.message || ex.class}")
    end
  end
end
