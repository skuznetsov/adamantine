require "spec"
require "file_utils"

require "../src/adamantine/debug_source_resolver"
require "../src/adamantine/debug_source_store"

private def with_debug_source_workspace(&)
  root = Path.new(Dir.tempdir) / "debug-source-#{Random::Secure.hex(8)}"
  Dir.mkdir_p(root)
  root = Path.new(File.realpath(root.to_s))
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe Adamantine::Debugging::DebugSourceResolver do
  it "uses explicit longest-prefix maps with component boundaries and rejects ambiguity" do
    with_debug_source_workspace do |root|
      project = root / "project"
      nested = project / "nested"
      Dir.mkdir_p(nested)
      File.write(project / "same.cr", "project")
      File.write(nested / "same.cr", "nested")
      maps = [
        Adamantine::Debugging::DebugSourceMap.new("/build", File.realpath(project)),
        Adamantine::Debugging::DebugSourceMap.new("/build/generated", File.realpath(nested)),
      ]
      resolver = Adamantine::Debugging::DebugSourceResolver.new(project, maps, "session-a")
      mapped = resolver.resolve(adapter_path: "/build/generated/same.cr")
      raise "longest mapping should win" unless mapped.local_path == File.realpath(nested / "same.cr")
      direct_project = resolver.resolve(adapter_path: (project / "same.cr").to_s)
      direct_nested = resolver.resolve(adapter_path: (nested / "same.cr").to_s)
      raise "same-basename files must retain distinct canonical identities" unless direct_project.source_key != direct_nested.source_key
      boundary = resolver.resolve(adapter_path: "/builder/same.cr")
      raise "a basename or partial prefix must not match" unless boundary.unavailable?
      raise "relative basename must not be guessed" unless resolver.resolve(adapter_path: "same.cr").unavailable?

      ambiguous = Adamantine::Debugging::DebugSourceResolver.new(project, [
        Adamantine::Debugging::DebugSourceMap.new("/build/src", File.realpath(project)),
        Adamantine::Debugging::DebugSourceMap.new("/build/src", File.realpath(nested)),
      ], "session-a").resolve(adapter_path: "/build/src/same.cr")
      raise "equal-specificity mappings to different roots must fail closed" unless ambiguous.unavailable? && ambiguous.reason.not_nil!.includes?("ambiguous")
    end
  end

  it "keeps source references session-scoped and checks only implemented local checksums" do
    with_debug_source_workspace do |root|
      project = root / "project"
      Dir.mkdir(project)
      local_file = project / "checksum.cr"
      File.write(local_file, "a😀b")
      resolver = Adamantine::Debugging::DebugSourceResolver.new(project, [] of Adamantine::Debugging::DebugSourceMap, "session-a")
      reference = resolver.resolve(source_reference: 7)
      raise "source reference should remain a distinct identity" unless reference.source_key == Adamantine::Debugging::DebugSourceKey.session("session-a", 7)
      foreign = Adamantine::Debugging::DebugSourceResolver.new(project, [] of Adamantine::Debugging::DebugSourceMap, "session-b")
      raise "reference keys must not cross sessions" if reference.source_key == foreign.resolve(source_reference: 7).source_key
      no_session = Adamantine::Debugging::DebugSourceResolver.new(project, [] of Adamantine::Debugging::DebugSourceMap)
      raise "unscoped reference must not resolve" unless no_session.resolve(source_reference: 7).unavailable?

      checksum = Adamantine::Debugging::DebugChecksum.new("SHA256", Digest::SHA256.hexdigest("a😀b"))
      checked = resolver.resolve(adapter_path: local_file.to_s, checksum: checksum, local_contents: "a😀b")
      raise "known checksum should match exact source bytes: #{checked.checksum_status}" unless checked.checksum_status == Adamantine::Debugging::ChecksumStatus::Match
      unknown = resolver.resolve(adapter_path: local_file.to_s, checksum: Adamantine::Debugging::DebugChecksum.new("future-hash", "anything"), local_contents: "a😀b")
      raise "unknown algorithm must stay unverified" unless unknown.checksum_status == Adamantine::Debugging::ChecksumStatus::Unverified
      mismatch = resolver.resolve(adapter_path: local_file.to_s, checksum: checksum, local_contents: "different")
      raise "implemented checksum mismatch should remain explicit" unless mismatch.checksum_status == Adamantine::Debugging::ChecksumStatus::Mismatch
      session_unverified = resolver.resolve(source_reference: 7, checksum: checksum, local_contents: "a😀b")
      raise "local contents must not certify a session source reference" unless session_unverified.checksum_status == Adamantine::Debugging::ChecksumStatus::Unverified
      position = resolver.to_editor_position("a😀b", 1, 4)
      raise "DAP UTF-16 column conversion mismatch" unless position.line == 0 && position.column == 2
      trailing_line = resolver.to_editor_position("first\n", 2, 1)
      raise "trailing empty source line must be addressable" unless trailing_line.line == 1 && trailing_line.column == 0
      tab_emoji = resolver.to_editor_position("\t😀\r\nsecond\r\n", 1, 4)
      raise "UTF-16 column after tab and supplementary character must map to codepoints" unless tab_emoji.line == 0 && tab_emoji.column == 2
      crlf_line = resolver.to_editor_position("\t😀\r\nsecond\r\n", 2, 1)
      raise "CRLF splitting must preserve the next line's origin" unless crlf_line.line == 1 && crlf_line.column == 0
      many_lines = "x\n" * 100_000
      last_text_line = resolver.to_editor_position(many_lines, 100_000, 2)
      raise "late line lookup mismatch" unless last_text_line.line == 99_999 && last_text_line.column == 1
      final_empty_line = resolver.to_editor_position(many_lines, 100_001, 1)
      raise "large source must retain its trailing empty line" unless final_empty_line.line == 100_000 && final_empty_line.column == 0
    end
  end

  it "prioritizes positive source references and rejects negative references" do
    with_debug_source_workspace do |root|
      project = root / "project"
      Dir.mkdir(project)
      local_file = project / "visible.cr"
      File.write(local_file, "local editable text")
      resolver = Adamantine::Debugging::DebugSourceResolver.new(
        project,
        [Adamantine::Debugging::DebugSourceMap.new("/build", File.realpath(project))],
        "session-a",
      )
      checksum = Adamantine::Debugging::DebugChecksum.new("SHA256", Digest::SHA256.hexdigest("local editable text"))

      direct = resolver.resolve(adapter_path: local_file.to_s, source_reference: 21, checksum: checksum, local_contents: "local editable text")
      raise "positive sourceReference must override an existing local path" unless direct.kind == Adamantine::Debugging::SourceResolutionKind::SessionReference
      raise "adapter source must not be exposed as an editable local path" unless direct.local_path.nil?
      raise "adapter path should be retained only as display metadata" unless direct.display_path == local_file.to_s
      raise "local file bytes must not certify adapter source contents" unless direct.checksum_status == Adamantine::Debugging::ChecksumStatus::Unverified
      raise "session reference identity was not preserved" unless direct.source_key == Adamantine::Debugging::DebugSourceKey.session("session-a", 21)

      mapped = resolver.resolve(adapter_path: "/build/visible.cr", source_reference: 22)
      raise "positive sourceReference must override a mapped path" unless mapped.kind == Adamantine::Debugging::SourceResolutionKind::SessionReference
      raise "mapped adapter path should remain display-only" unless mapped.local_path.nil? && mapped.display_path == "/build/visible.cr"
      unmappable = resolver.resolve(adapter_path: "/remote/unknown.cr", source_reference: 23)
      raise "positive sourceReference must survive an unmappable display path" unless unmappable.kind == Adamantine::Debugging::SourceResolutionKind::SessionReference
      invalid_display = resolver.resolve(adapter_path: "bad\u0000path", source_reference: 24)
      raise "unsafe adapter path metadata must not block reference identity" unless invalid_display.kind == Adamantine::Debugging::SourceResolutionKind::SessionReference && invalid_display.display_path.nil?

      zero = resolver.resolve(adapter_path: local_file.to_s, source_reference: 0)
      raise "zero sourceReference must allow ordinary local-path resolution" unless zero.kind == Adamantine::Debugging::SourceResolutionKind::LocalFile && zero.local_path == File.realpath(local_file)
      negative = resolver.resolve(adapter_path: local_file.to_s, source_reference: -1)
      raise "negative sourceReference must be rejected even when path is local" unless negative.unavailable?
      no_path_negative = resolver.resolve(source_reference: -1)
      raise "negative sourceReference must be rejected without a path" unless no_path_negative.unavailable?
    end
  end
end

describe Adamantine::Debugging::DebugSourceStore do
  it "accounts bytes without exposing mutable text and reuses same-reason outdated snapshots" do
    store = Adamantine::Debugging::DebugSourceStore.new("session-a")
    key = Adamantine::Debugging::DebugSourceKey.local("/tmp/immutable-source.cr")
    store.capture_baseline(key, "baseline")
    snapshot = store.fetch(key).not_nil!
    raise "snapshot byte count mismatch" unless snapshot.bytesize == 8
    raise "logical retention count mismatch" unless store.logical_bytes == 8

    public_text = snapshot.text
    public_text += " mutation"
    raise "public source text must not mutate retained content" unless snapshot.text == "baseline" && snapshot.bytesize == 8

    raise "source edit should mark baseline outdated" unless store.mark_outdated(key, "buffer changed")
    outdated = store.fetch(key).not_nil!
    raise "outdated source text or accounting changed" unless outdated.text == "baseline" && outdated.bytesize == 8 && store.logical_bytes == 8
    raise "same-reason edit should preserve the existing immutable snapshot" unless store.mark_outdated(key, "buffer changed") && store.fetch(key).not_nil!.object_id == outdated.object_id
    raise "changed reason should be reflected without mutating retained bytes" unless store.mark_outdated(key, "buffer changed again") && store.fetch(key).not_nil!.reason == "buffer changed again" && store.fetch(key).not_nil!.text == "baseline"
  end

  it "owns immutable source text, enforces logical retention, and reports eviction" do
    store = Adamantine::Debugging::DebugSourceStore.new("session-a")
    first = Adamantine::Debugging::DebugSourceKey.local("/tmp/source-one.cr")
    captured = store.capture_baseline(first, "one")
    raise "baseline should be retained" unless captured.retained?
    leaked = store.fetch(first).not_nil!.text
    raise "snapshot text getter mismatch" unless leaked == "one" && store.fetch(first).not_nil!.text == "one"
    raise "source key was not pinned" unless store.pin(first)

    oversized_key = Adamantine::Debugging::DebugSourceKey.local("/tmp/too-large.cr")
    oversized = store.capture_baseline(oversized_key, "x" * (Adamantine::Debugging::DebugSourceStore::MAX_LOGICAL_BYTES + 1))
    raise "one source over logical budget must not be retained" unless !oversized.retained? && oversized.reason.not_nil!.includes?("limit")
    rejected_refresh = store.capture_baseline(first, "x" * (Adamantine::Debugging::DebugSourceStore::MAX_LOGICAL_BYTES + 1))
    stale = store.fetch(first).not_nil!
    raise "failed refresh must expose old text as outdated" unless !rejected_refresh.retained? && stale.outdated? && stale.reason.not_nil!.includes?("limit")

    (1..Adamantine::Debugging::DebugSourceStore::MAX_RETAINED_ROOTS).each do |index|
      store.capture_baseline(Adamantine::Debugging::DebugSourceKey.local("/tmp/source-#{index}.cr"), "x")
    end
    raise "pinned root should survive eviction pressure" unless store.fetch(first)
    raise "retained roots exceeded cap" if store.retained_count > Adamantine::Debugging::DebugSourceStore::MAX_RETAINED_ROOTS
    store.unpin(first)
    store.capture_baseline(Adamantine::Debugging::DebugSourceKey.local("/tmp/source-final.cr"), "x")
    raise "unpinned oldest root should be evicted at the cap" unless store.fetch(first).nil? && store.unavailable_reason(first).not_nil!.includes?("evict")
  end

  it "marks source edits outdated instead of presenting a baseline as compiled truth" do
    store = Adamantine::Debugging::DebugSourceStore.new("session-a")
    key = Adamantine::Debugging::DebugSourceKey.local("/tmp/source.cr")
    store.capture_baseline(key, "baseline")
    raise "baseline must be unverified" unless store.fetch(key).not_nil!.checksum_status == Adamantine::Debugging::ChecksumStatus::Unverified
    checksum = Adamantine::Debugging::DebugChecksum.new("SHA256", Digest::SHA256.hexdigest("baseline"))
    store.capture_baseline(key, "baseline", checksum: checksum)
    raise "matching checksum should be typed evidence, not a baseline claim" unless store.fetch(key).not_nil!.checksum_status == Adamantine::Debugging::ChecksumStatus::Match && store.fetch(key).not_nil!.origin == Adamantine::Debugging::SourceOrigin::LaunchBaseline
    raise "edit should update freshness" unless store.mark_outdated(key, "buffer changed")
    snapshot = store.fetch(key).not_nil!
    raise "edited source must be outdated" unless snapshot.outdated? && snapshot.reason.not_nil!.includes?("buffer changed")
  end

  it "enforces the aggregate logical-byte budget without evicting pinned roots" do
    store = Adamantine::Debugging::DebugSourceStore.new("session-a")
    first = Adamantine::Debugging::DebugSourceKey.local("/tmp/large-one.cr")
    second = Adamantine::Debugging::DebugSourceKey.local("/tmp/large-two.cr")
    block = "x" * (20 * 1024 * 1024)
    store.capture_baseline(first, block, pin: true)
    rejected = store.capture_baseline(second, block)
    raise "pinned roots should not be evicted to meet byte cap" unless !rejected.retained? && store.fetch(first) && store.fetch(second).nil?
    raise "logical bytes exceeded cap after rejection" if store.logical_bytes > Adamantine::Debugging::DebugSourceStore::MAX_LOGICAL_BYTES
    store.unpin(first)
    accepted = store.capture_baseline(second, block)
    raise "unpinned root should be evictable under byte pressure" unless accepted.retained? && store.fetch(first).nil? && store.fetch(second)
    raise "logical bytes exceeded cap after eviction" if store.logical_bytes > Adamantine::Debugging::DebugSourceStore::MAX_LOGICAL_BYTES
  end

  it "preserves an explicit pin when replacing the same retained source" do
    store = Adamantine::Debugging::DebugSourceStore.new("session-a")
    key = Adamantine::Debugging::DebugSourceKey.local("/tmp/pinned-source.cr")
    store.capture_baseline(key, "old", pin: true)
    store.capture_baseline(key, "replacement")
    (1..Adamantine::Debugging::DebugSourceStore::MAX_RETAINED_ROOTS).each do |index|
      store.capture_baseline(Adamantine::Debugging::DebugSourceKey.local("/tmp/pin-pressure-#{index}.cr"), "x")
    end
    raise "replacement must not silently unpin a retained source" unless store.fetch(key)
    raise "pinned replacement must remain within root cap" if store.retained_count > Adamantine::Debugging::DebugSourceStore::MAX_RETAINED_ROOTS
  end
end
