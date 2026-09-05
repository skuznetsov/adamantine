require "digest/sha256"

module Adamantine
  # A content revision and the filesystem observation which produced it.
  #
  # `FileRevision.probe` only performs metadata work. `capture` streams a
  # digest without retaining the file contents, while `read` additionally
  # returns the bytes for callers which explicitly need a reload snapshot.
  struct FileRevision
    DEFAULT_CHUNK_SIZE = 64 * 1024

    enum Status
      Stable
      Missing
      Unreadable
      NonRegular
      TooLarge
      Unstable
    end

    # The inexpensive metadata observation used to decide whether a digest
    # pass is needed. `target_identity` is the canonical target path; the
    # private File::Info values retain device/inode identity for comparisons,
    # which catches same-size atomic replacement even when timestamps collide.
    struct Stamp
      getter exists : Bool
      getter type : File::Type?
      getter target_type : File::Type?
      getter size : Int64
      getter modification_time : Time?
      getter resolved_target : String?
      getter target_identity : String?
      getter status : Status
      getter error : String?

      @path_info : File::Info?
      @target_info : File::Info?

      def initialize(
        @exists : Bool,
        @type : File::Type?,
        @target_type : File::Type?,
        @size : Int64,
        @modification_time : Time?,
        @resolved_target : String?,
        @target_identity : String?,
        @status : Status,
        @path_info : File::Info? = nil,
        @target_info : File::Info? = nil,
        @error : String? = nil,
      )
      end

      def exists? : Bool
        @exists
      end

      def missing? : Bool
        @status == Status::Missing
      end

      def unreadable? : Bool
        @status == Status::Unreadable
      end

      def regular? : Bool
        @status == Status::Stable
      end

      def stable? : Bool
        regular?
      end

      def non_regular? : Bool
        @status == Status::NonRegular
      end

      def symlink? : Bool
        @type == File::Type::Symlink
      end

      def directory? : Bool
        @target_type == File::Type::Directory
      end

      def same_as?(other : Stamp) : Bool
        @exists == other.exists &&
          @type == other.type &&
          @target_type == other.target_type &&
          @size == other.size &&
          @modification_time == other.modification_time &&
          @resolved_target == other.resolved_target &&
          same_file_info?(@path_info, other.path_info) &&
          same_file_info?(@target_info, other.target_info) &&
          @status == other.status
      end

      def identity_changed?(other : Stamp) : Bool
        return true unless @type == other.type && @target_type == other.target_type
        return true unless @resolved_target == other.resolved_target
        return true unless same_file_info?(@path_info, other.path_info)
        return true unless same_file_info?(@target_info, other.target_info)
        false
      end

      def symlink_target_changed?(other : Stamp) : Bool
        return false unless symlink? && other.symlink?
        @resolved_target != other.resolved_target
      end

      # Used by the streaming reader to make sure the descriptor opened the
      # same target observed by the path probe.
      def target_matches?(info : File::Info) : Bool
        same_file_info?(@target_info, info)
      end

      # Exposed as a read-only comparison primitive for callers which need to
      # retain a stamp but do not need access to File::Info internals.
      def same_target?(other : Stamp) : Bool
        @resolved_target == other.resolved_target && same_file_info?(@target_info, other.target_info)
      end

      protected getter path_info : File::Info?
      protected getter target_info : File::Info?

      private def same_file_info?(left : File::Info?, right : File::Info?) : Bool
        return true if left.nil? && right.nil?
        return false if left.nil? || right.nil?
        left.not_nil!.same_file?(right.not_nil!)
      end
    end

    # A result from either a digest-only capture or an exact content snapshot.
    # Non-stable results deliberately carry no content or revision.
    struct Result
      getter path : Path
      getter status : Status
      getter content : String?
      getter revision : FileRevision?
      getter stamp_before : Stamp
      getter stamp_after : Stamp?
      getter error : String?

      def initialize(
        @path : Path,
        @status : Status,
        @content : String?,
        @revision : FileRevision?,
        @stamp_before : Stamp,
        @stamp_after : Stamp? = nil,
        @error : String? = nil,
      )
      end

      def stable? : Bool
        @status == Status::Stable && !@revision.nil?
      end

      def missing? : Bool
        @status == Status::Missing
      end

      def unreadable? : Bool
        @status == Status::Unreadable
      end

      def non_regular? : Bool
        @status == Status::NonRegular
      end

      def too_large? : Bool
        @status == Status::TooLarge
      end

      def unstable? : Bool
        @status == Status::Unstable
      end

      def digest : String?
        @revision.try(&.digest)
      end

      # The best current stamp is useful for a monitor baseline even when the
      # read was rejected as too large or unreadable.
      def stamp : Stamp
        @stamp_after || @stamp_before
      end
    end

    getter path : Path
    getter stamp : Stamp
    getter digest : String

    def initialize(@path : Path, @stamp : Stamp, @digest : String)
    end

    def same_content?(other : FileRevision) : Bool
      @digest == other.digest
    end

    # Cheap metadata-only observation. No file bytes are opened or hashed.
    def self.probe(path : Path | String) : Stamp
      normalized = begin
        normalize_path(path)
      rescue ex
        return Stamp.new(
          false,
          nil,
          nil,
          0_i64,
          nil,
          nil,
          nil,
          Status::Unreadable,
          nil,
          nil,
          error_message(ex),
        )
      end

      path_info = begin
        File.info?(normalized, follow_symlinks: false)
      rescue ex
        return Stamp.new(
          false,
          nil,
          nil,
          0_i64,
          nil,
          nil,
          nil,
          Status::Unreadable,
          nil,
          nil,
          error_message(ex),
        )
      end

      unless path_info
        return Stamp.new(false, nil, nil, 0_i64, nil, nil, nil, Status::Missing)
      end

      path_type = path_info.not_nil!.type
      resolved_target = begin
        File.realpath(normalized)
      rescue ex : File::NotFoundError
        return Stamp.new(
          true,
          path_type,
          nil,
          path_info.not_nil!.size,
          path_info.not_nil!.modification_time,
          nil,
          nil,
          Status::Missing,
          path_info,
          nil,
          error_message(ex),
        )
      rescue ex
        return Stamp.new(
          true,
          path_type,
          nil,
          path_info.not_nil!.size,
          path_info.not_nil!.modification_time,
          nil,
          nil,
          Status::Unreadable,
          path_info,
          nil,
          error_message(ex),
        )
      end

      target_info = begin
        File.info(resolved_target)
      rescue ex : File::NotFoundError
        return Stamp.new(
          true,
          path_type,
          nil,
          path_info.not_nil!.size,
          path_info.not_nil!.modification_time,
          resolved_target,
          resolved_target,
          Status::Missing,
          path_info,
          nil,
          error_message(ex),
        )
      rescue ex
        return Stamp.new(
          true,
          path_type,
          nil,
          path_info.not_nil!.size,
          path_info.not_nil!.modification_time,
          resolved_target,
          resolved_target,
          Status::Unreadable,
          path_info,
          nil,
          error_message(ex),
        )
      end

      target_type = target_info.not_nil!.type
      status = if target_type.file?
                 if File::Info.readable?(resolved_target)
                   Status::Stable
                 else
                   Status::Unreadable
                 end
               else
                 Status::NonRegular
               end

      Stamp.new(
        true,
        path_type,
        target_type,
        # Size and mtime gate the bytes which will be read. For a symlink they
        # must describe the resolved target, not the link entry itself.
        target_info.not_nil!.size,
        target_info.not_nil!.modification_time,
        resolved_target,
        resolved_target,
        status,
        path_info,
        target_info,
      )
    end

    # Reads and validates one exact external snapshot. The bytes are retained
    # only because this API is explicitly for reload/initial-load callers.
    def self.read(
      path : Path | String,
      *,
      max_bytes : Int64? = nil,
      chunk_size : Int32 = DEFAULT_CHUNK_SIZE,
      stamp : Stamp? = nil,
      expected_stamp : Stamp? = nil,
    ) : Result
      stream(
        path,
        max_bytes: max_bytes,
        chunk_size: chunk_size,
        expected_stamp: expected_stamp || stamp,
        collect_content: true,
      )
    end

    # Digest-only capture used by the monitor. It never materializes the full
    # file contents and yields after every bounded read.
    def self.capture(
      path : Path | String,
      *,
      max_bytes : Int64? = nil,
      chunk_size : Int32 = DEFAULT_CHUNK_SIZE,
      stamp : Stamp? = nil,
      expected_stamp : Stamp? = nil,
    ) : Result
      stream(
        path,
        max_bytes: max_bytes,
        chunk_size: chunk_size,
        expected_stamp: expected_stamp || stamp,
        collect_content: false,
      )
    end

    private def self.stream(
      path : Path | String,
      *,
      max_bytes : Int64?,
      chunk_size : Int32,
      expected_stamp : Stamp?,
      collect_content : Bool,
    ) : Result
      raise ArgumentError.new("chunk_size must be positive") unless chunk_size > 0
      if limit = max_bytes
        raise ArgumentError.new("max_bytes must not be negative") if limit < 0
      end

      normalized = normalize_path(path)
      stamp_before = expected_stamp || probe(normalized)

      # If a caller supplied an observation which is already stale, do not
      # open a potentially different target and call it an exact snapshot.
      if expected_stamp
        current = probe(normalized)
        unless expected_stamp.not_nil!.same_as?(current)
          return Result.new(normalized, Status::Unstable, nil, nil, stamp_before, current)
        end
      end

      unless stamp_before.regular?
        return Result.new(normalized, stamp_before.status, nil, nil, stamp_before)
      end

      if limit = max_bytes
        if stamp_before.size > limit
          return Result.new(normalized, Status::TooLarge, nil, nil, stamp_before)
        end
      end

      begin
        File.open(normalized, "rb") do |file|
          opened_info = file.info
          unless stamp_before.target_matches?(opened_info)
            current = probe(normalized)
            return Result.new(normalized, Status::Unstable, nil, nil, stamp_before, current)
          end

          digest = Digest::SHA256.new
          content_io = collect_content ? IO::Memory.new : nil
          buffer = Bytes.new(chunk_size)
          total = 0_i64

          loop do
            read_bytes = file.read(buffer)
            break if read_bytes == 0

            if limit = max_bytes
              if total > limit || read_bytes.to_i64 > limit - total
                current = probe(normalized)
                return Result.new(normalized, Status::TooLarge, nil, nil, stamp_before, current)
              end
            end

            slice = buffer[0, read_bytes]
            digest.update(slice)
            content_io.try(&.write(slice))
            total += read_bytes
            Fiber.yield
          end

          stamp_after = probe(normalized)
          if limit = max_bytes
            if stamp_after.size > limit && stamp_after.regular?
              return Result.new(normalized, Status::TooLarge, nil, nil, stamp_before, stamp_after)
            end
          end

          unless stamp_before.same_as?(stamp_after) && stamp_after.target_matches?(opened_info)
            return Result.new(normalized, Status::Unstable, nil, nil, stamp_before, stamp_after)
          end

          revision = new(normalized, stamp_after, digest.hexfinal)
          content = content_io.try(&.to_s)
          return Result.new(normalized, Status::Stable, content, revision, stamp_before, stamp_after)
        end
      rescue ex : File::NotFoundError
        current = probe(normalized)
        status = current.missing? ? Status::Missing : Status::Unstable
        return Result.new(normalized, status, nil, nil, stamp_before, current, error_message(ex))
      rescue ex
        current = probe(normalized)
        status = if current.unreadable?
                   Status::Unreadable
                 elsif current.non_regular?
                   Status::NonRegular
                 elsif current.missing?
                   Status::Missing
                 elsif current.same_as?(stamp_before)
                   # The path remained the same regular file, but opening or
                   # reading it failed (for example, an access denial that a
                   # metadata-only permission probe did not predict).
                   Status::Unreadable
                 else
                   Status::Unstable
                 end
        return Result.new(normalized, status, nil, nil, stamp_before, current, error_message(ex))
      end
    end

    private def self.normalize_path(path : Path | String) : Path
      path.is_a?(Path) ? path : Path.new(path)
    end

    private def self.error_message(ex : Exception) : String
      ex.message || ex.class.to_s
    end
  end
end
