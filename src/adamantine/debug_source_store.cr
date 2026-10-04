require "digest/sha256"
require "set"

module Adamantine::Debugging
  enum SourceKeyKind
    Local
    SessionReference
  end

  # Local paths and adapter-owned source references are deliberately distinct
  # identities; neither can be constructed by coercing the other.
  class DebugSourceKey
    getter kind : SourceKeyKind
    @local_path : String?
    @session_id : String?
    @source_reference : Int32?

    private def initialize(@kind : SourceKeyKind, @local_path : String?, @session_id : String?, @source_reference : Int32?)
    end

    def self.local(path : Path | String) : DebugSourceKey
      raw = Path.new(path.to_s)
      raise ArgumentError.new("local source path must be absolute") unless raw.absolute?
      expanded = raw.expand
      canonical = if File.exists?(expanded.to_s)
                    Path.new(File.realpath(expanded.to_s)).to_s
                  else
                    expanded.to_s
                  end
      new(SourceKeyKind::Local, canonical, nil, nil)
    end

    def self.session(session_id : String, source_reference : Int32) : DebugSourceKey
      raise ArgumentError.new("session id is empty") if session_id.empty? || session_id.bytesize > 256
      raise ArgumentError.new("source reference must be positive") unless source_reference > 0
      new(SourceKeyKind::SessionReference, nil, session_id.dup, source_reference)
    end

    def local_path : String?
      @local_path.try(&.dup)
    end

    def session_id : String?
      @session_id.try(&.dup)
    end

    def source_reference : Int32?
      @source_reference
    end

    def ==(other : DebugSourceKey) : Bool
      @kind == other.@kind && @local_path == other.@local_path && @session_id == other.@session_id && @source_reference == other.@source_reference
    end

    def hash(hasher)
      {@kind, @local_path, @session_id, @source_reference}.hash(hasher)
    end

    def to_s : String
      if path = @local_path
        "local:#{path}"
      else
        "session:#{@session_id}:#{@source_reference}"
      end
    end
  end

  enum ChecksumStatus
    Unverified
    Match
    Mismatch
  end

  struct DebugChecksum
    @algorithm : String
    @value : String

    def initialize(algorithm : String, value : String)
      raise ArgumentError.new("checksum fields exceed limit") if algorithm.bytesize > 64 || value.bytesize > 256
      @algorithm = algorithm.dup
      @value = value.dup
    end

    def algorithm : String
      @algorithm.dup
    end

    def value : String
      @value.dup
    end

    def compare(contents : String) : ChecksumStatus
      return ChecksumStatus::Unverified unless contents.valid_encoding? && @algorithm == "SHA256"
      valid_hex = @value.bytesize == 64
      @value.each_char do |char|
        codepoint = char.ord
        valid_hex = false unless (codepoint >= 0x30 && codepoint <= 0x39) ||
                                 (codepoint >= 0x61 && codepoint <= 0x66) ||
                                 (codepoint >= 0x41 && codepoint <= 0x46)
      end
      return ChecksumStatus::Unverified unless valid_hex
      Digest::SHA256.hexdigest(contents).downcase == @value.downcase ? ChecksumStatus::Match : ChecksumStatus::Mismatch
    end
  end

  enum SourceOrigin
    LaunchBaseline
    AdapterSource
    SessionReference
  end

  class DebugSourceSnapshot
    getter key : DebugSourceKey
    getter origin : SourceOrigin
    getter checksum_status : ChecksumStatus
    @text : String
    @outdated : Bool
    @reason : String?

    def initialize(@key : DebugSourceKey, text : String, @origin : SourceOrigin,
                   @checksum_status : ChecksumStatus = ChecksumStatus::Unverified,
                   @outdated : Bool = false, reason : String? = nil)
      @text = text.dup
      @reason = reason.try(&.dup)
    end

    def text : String
      @text.dup
    end

    # Logical byte accounting without copying the retained source text.
    def bytesize : Int32
      @text.bytesize
    end

    def outdated? : Bool
      @outdated
    end

    def reason : String?
      @reason.try(&.dup)
    end

    def with_outdated(reason : String) : DebugSourceSnapshot
      return self if @outdated && @reason == reason
      DebugSourceSnapshot.new(@key, @text, @origin, @checksum_status, true, reason)
    end
  end

  struct DebugSourceCaptureResult
    @snapshot : DebugSourceSnapshot?
    @reason : String?

    def initialize(@snapshot : DebugSourceSnapshot?, reason : String? = nil)
      @reason = reason.try(&.dup)
    end

    def retained? : Bool
      !@snapshot.nil?
    end

    def snapshot : DebugSourceSnapshot?
      @snapshot
    end

    def reason : String?
      @reason.try(&.dup)
    end
  end

  # In-memory, guard-only source snapshot retention. Construction performs no
  # I/O. Callers explicitly provide captured contents at the source boundary.
  class DebugSourceStore
    MAX_RETAINED_ROOTS = 32
    MAX_LOGICAL_BYTES  = 32 * 1024 * 1024
    MAX_REASONS        = 32

    private class Entry
      property snapshot : DebugSourceSnapshot
      property pinned : Bool
      property ordinal : UInt64

      def initialize(@snapshot : DebugSourceSnapshot, @pinned : Bool, @ordinal : UInt64)
      end
    end

    @session_id : String
    @entries : Hash(DebugSourceKey, Entry)
    @unavailable : Hash(DebugSourceKey, String)
    @unavailable_order : Array(DebugSourceKey)
    @ordinal : UInt64
    @logical_bytes : Int64

    def initialize(session_id : String)
      raise ArgumentError.new("session id is empty") if session_id.empty? || session_id.bytesize > 256
      @session_id = session_id.dup
      @entries = {} of DebugSourceKey => Entry
      @unavailable = {} of DebugSourceKey => String
      @unavailable_order = [] of DebugSourceKey
      @ordinal = 0_u64
      @logical_bytes = 0_i64
    end

    def capture_baseline(key : DebugSourceKey, text : String, *, pin : Bool = false,
                         checksum : DebugChecksum? = nil) : DebugSourceCaptureResult
      return unavailable(key, "launch baselines require a local source identity") unless key.kind == SourceKeyKind::Local
      capture(key, text, SourceOrigin::LaunchBaseline, pin, checksum)
    end

    def capture_adapter_source(key : DebugSourceKey, text : String, *, pin : Bool = false,
                               checksum : DebugChecksum? = nil) : DebugSourceCaptureResult
      origin = key.kind == SourceKeyKind::SessionReference ? SourceOrigin::SessionReference : SourceOrigin::AdapterSource
      capture(key, text, origin, pin, checksum)
    end

    def fetch(key : DebugSourceKey) : DebugSourceSnapshot?
      @entries[key]?.try(&.snapshot)
    end

    def pin(key : DebugSourceKey) : Bool
      entry = @entries[key]?
      return false unless entry
      entry.not_nil!.pinned = true
      true
    end

    def unpin(key : DebugSourceKey) : Bool
      entry = @entries[key]?
      return false unless entry
      entry.not_nil!.pinned = false
      true
    end

    def mark_outdated(key : DebugSourceKey, reason : String) : Bool
      entry = @entries[key]?
      return false unless entry
      bounded = bounded_reason(reason)
      entry.not_nil!.snapshot = entry.not_nil!.snapshot.with_outdated(bounded)
      true
    end

    def unavailable_reason(key : DebugSourceKey) : String?
      @unavailable[key]?.try(&.dup) || (@entries.has_key?(key) ? nil : "source snapshot is not retained")
    end

    def retained_count : Int32
      @entries.size
    end

    def logical_bytes : Int64
      @logical_bytes
    end

    def retained_keys : Array(DebugSourceKey)
      @entries.keys
    end

    private def capture(key : DebugSourceKey, text : String, origin : SourceOrigin, pin : Bool,
                        checksum : DebugChecksum?) : DebugSourceCaptureResult
      if session = key.session_id
        return unavailable(key, "source reference belongs to another session") unless session == @session_id
      end
      return unavailable(key, "source text is not valid UTF-8") unless text.valid_encoding?
      return unavailable(key, "source exceeds logical retention limit") if text.bytesize > MAX_LOGICAL_BYTES

      old = @entries[key]?
      old_bytes = old ? old.not_nil!.snapshot.bytesize.to_i64 : 0_i64
      retained_pin = pin || (old ? old.not_nil!.pinned : false)
      projected = @logical_bytes - old_bytes + text.bytesize
      victim_candidates = @entries.select { |candidate, entry| candidate != key && !entry.pinned }
        .to_a
        .sort_by { |pair| pair[1].ordinal }
      victims = [] of DebugSourceKey
      projected_roots = @entries.size + (old ? 0 : 1)
      until projected <= MAX_LOGICAL_BYTES && projected_roots <= MAX_RETAINED_ROOTS
        victim_pair = victim_candidates.shift?
        return unavailable(key, "all retained source roots are pinned at the retention limit") unless victim_pair
        victim_key, victim_entry = victim_pair.not_nil!
        victims << victim_key
        projected -= victim_entry.snapshot.bytesize
        projected_roots -= 1
      end

      victims.each { |victim| evict(victim) }
      @logical_bytes -= old_bytes
      @ordinal += 1
      checksum_status = checksum ? checksum.not_nil!.compare(text) : ChecksumStatus::Unverified
      snapshot = DebugSourceSnapshot.new(key, text, origin, checksum_status)
      @entries[key] = Entry.new(snapshot, retained_pin, @ordinal)
      @logical_bytes += text.bytesize
      @unavailable.delete(key)
      @unavailable_order.delete(key)
      DebugSourceCaptureResult.new(snapshot)
    rescue
      unavailable(key, "source snapshot was not retained")
    end

    private def evict(key : DebugSourceKey) : Nil
      if entry = @entries.delete(key)
        @logical_bytes -= entry.snapshot.bytesize
        remember_unavailable(key, "source snapshot evicted to honor retention limits")
      end
    end

    private def unavailable(key : DebugSourceKey, reason : String) : DebugSourceCaptureResult
      bounded = bounded_reason(reason)
      if entry = @entries[key]?
        entry.snapshot = entry.snapshot.with_outdated(bounded)
      end
      remember_unavailable(key, bounded)
      DebugSourceCaptureResult.new(nil, bounded)
    end

    private def remember_unavailable(key : DebugSourceKey, reason : String) : Nil
      @unavailable[key] = bounded_reason(reason)
      @unavailable_order.delete(key)
      @unavailable_order << key
      while @unavailable_order.size > MAX_REASONS
        expired = @unavailable_order.shift
        @unavailable.delete(expired)
      end
    end

    private def bounded_reason(reason : String) : String
      output = String.build do |builder|
        bytes = 0
        reason.each_char do |char|
          break if bytes + char.bytesize > 256
          builder << char if char.ord >= 0x20 && char.ord != 0x7f
          bytes += char.bytesize
        end
      end
      output.empty? ? "source is unavailable" : output
    end
  end
end
