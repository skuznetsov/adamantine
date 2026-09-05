require "digest/sha256"
require "json"

module Adamantine
  # Private, best-effort persistence for dirty editor buffers.  A store never
  # opens a source path while recovering: source paths in a checkpoint are
  # display metadata only.
  class RecoveryStore
    MAX_DOCUMENT_BYTES        = 16_i64 * 1024 * 1024
    MAX_SNAPSHOTS_PER_SESSION = 128
    MAX_SESSION_BYTES         = 256_i64 * 1024 * 1024
    MAX_SCANNED_SESSIONS      =  128
    MAX_SCANNED_SNAPSHOTS     = 4096
    # The byte cap admits one complete per-session quota.  It still bounds a
    # scan globally; the session and snapshot caps bound how many entries can
    # be examined when several abandoned sessions exist.
    MAX_SCANNED_BYTES                = MAX_SESSION_BYTES
    MAX_RECOVERED_COPIES_PER_SESSION = 128
    MAX_METADATA_BYTES               = 64_i64 * 1024
    MAX_METADATA_STRING_BYTES        = 16_i64 * 1024
    CHUNK_SIZE                       = 64 * 1024

    SNAPSHOT_PREFIX     = "snapshot-"
    SNAPSHOT_SUFFIX     = ".arc"
    SESSION_PREFIX      = "session-"
    SESSION_HEX_BYTES   = 16
    SNAPSHOT_HEX_BYTES  = 16
    RECOVERED_PREFIX    = "recovered-"
    RECOVERED_HEX_BYTES = 16

    FRAME_MAGIC         = "ADAMANTINE_RECOVERY_SNAPSHOT_V1"
    FRAME_TRAILER_MAGIC = "ADAMANTINE_RECOVERY_END_V1"
    FRAME_VERSION       =  1
    DIGEST_HEX_BYTES    = 64
    FRAME_TRAILER_BYTES = FRAME_TRAILER_MAGIC.bytesize + 8 + DIGEST_HEX_BYTES

    enum ErrorCode
      Io
      Invalid
      Locked
      ActiveSession
      Corrupt
      Stale
      Quota
      Closed
      NotFound
      ScanLimit
      NotModified
      Symlink
    end

    class Error < Exception
      getter code : ErrorCode
      getter path : Path?

      def initialize(@code : ErrorCode, message : String, @path : Path? = nil)
        super(message)
      end
    end

    alias RecoveryError = Error

    struct Warning
      getter code : ErrorCode
      getter path : Path?
      getter message : String

      def initialize(@code : ErrorCode, @message : String, @path : Path? = nil)
      end
    end

    class Checkpoint
      getter session_id : String
      getter file_name : String
      getter path : Path
      getter source_path : Path
      getter project : String
      getter version : Int64?
      getter modified : Bool
      getter bytes : Int64
      getter digest : String
      getter captured_at : Time

      # These aliases keep the storage vocabulary out of controller code.
      def source : Path
        @source_path
      end

      def buffer_version : Int64?
        @version
      end

      def created_at : Time
        @captured_at
      end

      def checkpoint_path : Path
        @path
      end

      def frame_path : Path
        @path
      end

      def content_size : Int64
        @bytes
      end

      def initialize(
        @session_id : String,
        @file_name : String,
        @path : Path,
        @source_path : Path,
        @project : String,
        @version : Int64?,
        @modified : Bool,
        @bytes : Int64,
        @digest : String,
        @captured_at : Time,
        @content_offset : Int64,
      )
      end

      protected def content_offset : Int64
        @content_offset
      end
    end

    alias Candidate = Checkpoint
    alias Snapshot = Checkpoint

    class ScanResult
      include Enumerable(Checkpoint)

      getter entries : Array(Checkpoint)
      getter warnings : Array(Warning)
      getter truncated : Bool

      def initialize(@entries : Array(Checkpoint), @warnings : Array(Warning), @truncated : Bool = false)
      end

      def each(& : Checkpoint ->)
        @entries.each { |entry| yield entry }
      end

      def size : Int32
        @entries.size
      end

      def empty? : Bool
        @entries.empty?
      end

      def first : Checkpoint
        @entries.first
      end

      def [](index : Int) : Checkpoint
        @entries[index]
      end

      # Compatibility for callers which prefer the noun over Enumerable.
      def candidates : Array(Checkpoint)
        @entries
      end

      # Scan warnings are deliberately non-fatal so an editor can continue
      # operating when one abandoned entry is damaged.
      def errors : Array(Warning)
        @warnings
      end

      def truncated? : Bool
        @truncated
      end
    end

    class RecoveryCopy
      getter path : Path
      getter source_path : Path
      getter session_id : String
      getter bytes : Int64

      def copy_path : Path
        @path
      end

      def initialize(@path : Path, @source_path : Path, @session_id : String, @bytes : Int64)
      end
    end

    class SnapshotWriter < IO
      getter bytes : Int64

      def initialize(
        @target : File,
        @digest : Digest::SHA256,
        @base_bytes : Int64,
        @frame_overhead : Int64,
      )
        @bytes = 0_i64
        @closed = false
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("recovery snapshot writer is write-only")
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("recovery snapshot writer is closed") if @closed
        return if slice.empty?

        next_bytes = @bytes + slice.size.to_i64
        if next_bytes > MAX_DOCUMENT_BYTES
          raise RecoveryStore::Error.new(RecoveryStore::ErrorCode::Quota, "recovery document exceeds #{MAX_DOCUMENT_BYTES} bytes")
        end

        # The old accepted checkpoint remains beside this temporary file until
        # the final rename, so the peak includes both representations.
        peak = @base_bytes + @frame_overhead + next_bytes
        if peak > MAX_SESSION_BYTES
          raise RecoveryStore::Error.new(RecoveryStore::ErrorCode::Quota, "recovery session exceeds #{MAX_SESSION_BYTES} bytes")
        end

        @target.write(slice)
        @digest.update(slice)
        @bytes = next_bytes
        Fiber.yield
      end

      def flush : Nil
        @target.flush
      end

      def close : Nil
        @closed = true
      end

      def closed? : Bool
        @closed
      end
    end

    class Session
      getter id : String
      getter path : Path
      getter project : String

      def initialize(
        @store : RecoveryStore,
        @id : String,
        @path : Path,
        @lock : File,
        @project : String,
      )
        @mutex = Mutex.new
        @closed = false
      end

      def session_id : String
        @id
      end

      def closed? : Bool
        @closed
      end

      # Streams one editor buffer into a framed temporary file.  The old
      # checkpoint is not replaced until the caller's freshness predicate has
      # passed after flush/fsync.
      def write_snapshot(
        path : Path | String | Nil = nil,
        *,
        source_path : Path | String | Nil = nil,
        modified : Bool = true,
        version : Int32 | Int64 | Nil = nil,
        freshness : Proc(Bool) = -> { true },
        &block : IO ->
      ) : Checkpoint
        source_value = source_path || path
        raise Error.new(ErrorCode::Invalid, "recovery snapshot source path is required") unless source_value
        source = @store.expand_source_path(source_value.not_nil!)
        return raise(Error.new(ErrorCode::NotModified, "clean buffers are not checkpointed")) unless modified
        buffer_version = version.try(&.to_i64)

        @mutex.synchronize do
          ensure_open!
          @store.write_snapshot(
            self,
            source,
            @project,
            buffer_version,
            freshness,
            &block
          )
        end
      end

      # A controller calls this after a buffer becomes clean or closes.  It
      # only removes validated frame names belonging to this live session.
      def release_clean(source_path : Path | String) : Int32
        source = @store.expand_source_path(source_path)
        @mutex.synchronize do
          ensure_open!
          @store.release_clean(@id, @path, source)
        end
      end

      def retire(source_path : Path | String) : Int32
        release_clean(source_path)
      end

      def close : Nil
        return if @closed

        @mutex.synchronize do
          return if @closed
          # Keep the lock held while deciding whether this own session can be
          # retired.  Abandoned sessions are never removed by scan/discard.
          @store.remove_empty_owned_session(@id, @path, @lock)
          @lock.flock_unlock rescue nil
          @lock.close unless @lock.closed?
          @closed = true
        end
      rescue ex : Error
        @lock.flock_unlock rescue nil
        @lock.close unless @lock.closed?
        @closed = true
        raise ex
      end

      def release : Nil
        close
      end

      private def ensure_open! : Nil
        raise Error.new(ErrorCode::Closed, "recovery session is closed", @path) if @closed
      end
    end

    getter root : Path
    getter project : String?

    def self.default_root : Path
      state_home = ENV["XDG_STATE_HOME"]?
      base = if state_home && !state_home.empty? && Path.new(state_home.not_nil!).absolute?
               Path.new(state_home.not_nil!)
             else
               Path.home / ".local" / "state"
             end
      (base / "adamantine" / "recovery").expand
    end

    def initialize(root : Path | String | Nil = nil, project : Path | String | Nil = nil)
      @root = (root ? Path.new(root.to_s) : self.class.default_root).expand
      @project = project.try { |value| Path.new(value.to_s).expand.to_s }
      @sessions_path = @root / "sessions"
      @recovered_path = @root / "recovered"
      @session = nil.as(Session?)
    end

    def open_session : Session
      if existing = @session
        raise Error.new(ErrorCode::Closed, "recovery session is closed", @root) if existing.closed?
        return existing
      end

      ensure_layout!
      session = create_session
      @session = session
      session
    end

    def session : Session
      open_session
    end

    def open : Session
      open_session
    end

    def close : Nil
      if current = @session
        current.close
        @session = nil
      end
    end

    # Returns only snapshots whose session lock can be acquired.  A damaged
    # entry becomes a warning; it never causes a caller-facing scan failure.
    def candidates(project : String? = @project) : ScanResult
      entries = [] of Checkpoint
      warnings = [] of Warning
      truncated = false
      examined_snapshots = 0
      examined_bytes = 0_i64
      byte_limit_reached = false

      begin
        ensure_layout!
        session_names, session_limit = bounded_children(@sessions_path, MAX_SCANNED_SESSIONS)
        if session_limit
          truncated = true
          warnings << Warning.new(ErrorCode::ScanLimit, "recovery session scan limit reached", @sessions_path)
        end

        examined = 0
        session_names.each do |session_name|
          break if examined >= MAX_SCANNED_SESSIONS
          examined += 1
          next unless valid_session_name?(session_name)

          session_path = @sessions_path / session_name
          unless private_directory?(session_path)
            warnings << Warning.new(ErrorCode::Invalid, "recovery session directory rejected", session_path)
            next
          end

          lock_path = session_path / "lock"
          lock = open_abandoned_lock(lock_path)
          next unless lock

          begin
            snapshot_names, snapshot_limit = bounded_children(session_path, MAX_SNAPSHOTS_PER_SESSION + 1)
            if snapshot_limit
              truncated = true
              warnings << Warning.new(ErrorCode::ScanLimit, "recovery snapshot scan limit reached", session_path)
            end

            session_examined = 0
            snapshot_names.each do |snapshot_name|
              break if session_examined >= MAX_SNAPSHOTS_PER_SESSION
              break if examined_snapshots >= MAX_SCANNED_SNAPSHOTS
              next unless valid_snapshot_name?(snapshot_name)
              snapshot_path = session_path / snapshot_name
              unless private_file?(snapshot_path)
                warnings << Warning.new(ErrorCode::Invalid, "recovery snapshot rejected", snapshot_path)
                next
              end

              session_examined += 1
              examined_snapshots += 1
              info = File.info?(snapshot_path, follow_symlinks: false)
              snapshot_bytes = info.try(&.size) || 0_i64
              if snapshot_bytes < 0 || examined_bytes + snapshot_bytes > MAX_SCANNED_BYTES
                truncated = true
                byte_limit_reached = true
                warnings << Warning.new(ErrorCode::ScanLimit, "recovery byte scan limit reached", snapshot_path)
                break
              end
              examined_bytes += snapshot_bytes

              begin
                checkpoint = read_frame(snapshot_path, session_name, snapshot_name)
                next if project && checkpoint.project != project
                entries << checkpoint
              rescue ex : Error
                warnings << Warning.new(ex.code, ex.message || "recovery snapshot rejected", snapshot_path)
              rescue ex
                warnings << Warning.new(ErrorCode::Corrupt, "recovery snapshot rejected: #{ex.message}", snapshot_path)
              end
            end
            if examined_snapshots >= MAX_SCANNED_SNAPSHOTS
              truncated = true
              warnings << Warning.new(ErrorCode::ScanLimit, "recovery snapshot scan limit reached", @sessions_path)
              break
            end
            break if byte_limit_reached
          ensure
            release_lock(lock)
          end
        end
      rescue ex : Error
        warnings << Warning.new(ex.code, ex.message || "recovery scan failed", @root)
      rescue ex
        warnings << Warning.new(ErrorCode::Io, "recovery scan failed: #{ex.message}", @root)
      end

      entries.sort_by! { |entry| {-entry.captured_at.to_unix_ms, entry.file_name} }
      ScanResult.new(entries, warnings, truncated)
    end

    # Recover to a uniquely named plain-text copy inside the private store.
    # The destination is never caller supplied and the source path is never
    # opened, written, renamed, or deleted.
    def recover(candidate : Checkpoint) : RecoveryCopy
      ensure_layout!
      session_path, snapshot_path = validated_candidate_paths(candidate)
      lock = acquire_required_lock(session_path / "lock")
      begin
        unless private_file?(snapshot_path)
          raise Error.new(ErrorCode::NotFound, "recovery checkpoint no longer exists", snapshot_path)
        end
        current = read_frame(snapshot_path, candidate.session_id, candidate.file_name)
        unless same_checkpoint?(candidate, current)
          raise Error.new(ErrorCode::Corrupt, "recovery checkpoint identity changed", snapshot_path)
        end

        copy_dir = @recovered_path / candidate.session_id
        ensure_private_directory!(copy_dir, 0o700)
        recovered_names, recovered_limit = bounded_children(copy_dir, MAX_RECOVERED_COPIES_PER_SESSION + 1)
        raise Error.new(ErrorCode::Quota, "recovery copy directory scan is bounded", copy_dir) if recovered_limit
        recovered_count = recovered_names.count { |name| valid_recovered_name?(name) }
        if recovered_count >= MAX_RECOVERED_COPIES_PER_SESSION
          raise Error.new(ErrorCode::Quota, "recovery copy limit reached", copy_dir)
        end

        existing_bytes = session_storage_bytes(session_path, copy_dir)
        frame_overhead = frame_header_bytes(current) + FRAME_TRAILER_BYTES
        if existing_bytes + frame_overhead + current.bytes > MAX_SESSION_BYTES
          raise Error.new(ErrorCode::Quota, "recovery session exceeds #{MAX_SESSION_BYTES} bytes", session_path)
        end

        basename = safe_recovery_basename(current.source_path)
        final_name = "#{RECOVERED_PREFIX}#{Random::Secure.hex(RECOVERED_HEX_BYTES)}-#{basename}"
        final_path = copy_dir / final_name
        temp = File.tempfile(prefix: ".recovered-", suffix: ".tmp", dir: copy_dir.to_s)
        temp_path = Path.new(temp.path)
        begin
          stream_frame_content(snapshot_path, current, temp)
          temp.flush
          temp.fsync
          File.rename(temp_path.to_s, final_path.to_s)
          fsync_directory(copy_dir)
          temp_path = nil
          RecoveryCopy.new(final_path, current.source_path, current.session_id, current.bytes)
        ensure
          temp.close unless temp.closed?
          File.delete(temp_path.to_s) if temp_path && File.exists?(temp_path)
        end
      ensure
        release_lock(lock)
      end
    end

    # Delete exactly one validated abandoned checkpoint.  It deliberately
    # leaves session locks, session directories, and recovered copies intact.
    def discard(candidate : Checkpoint) : Nil
      ensure_layout!
      session_path, snapshot_path = validated_candidate_paths(candidate)
      lock = acquire_required_lock(session_path / "lock")
      begin
        unless private_file?(snapshot_path)
          raise Error.new(ErrorCode::NotFound, "recovery checkpoint no longer exists", snapshot_path)
        end
        current = read_frame(snapshot_path, candidate.session_id, candidate.file_name)
        unless same_checkpoint?(candidate, current)
          raise Error.new(ErrorCode::Corrupt, "recovery checkpoint identity changed", snapshot_path)
        end
        File.delete(snapshot_path.to_s)
        fsync_directory(session_path)
      ensure
        release_lock(lock)
      end
    end

    # Internal write entry point kept on the store so Session can hold its
    # mutex while all filesystem mutations remain serialized per session.
    protected def write_snapshot(
      session : Session,
      source : Path,
      project : String,
      version : Int64?,
      freshness : Proc(Bool),
      &block : IO ->
    ) : Checkpoint
      ensure_layout!
      session_path = session.path
      snapshot_name = snapshot_name_for(source)
      final_path = session_path / snapshot_name
      unless valid_snapshot_name?(snapshot_name)
        raise Error.new(ErrorCode::Invalid, "invalid recovery checkpoint name", final_path)
      end

      snapshot_names, snapshot_limit = bounded_children(session_path, MAX_SNAPSHOTS_PER_SESSION + 1)
      raise Error.new(ErrorCode::Quota, "recovery snapshot directory scan is bounded", session_path) if snapshot_limit
      valid_snapshots = snapshot_names.select { |name| valid_snapshot_name?(name) }
      if valid_snapshots.size >= MAX_SNAPSHOTS_PER_SESSION && !valid_snapshots.includes?(snapshot_name)
        raise Error.new(ErrorCode::Quota, "recovery snapshot count limit reached", session_path)
      end

      metadata = build_metadata(project, source, version)
      if metadata.bytesize > MAX_METADATA_BYTES
        raise Error.new(ErrorCode::Quota, "recovery metadata exceeds #{MAX_METADATA_BYTES} bytes", final_path)
      end
      frame_overhead = FRAME_MAGIC.bytesize.to_i64 + 4 + metadata.bytesize.to_i64 + FRAME_TRAILER_BYTES
      base_bytes = session_storage_bytes(session_path, @recovered_path / session.id)
      if base_bytes + frame_overhead > MAX_SESSION_BYTES
        raise Error.new(ErrorCode::Quota, "recovery session exceeds #{MAX_SESSION_BYTES} bytes", session_path)
      end

      # Reject an existing symlink before the atomic replacement.  A normal
      # file is replaced only after the new frame is fully durable.
      if info = File.info?(final_path, follow_symlinks: false)
        raise Error.new(ErrorCode::Symlink, "recovery checkpoint path is a symlink", final_path) if info.symlink?
        raise Error.new(ErrorCode::Invalid, "recovery checkpoint path is not a file", final_path) unless info.file?
        raise Error.new(ErrorCode::Invalid, "recovery checkpoint permissions are not private", final_path) if (info.permissions.to_i & 0o077) != 0
      end

      temp = File.tempfile(prefix: ".snapshot-", suffix: ".tmp", dir: session_path.to_s)
      temp_path = Path.new(temp.path)
      begin
        temp.write(FRAME_MAGIC.to_slice)
        write_u32(temp, metadata.bytesize.to_i64)
        temp.write(metadata.to_slice)
        digest = Digest::SHA256.new
        digest.update(metadata.to_slice)
        frame = SnapshotWriter.new(temp, digest, base_bytes, frame_overhead)
        yield frame
        frame.close
        write_trailer(temp, frame.bytes, digest.hexfinal)
        temp.flush
        temp.fsync

        # This call is the final user-controlled freshness boundary.  There
        # is no cooperative yield or other callback between it and rename.
        raise Error.new(ErrorCode::Stale, "recovery snapshot became stale", final_path) unless freshness.call
        File.rename(temp_path.to_s, final_path.to_s)
        fsync_directory(session_path)
        temp_path = nil
        read_frame(final_path, session.id, snapshot_name)
      ensure
        temp.close unless temp.closed?
        File.delete(temp_path.to_s) if temp_path && File.exists?(temp_path)
      end
    rescue ex : Error
      raise ex
    rescue ex
      raise Error.new(ErrorCode::Io, "failed to write recovery snapshot: #{ex.message}", final_path)
    end

    protected def release_clean(session_id : String, session_path : Path, source : Path) : Int32
      snapshot_name = snapshot_name_for(source)
      snapshot_path = session_path / snapshot_name
      return 0 unless private_file?(snapshot_path)
      begin
        checkpoint = read_frame(snapshot_path, session_id, snapshot_name)
        return 0 unless checkpoint.source_path == source
        File.delete(snapshot_path.to_s)
        fsync_directory(session_path)
        1
      rescue Error
        # A malformed checkpoint is not trusted for a delete decision.
        0
      end
    end

    protected def remove_empty_owned_session(session_id : String, session_path : Path, lock : File) : Nil
      names, limited = bounded_children(session_path, 3)
      return if limited
      return unless names.all? { |name| name == "lock" }
      lock_path = session_path / "lock"
      return unless names.includes?("lock") && private_file?(lock_path)
      # The descriptor remains exclusively locked while its directory entry is
      # removed, so no abandoned scanner can observe a reusable lock path.
      File.delete(lock_path.to_s)
      Dir.delete(session_path.to_s)
    rescue
      # Clean shutdown should not make the editor fail; leave the own lock and
      # directory for a later explicit cleanup if filesystem policy prevents it.
      nil
    end

    protected def expand_source_path(value : Path | String) : Path
      Path.new(value.to_s).expand
    end

    private def ensure_layout! : Nil
      ensure_private_directory!(@root, 0o700)
      ensure_private_directory!(@sessions_path, 0o700)
      ensure_private_directory!(@recovered_path, 0o700)
    end

    private def ensure_private_directory!(path : Path, mode : Int32) : Nil
      path = path.expand
      raise Error.new(ErrorCode::Invalid, "recovery root must not be filesystem root", path) if path.to_s == "/"
      components = path.to_s.split('/').reject(&.empty?)
      current = Path.new("/")
      components.each_with_index do |component, index|
        current = current / component
        info = File.info?(current, follow_symlinks: false)
        if info.nil?
          create_mode = index == components.size - 1 ? mode : 0o755
          begin
            Dir.mkdir(current.to_s, create_mode)
          rescue ex
            raise Error.new(ErrorCode::Io, "failed to create recovery directory: #{ex.message}", current)
          end
          info = File.info?(current, follow_symlinks: false)
        end
        raise Error.new(ErrorCode::Symlink, "recovery directory is a symlink", current) if info.nil? || info.symlink?
        raise Error.new(ErrorCode::Invalid, "recovery path is not a directory", current) unless info.directory?
        if index == components.size - 1 && (info.permissions.to_i & 0o077) != 0
          begin
            File.chmod(current.to_s, mode)
          rescue ex
            raise Error.new(ErrorCode::Io, "failed to protect recovery directory: #{ex.message}", current)
          end
        end
      end
    end

    private def create_session : Session
      attempts = 0
      while attempts < 64
        attempts += 1
        id = "#{SESSION_PREFIX}#{Random::Secure.hex(SESSION_HEX_BYTES)}"
        session_path = @sessions_path / id
        begin
          Dir.mkdir(session_path.to_s, 0o700)
        rescue
          next if File.info?(session_path, follow_symlinks: false)
          next
        end

        lock : File? = nil
        temp_lock : File? = nil
        temp_path : Path? = nil
        committed = false
        begin
          temp_lock = File.tempfile(prefix: ".lock-", suffix: ".tmp", dir: session_path.to_s)
          temp_path = Path.new(temp_lock.not_nil!.path)
          temp_lock.not_nil!.flock_exclusive(false)
          lock_path = session_path / "lock"
          File.rename(temp_path.to_s, lock_path.to_s)
          temp_path = nil
          lock = temp_lock
          temp_lock = nil
          File.chmod(lock_path.to_s, 0o600)
          committed = true
          return Session.new(self, id, session_path, lock.not_nil!, @project || "")
        rescue ex : Error
          raise ex
        rescue ex
          raise Error.new(ErrorCode::Io, "failed to initialize recovery session: #{ex.message}", session_path)
        ensure
          temp_lock.try do |file|
            file.flock_unlock rescue nil
            file.close unless file.closed?
          end
          if temp_path && File.exists?(temp_path.not_nil!)
            File.delete(temp_path.not_nil!.to_s) rescue nil
          end
          unless committed
            lock.try do |file|
              file.flock_unlock rescue nil
              file.close unless file.closed?
            end
            File.delete((session_path / "lock").to_s) if File.exists?(session_path / "lock") rescue nil
            Dir.delete(session_path.to_s) rescue nil
          end
        end
      end
      raise Error.new(ErrorCode::Io, "unable to allocate a recovery session", @sessions_path)
    end

    private def bounded_children(path : Path, limit : Int32) : {Array(String), Bool}
      names = [] of String
      truncated = false
      Dir.open(path.to_s) do |dir|
        loop do
          name = dir.read
          break unless name
          next if name == "." || name == ".."
          if names.size >= limit
            truncated = true
            break
          end
          names << name
        end
      end
      {names.sort!, truncated}
    rescue ex
      raise Error.new(ErrorCode::Io, "failed to scan recovery directory: #{ex.message}", path)
    end

    private def open_abandoned_lock(path : Path) : File?
      return nil unless private_file?(path)
      file = File.open(path.to_s, "r+")
      begin
        file.flock_exclusive(false)
        file
      rescue ex : IO::Error
        file.close unless file.closed?
        nil
      rescue ex
        file.close unless file.closed?
        nil
      end
    rescue
      nil
    end

    private def acquire_required_lock(path : Path) : File
      unless private_file?(path)
        raise Error.new(ErrorCode::NotFound, "recovery session lock is unavailable", path)
      end
      file = begin
        File.open(path.to_s, "r+")
      rescue ex
        raise Error.new(ErrorCode::Io, "failed to open recovery session lock: #{ex.message}", path)
      end
      begin
        file.flock_exclusive(false)
      rescue ex : IO::Error
        file.close unless file.closed?
        raise Error.new(ErrorCode::ActiveSession, "recovery session is active", path)
      rescue ex
        file.close unless file.closed?
        raise Error.new(ErrorCode::Locked, "recovery session lock failed: #{ex.message}", path)
      end
      file
    end

    private def release_lock(file : File) : Nil
      file.flock_unlock rescue nil
      file.close unless file.closed?
    end

    private def validated_candidate_paths(candidate : Checkpoint) : {Path, Path}
      unless valid_session_name?(candidate.session_id) && valid_snapshot_name?(candidate.file_name)
        raise Error.new(ErrorCode::Invalid, "untrusted recovery checkpoint identity")
      end
      session_path = @sessions_path / candidate.session_id
      snapshot_path = session_path / candidate.file_name
      unless private_directory?(session_path)
        raise Error.new(ErrorCode::Invalid, "recovery session directory is not private", session_path)
      end
      unless candidate.path.to_s == snapshot_path.to_s
        raise Error.new(ErrorCode::Invalid, "recovery checkpoint path does not match its identity", candidate.path)
      end
      {session_path, snapshot_path}
    end

    private def private_directory?(path : Path) : Bool
      info = File.info?(path, follow_symlinks: false)
      return false unless info
      info.directory? && !info.symlink? && (info.permissions.to_i & 0o077) == 0
    end

    private def private_file?(path : Path) : Bool
      info = File.info?(path, follow_symlinks: false)
      return false unless info
      info.file? && !info.symlink? && (info.permissions.to_i & 0o077) == 0
    end

    private def valid_session_name?(name : String) : Bool
      name.starts_with?(SESSION_PREFIX) && name[SESSION_PREFIX.bytesize..].size == SESSION_HEX_BYTES * 2 && hex_string?(name[SESSION_PREFIX.bytesize..])
    end

    private def valid_snapshot_name?(name : String) : Bool
      return false unless name.starts_with?(SNAPSHOT_PREFIX) && name.ends_with?(SNAPSHOT_SUFFIX)
      id = name[SNAPSHOT_PREFIX.bytesize, name.bytesize - SNAPSHOT_PREFIX.bytesize - SNAPSHOT_SUFFIX.bytesize]
      id.size == SNAPSHOT_HEX_BYTES * 2 && hex_string?(id)
    end

    private def valid_recovered_name?(name : String) : Bool
      return false unless name.starts_with?(RECOVERED_PREFIX)
      rest = name[RECOVERED_PREFIX.bytesize..]
      separator = rest.index('-')
      return false unless separator
      id = rest[0, separator]
      id.size == RECOVERED_HEX_BYTES * 2 && hex_string?(id) && rest.bytesize > separator.not_nil! + 1
    end

    private def hex_string?(value : String) : Bool
      value.each_byte.all? do |byte|
        (byte >= '0'.ord && byte <= '9'.ord) || (byte >= 'a'.ord && byte <= 'f'.ord)
      end
    end

    private def snapshot_name_for(source : Path) : String
      "#{SNAPSHOT_PREFIX}#{Digest::SHA256.hexdigest(source.to_s)[0, SNAPSHOT_HEX_BYTES * 2]}#{SNAPSHOT_SUFFIX}"
    end

    private def build_metadata(project : String, source : Path, version : Int64?) : String
      JSON.build do |json|
        json.object do
          json.field "format", FRAME_VERSION
          json.field "project", project
          json.field "source", source.to_s
          json.field "version", version
          json.field "modified", true
          json.field "captured_at_ms", Time.utc.to_unix_ms
        end
      end
    rescue ex
      raise Error.new(ErrorCode::Invalid, "failed to encode recovery metadata: #{ex.message}")
    end

    private def read_frame(path : Path, session_id : String, file_name : String) : Checkpoint
      info = File.info?(path, follow_symlinks: false)
      raise Error.new(ErrorCode::Corrupt, "recovery frame is unavailable", path) unless info && info.file? && !info.symlink?
      raise Error.new(ErrorCode::Corrupt, "recovery frame permissions are not private", path) if (info.permissions.to_i & 0o077) != 0
      file_size = info.size
      minimum = FRAME_MAGIC.bytesize.to_i64 + 4 + FRAME_TRAILER_BYTES
      raise Error.new(ErrorCode::Corrupt, "recovery frame is truncated", path) if file_size < minimum

      file = File.open(path.to_s, "rb")
      begin
        magic = Bytes.new(FRAME_MAGIC.bytesize)
        raise Error.new(ErrorCode::Corrupt, "recovery frame magic is invalid", path) unless read_exact(file, magic) && String.new(magic) == FRAME_MAGIC
        metadata_length = read_u32(file)
        raise Error.new(ErrorCode::Corrupt, "recovery metadata is too large", path) if metadata_length > MAX_METADATA_BYTES
        metadata_end = FRAME_MAGIC.bytesize.to_i64 + 4 + metadata_length
        raise Error.new(ErrorCode::Corrupt, "recovery metadata is truncated", path) if metadata_end + FRAME_TRAILER_BYTES > file_size
        metadata_bytes = Bytes.new(metadata_length.to_i)
        raise Error.new(ErrorCode::Corrupt, "recovery metadata is truncated", path) unless read_exact(file, metadata_bytes)
        fields = parse_metadata(metadata_bytes, path)

        content_bytes = file_size - metadata_end - FRAME_TRAILER_BYTES
        raise Error.new(ErrorCode::Corrupt, "recovery content exceeds document limit", path) if content_bytes < 0 || content_bytes > MAX_DOCUMENT_BYTES
        digest = Digest::SHA256.new
        digest.update(metadata_bytes)
        remaining = content_bytes
        chunk = Bytes.new(CHUNK_SIZE)
        while remaining > 0
          count = {remaining, CHUNK_SIZE.to_i64}.min.to_i
          read_slice = chunk[0, count]
          read_count = file.read(read_slice)
          raise Error.new(ErrorCode::Corrupt, "recovery content is truncated", path) if read_count <= 0
          digest.update(read_slice[0, read_count])
          remaining -= read_count
          Fiber.yield
        end

        trailer_magic = Bytes.new(FRAME_TRAILER_MAGIC.bytesize)
        raise Error.new(ErrorCode::Corrupt, "recovery frame footer is truncated", path) unless read_exact(file, trailer_magic)
        raise Error.new(ErrorCode::Corrupt, "recovery frame footer is invalid", path) unless String.new(trailer_magic) == FRAME_TRAILER_MAGIC
        footer_bytes = read_u64(file)
        footer_digest = Bytes.new(DIGEST_HEX_BYTES)
        raise Error.new(ErrorCode::Corrupt, "recovery frame checksum is truncated", path) unless read_exact(file, footer_digest)
        raise Error.new(ErrorCode::Corrupt, "recovery frame has trailing bytes", path) unless file.pos == file_size
        raise Error.new(ErrorCode::Corrupt, "recovery content length is invalid", path) unless footer_bytes == content_bytes
        digest_hex = String.new(footer_digest)
        raise Error.new(ErrorCode::Corrupt, "recovery checksum mismatch", path) unless digest.hexfinal == digest_hex

        captured_at = begin
          Time.unix_ms(fields[:captured_at_ms])
        rescue
          raise Error.new(ErrorCode::Corrupt, "recovery timestamp is invalid", path)
        end
        Checkpoint.new(
          session_id,
          file_name,
          path,
          fields[:source],
          fields[:project],
          fields[:version],
          fields[:modified],
          content_bytes,
          digest_hex,
          captured_at,
          metadata_end,
        )
      ensure
        file.close unless file.closed?
      end
    rescue ex : Error
      raise ex
    rescue ex
      raise Error.new(ErrorCode::Corrupt, "failed to read recovery frame: #{ex.message}", path)
    end

    private def parse_metadata(bytes : Bytes, path : Path) : NamedTuple(
      source: Path,
      project: String,
      version: Int64?,
      modified: Bool,
      captured_at_ms: Int64,
    )
      metadata_text = String.new(bytes)
      raise Error.new(ErrorCode::Corrupt, "recovery metadata is not valid UTF-8", path) unless metadata_text.valid_encoding?
      object = begin
        JSON.parse(metadata_text).as_h
      rescue ex
        raise Error.new(ErrorCode::Corrupt, "recovery metadata is invalid: #{ex.message}", path)
      end
      format = object["format"]?.try(&.as_i?)
      raise Error.new(ErrorCode::Corrupt, "recovery metadata format is invalid", path) unless format == FRAME_VERSION
      project = metadata_string(object, "project", path)
      source_string = metadata_string(object, "source", path)
      source = Path.new(source_string).expand
      version = object["version"]?.try(&.as_i64?)
      modified = object["modified"]?.try(&.as_bool?)
      captured_at = object["captured_at_ms"]?.try(&.as_i64?)
      raise Error.new(ErrorCode::Corrupt, "recovery metadata modified flag is invalid", path) unless modified == true
      raise Error.new(ErrorCode::Corrupt, "recovery metadata timestamp is invalid", path) unless captured_at
      {
        source:         source,
        project:        project,
        version:        version,
        modified:       modified.not_nil!,
        captured_at_ms: captured_at.not_nil!,
      }
    rescue ex : Error
      raise ex
    rescue ex
      raise Error.new(ErrorCode::Corrupt, "recovery metadata is invalid: #{ex.message}", path)
    end

    private def metadata_string(object : Hash(String, JSON::Any), key : String, path : Path) : String
      value = object[key]?.try(&.as_s?)
      raise Error.new(ErrorCode::Corrupt, "recovery metadata #{key} is invalid", path) unless value
      raise Error.new(ErrorCode::Corrupt, "recovery metadata #{key} is too large", path) if value.not_nil!.bytesize > MAX_METADATA_STRING_BYTES
      value.not_nil!
    end

    private def stream_frame_content(path : Path, checkpoint : Checkpoint, output : IO) : Nil
      file = File.open(path.to_s, "rb")
      begin
        file.seek(checkpoint.content_offset)
        digest = Digest::SHA256.new
        # Re-read metadata to seed the checksum without retaining content.
        file.rewind
        magic = Bytes.new(FRAME_MAGIC.bytesize)
        raise Error.new(ErrorCode::Corrupt, "recovery frame magic is invalid", path) unless read_exact(file, magic) && String.new(magic) == FRAME_MAGIC
        metadata_length = read_u32(file)
        raise Error.new(ErrorCode::Corrupt, "recovery metadata is too large", path) if metadata_length > MAX_METADATA_BYTES
        metadata_end = FRAME_MAGIC.bytesize.to_i64 + 4 + metadata_length
        frame_size = File.info(path, follow_symlinks: false).size
        raise Error.new(ErrorCode::Corrupt, "recovery metadata is truncated", path) if metadata_end + FRAME_TRAILER_BYTES > frame_size
        raise Error.new(ErrorCode::Corrupt, "recovery metadata offset changed", path) unless metadata_end == checkpoint.content_offset
        metadata = Bytes.new(metadata_length.to_i)
        raise Error.new(ErrorCode::Corrupt, "recovery metadata is truncated", path) unless read_exact(file, metadata)
        digest.update(metadata)
        file.seek(checkpoint.content_offset)
        remaining = checkpoint.bytes
        chunk = Bytes.new(CHUNK_SIZE)
        while remaining > 0
          count = {remaining, CHUNK_SIZE.to_i64}.min.to_i
          read_slice = chunk[0, count]
          read_count = file.read(read_slice)
          raise Error.new(ErrorCode::Corrupt, "recovery content is truncated", path) if read_count <= 0
          bytes = read_slice[0, read_count]
          output.write(bytes)
          digest.update(bytes)
          remaining -= read_count
          Fiber.yield
        end
        trailer_magic = Bytes.new(FRAME_TRAILER_MAGIC.bytesize)
        raise Error.new(ErrorCode::Corrupt, "recovery frame footer is truncated", path) unless read_exact(file, trailer_magic)
        raise Error.new(ErrorCode::Corrupt, "recovery frame footer is invalid", path) unless String.new(trailer_magic) == FRAME_TRAILER_MAGIC
        footer_bytes = read_u64(file)
        footer_digest = Bytes.new(DIGEST_HEX_BYTES)
        raise Error.new(ErrorCode::Corrupt, "recovery checksum is truncated", path) unless read_exact(file, footer_digest)
        raise Error.new(ErrorCode::Corrupt, "recovery content length is invalid", path) unless footer_bytes == checkpoint.bytes
        computed_digest = digest.hexfinal
        raise Error.new(ErrorCode::Corrupt, "recovery checksum mismatch", path) unless computed_digest == String.new(footer_digest) && computed_digest == checkpoint.digest
      ensure
        file.close unless file.closed?
      end
    rescue ex : Error
      raise ex
    rescue ex
      raise Error.new(ErrorCode::Corrupt, "failed to stream recovery frame: #{ex.message}", path)
    end

    private def frame_header_bytes(checkpoint : Checkpoint) : Int64
      checkpoint.content_offset
    end

    private def session_storage_bytes(session_path : Path, recovered_path : Path) : Int64
      total = 0_i64
      [session_path, recovered_path].each do |directory|
        next unless private_directory?(directory)
        names, limited = bounded_children(directory, MAX_SNAPSHOTS_PER_SESSION + MAX_RECOVERED_COPIES_PER_SESSION + 16)
        return MAX_SESSION_BYTES + 1 if limited
        names.each do |name|
          next if name == "." || name == ".."
          path = directory / name
          info = File.info?(path, follow_symlinks: false)
          next unless info && info.file? && !info.symlink?
          total += info.size
          return MAX_SESSION_BYTES + 1 if total > MAX_SESSION_BYTES
        end
      end
      total
    rescue Error
      MAX_SESSION_BYTES + 1
    rescue
      MAX_SESSION_BYTES + 1
    end

    private def same_checkpoint?(left : Checkpoint, right : Checkpoint) : Bool
      left.session_id == right.session_id &&
        left.file_name == right.file_name &&
        left.source_path == right.source_path &&
        left.project == right.project &&
        left.version == right.version &&
        left.modified == right.modified &&
        left.bytes == right.bytes &&
        left.digest == right.digest &&
        left.captured_at == right.captured_at
    end

    private def safe_recovery_basename(source : Path) : String
      raw = source.basename
      raw = "buffer" if raw.empty? || raw == "." || raw == ".." || raw == "/"
      sanitized = raw.gsub(/[^A-Za-z0-9._-]/, "_")
      sanitized = "buffer" if sanitized.empty? || sanitized == "." || sanitized == ".."
      # Keep the original extension when a hostile basename contains unusual
      # characters; sanitizing does not introduce path separators.
      sanitized[0, 128]
    end

    private def fsync_directory(path : Path) : Nil
      directory = File.open(path.to_s, "r")
      begin
        directory.fsync
      rescue
        # Some filesystems/platforms reject fsync on directories.  The frame
        # itself was already fsynced; durability remains best effort there.
      ensure
        directory.close unless directory.closed?
      end
    rescue
      nil
    end

    private def snapshot_name_count(entries : Array(Checkpoint)) : Int32
      entries.size
    end

    private def write_u32(io : IO, value : Int64) : Nil
      bytes = Bytes.new(4)
      bytes[0] = ((value >> 24) & 0xff).to_u8
      bytes[1] = ((value >> 16) & 0xff).to_u8
      bytes[2] = ((value >> 8) & 0xff).to_u8
      bytes[3] = (value & 0xff).to_u8
      io.write(bytes)
    end

    private def write_u64(io : IO, value : Int64) : Nil
      bytes = Bytes.new(8)
      8.times do |index|
        shift = (7 - index) * 8
        bytes[index] = ((value >> shift) & 0xff).to_u8
      end
      io.write(bytes)
    end

    private def read_u32(io : IO) : Int64
      bytes = Bytes.new(4)
      raise Error.new(ErrorCode::Corrupt, "recovery frame integer is truncated") unless read_exact(io, bytes)
      ((bytes[0].to_i64 << 24) | (bytes[1].to_i64 << 16) | (bytes[2].to_i64 << 8) | bytes[3].to_i64)
    end

    private def read_u64(io : IO) : Int64
      bytes = Bytes.new(8)
      raise Error.new(ErrorCode::Corrupt, "recovery frame integer is truncated") unless read_exact(io, bytes)
      value = 0_i64
      bytes.each { |byte| value = (value << 8) | byte.to_i64 }
      value
    end

    private def write_trailer(io : IO, content_bytes : Int64, digest : String) : Nil
      io.write(FRAME_TRAILER_MAGIC.to_slice)
      write_u64(io, content_bytes)
      io.write(digest.to_slice)
    end

    private def read_exact(io : IO, bytes : Bytes) : Bool
      offset = 0
      while offset < bytes.size
        count = io.read(bytes[offset, bytes.size - offset])
        return false if count <= 0
        offset += count
      end
      true
    end
  end
end
