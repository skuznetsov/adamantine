require "spec"
require "file_utils"

require "../src/adamantine/recovery_store"

private def with_recovery_workspace(prefix : String = "adamantine-recovery-store-spec", &)
  tmp_parent = Path.new(File.realpath(Dir.tempdir))
  tmp_dir = tmp_parent / "#{prefix}-#{Random::Secure.hex(8)}"
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::RecoveryStore do
  it "reads checkpoint content without creating a recovered copy or mutating state" do
    with_recovery_workspace do |root|
      project = Path.new(root, "project")
      Dir.mkdir_p(project.to_s)
      source = Path.new(project, "preview.txt")
      File.write(source, "saved on disk\n")
      store = Adamantine::RecoveryStore.new(root: root, project: project)
      session = store.open_session
      session.write_snapshot(source_path: source, version: 4_i64) do |io|
        io.write("checkpoint draft\n".to_slice)
      end
      session.close

      reopened = Adamantine::RecoveryStore.new(root: root, project: project)
      candidate = reopened.candidates.first
      frame_before = File.read(candidate.path)
      source_before = File.read(source)
      recovered_session = root / "recovered" / candidate.session_id

      content = reopened.read_checkpoint_content(candidate)

      raise "preview content mismatch" unless content == "checkpoint draft\n"
      raise "preview must not mutate the checkpoint frame" unless File.read(candidate.path) == frame_before
      raise "preview must not read or mutate the source" unless File.read(source) == source_before
      raise "preview must not create a recovered-copy directory" if File.exists?(recovered_session)
    ensure
      reopened.try(&.close)
      store.try(&.close)
    end
  end

  it "rejects checkpoint replacement and content corruption during read" do
    with_recovery_workspace do |root|
      project = Path.new(root, "project")
      Dir.mkdir_p(project.to_s)
      source = Path.new(project, "replacement.txt")
      original = Adamantine::RecoveryStore.new(root: root, project: project)
      original_session = original.open_session
      original_session.write_snapshot(source_path: source, version: 1_i64) do |io|
        io.write("original draft\n".to_slice)
      end
      original_session.close

      view = Adamantine::RecoveryStore.new(root: root, project: project)
      candidate = view.candidates.first
      replacement = Adamantine::RecoveryStore.new(root: root, project: project)
      replacement_session = replacement.open_session
      replacement_checkpoint = replacement_session.write_snapshot(source_path: source, version: 2_i64) do |io|
        io.write("replacement draft\n".to_slice)
      end
      replacement_session.close
      File.copy(replacement_checkpoint.path.to_s, candidate.path.to_s)

      stale_error : Adamantine::RecoveryStore::Error? = nil
      begin
        view.read_checkpoint_content(candidate)
      rescue ex : Adamantine::RecoveryStore::Error
        stale_error = ex
      end
      raise "replacement must be rejected" unless stale_error && stale_error.not_nil!.code == Adamantine::RecoveryStore::ErrorCode::Stale
    ensure
      replacement.try(&.close)
      view.try(&.close)
      original.try(&.close)
    end
  end

  it "rejects a missing or corrupt checkpoint during read" do
    with_recovery_workspace do |root|
      project = Path.new(root, "project")
      Dir.mkdir_p(project.to_s)
      source = Path.new(project, "corrupt-preview.txt")
      store = Adamantine::RecoveryStore.new(root: root, project: project)
      session = store.open_session
      session.write_snapshot(source_path: source, version: 1_i64) do |io|
        io.write("checksum draft\n".to_slice)
      end
      session.close

      view = Adamantine::RecoveryStore.new(root: root, project: project)
      candidate = view.candidates.first
      File.delete(candidate.path.to_s)
      missing_error : Adamantine::RecoveryStore::Error? = nil
      begin
        view.read_checkpoint_content(candidate)
      rescue ex : Adamantine::RecoveryStore::Error
        missing_error = ex
      end
      raise "missing checkpoint must be rejected" unless missing_error && missing_error.not_nil!.code == Adamantine::RecoveryStore::ErrorCode::NotFound

      # Recreate an independent valid checkpoint, then corrupt its payload so
      # the frame checksum—not an identity mismatch—rejects the read.
      replacement = view.open_session
      checkpoint = replacement.write_snapshot(source_path: source, version: 2_i64) do |io|
        io.write("checksum draft\n".to_slice)
      end
      replacement.close
      corrupt_candidate = view.candidates.first
      frame = File.open(checkpoint.path.to_s, "r+")
      begin
        frame.seek(Adamantine::RecoveryStore::FRAME_MAGIC.bytesize)
        metadata_length_bytes = Bytes.new(4)
        raise "failed to read frame metadata length" unless frame.read(metadata_length_bytes) == metadata_length_bytes.size
        metadata_length = (metadata_length_bytes[0].to_i64 << 24) |
                          (metadata_length_bytes[1].to_i64 << 16) |
                          (metadata_length_bytes[2].to_i64 << 8) |
                          metadata_length_bytes[3].to_i64
        content_offset = Adamantine::RecoveryStore::FRAME_MAGIC.bytesize + 4 + metadata_length
        frame.seek(content_offset)
        original_byte = frame.read_byte
        raise "frame payload was unexpectedly empty" unless original_byte
        frame.seek(content_offset)
        frame.write(Bytes[(original_byte.not_nil! ^ 0xff_u8)])
        frame.flush
      ensure
        frame.close unless frame.closed?
      end

      corrupt_error : Adamantine::RecoveryStore::Error? = nil
      begin
        view.read_checkpoint_content(corrupt_candidate)
      rescue ex : Adamantine::RecoveryStore::Error
        corrupt_error = ex
      end
      raise "corrupt checkpoint must be rejected" unless corrupt_error && corrupt_error.not_nil!.code == Adamantine::RecoveryStore::ErrorCode::Corrupt
    ensure
      replacement.try(&.close)
      view.try(&.close)
      store.try(&.close)
    end
  end

  it "round-trips a streamed dirty buffer after its session is abandoned" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/example.cr")
      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      content = "puts \"hello\"\n"

      snapshot = session.write_snapshot(
        source_path: source,
        modified: true,
        version: 7_i64,
        freshness: -> { true },
      ) do |io|
        io.write(content[0, 5].to_slice)
        io.write(content[5..].to_slice)
      end

      raise "snapshot should report streamed byte count" unless snapshot.bytes == content.bytesize
      session.close

      reopened = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      scan = reopened.candidates
      raise "abandoned snapshot should be discoverable" unless scan.size == 1
      candidate = scan.first
      raise "candidate source path mismatch" unless candidate.source_path == source
      raise "candidate version mismatch" unless candidate.version == 7_i64

      copy = reopened.recover(candidate)
      raise "recovery copy should be private" unless copy.path.to_s.starts_with?(root.to_s)
      raise "recovery copy should preserve extension" unless copy.path.extension == ".cr"
      raise "recovery copy should not touch source" if File.exists?(source)
      raise "recovery bytes mismatch" unless File.read(copy.path) == content
    ensure
      reopened.try(&.close)
      store.try(&.close)
    end
  end

  it "hides live sessions and preserves the last frame across stale and failed writes" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/stale.cr")
      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      session.write_snapshot(source_path: source, version: 1_i64, freshness: -> { true }) do |io|
        io.write("accepted\n".to_slice)
      end

      live_view = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      raise "live session must not be listed" unless live_view.candidates.empty?

      stale = false
      stale_error : Adamantine::RecoveryStore::Error? = nil
      begin
        session.write_snapshot(source_path: source, version: 2_i64, freshness: -> { !stale }) do |io|
          io.write("stale\n".to_slice)
          stale = true
        end
      rescue ex : Adamantine::RecoveryStore::Error
        stale_error = ex
      end
      raise "stale write must fail closed" unless stale_error && stale_error.not_nil!.code == Adamantine::RecoveryStore::ErrorCode::Stale

      failed_error : Exception? = nil
      begin
        session.write_snapshot(source_path: source, version: 3_i64, freshness: -> { true }) do |io|
          io.write("partial\n".to_slice)
          raise "simulated writer failure"
        end
      rescue ex
        failed_error = ex
      end
      raise "writer failure should reach the caller" unless failed_error

      session.close
      live_view.close
      reopened = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      scan = reopened.candidates
      raise "failed or stale writes must retain one accepted frame" unless scan.size == 1
      raise "accepted version was replaced" unless scan.first.version == 1_i64
      copy = reopened.recover(scan.first)
      raise "accepted bytes were replaced" unless File.read(copy.path) == "accepted\n"
    ensure
      reopened.try(&.close)
      live_view.try(&.close)
      store.try(&.close)
    end
  end

  it "rejects corrupt frames without touching a source and supports explicit discard" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/corrupt.txt")
      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      session.write_snapshot(source_path: source, version: 4_i64) do |io|
        io.write("draft\n".to_slice)
      end
      session.close

      reopened = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      candidate = reopened.candidates.first
      frame = File.open(candidate.path.to_s, "r+")
      frame.seek(0)
      frame.write(Bytes[0_u8])
      frame.close

      damaged = reopened.candidates
      raise "corrupt frame must not be offered" unless damaged.empty?
      raise "corruption should be reported" if damaged.warnings.empty?

      # Recreate a valid frame, then exercise the explicit, identity-checked
      # discard path.  No source exists, so a source-side mutation is
      # impossible by construction.
      replacement = reopened.open_session
      replacement.write_snapshot(source_path: source, version: 5_i64) do |io|
        io.write("draft again\n".to_slice)
      end
      replacement.close
      fresh = reopened.candidates
      raise "replacement frame should be discoverable" unless fresh.size == 1
      reopened.discard(fresh.first)
      raise "explicit discard should remove only its frame" unless reopened.candidates.empty?
    ensure
      reopened.try(&.close)
      store.try(&.close)
    end
  end

  it "rejects payload corruption through the frame checksum" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/checksum.txt")
      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      snapshot = session.write_snapshot(source_path: source, version: 1_i64) do |io|
        io.write("checksum-protected draft\n".to_slice)
      end
      session.close

      frame = File.open(snapshot.path.to_s, "r+")
      begin
        frame.seek(Adamantine::RecoveryStore::FRAME_MAGIC.bytesize)
        metadata_length_bytes = Bytes.new(4)
        raise "failed to read frame metadata length" unless frame.read(metadata_length_bytes) == metadata_length_bytes.size
        metadata_length = (metadata_length_bytes[0].to_i64 << 24) |
                          (metadata_length_bytes[1].to_i64 << 16) |
                          (metadata_length_bytes[2].to_i64 << 8) |
                          metadata_length_bytes[3].to_i64
        content_offset = Adamantine::RecoveryStore::FRAME_MAGIC.bytesize + 4 + metadata_length
        frame.seek(content_offset)
        original = frame.read_byte
        raise "frame payload was unexpectedly empty" unless original
        frame.seek(content_offset)
        frame.write(Bytes[(original.not_nil! ^ 0xff_u8)])
        frame.flush
      ensure
        frame.close unless frame.closed?
      end

      reopened = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      damaged = reopened.candidates
      raise "payload checksum corruption must not be offered" unless damaged.empty?
      raise "payload corruption should be reported" unless damaged.warnings.any? { |warning| warning.code == Adamantine::RecoveryStore::ErrorCode::Corrupt }
    ensure
      reopened.try(&.close)
      store.try(&.close)
    end
  end

  it "rejects a truncated frame during abandoned-session discovery" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/truncated.txt")
      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      snapshot = session.write_snapshot(source_path: source, version: 1_i64) do |io|
        io.write("truncated draft\n".to_slice)
      end
      session.close

      frame_size = File.info(snapshot.path).size
      raise "valid frame unexpectedly has no truncatable byte" unless frame_size > 0
      File.open(snapshot.path.to_s, "r+") do |frame|
        frame.truncate(frame_size - 1)
      end

      reopened = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      damaged = reopened.candidates
      raise "truncated frame must not be offered" unless damaged.empty?
      raise "truncation should be reported" unless damaged.warnings.any? { |warning| warning.code == Adamantine::RecoveryStore::ErrorCode::Corrupt }
    ensure
      reopened.try(&.close)
      store.try(&.close)
    end
  end

  it "filters abandoned frames by their recorded project" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/shared.txt")
      alpha = Adamantine::RecoveryStore.new(root: root, project: "/workspace/alpha")
      alpha_session = alpha.open_session
      alpha_session.write_snapshot(source_path: source, version: 1_i64) do |io|
        io.write("alpha\n".to_slice)
      end
      alpha_session.close

      beta = Adamantine::RecoveryStore.new(root: root, project: "/workspace/beta")
      beta_session = beta.open_session
      beta_session.write_snapshot(source_path: source, version: 2_i64) do |io|
        io.write("beta\n".to_slice)
      end
      beta_session.close

      alpha_view = Adamantine::RecoveryStore.new(root: root, project: "/workspace/alpha")
      raise "project filter leaked another project's frame" unless alpha_view.candidates.size == 1
      raise "wrong project frame was returned" unless alpha_view.candidates.first.project == "/workspace/alpha"
      all = Adamantine::RecoveryStore.new(root: root)
      raise "unfiltered scan should retain both projects" unless all.candidates.size == 2
    ensure
      alpha_view.try(&.close)
      all.try(&.close)
      alpha.try(&.close)
      beta.try(&.close)
    end
  end

  it "enforces private recovery directories and bounded session discovery" do
    with_recovery_workspace do |root|
      sessions_path = root / "sessions"
      Dir.mkdir_p(sessions_path.to_s)
      target = root / "real-session"
      Dir.mkdir(target.to_s, 0o700)
      symlinked = sessions_path / "session-#{"a" * 32}"
      File.symlink(target.basename.to_s, symlinked.to_s)

      rejected = false
      begin
        Adamantine::RecoveryStore.new(root: symlinked).open_session
      rescue ex : Adamantine::RecoveryStore::Error
        rejected = ex.code == Adamantine::RecoveryStore::ErrorCode::Symlink
      end
      raise "symlinked recovery root must be rejected" unless rejected

      129.times do |index|
        store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
        session = store.open_session
        session.write_snapshot(source_path: "/workspace/project/file#{index}.txt", version: index.to_i64) do |io|
          io.write("x\n".to_slice)
        end
        session.close
        store.close
      end

      bounded = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      scan = bounded.candidates
      raise "bounded scan must report truncation" unless scan.truncated?
      raise "bounded scan returned too many sessions" if scan.size > Adamantine::RecoveryStore::MAX_SCANNED_SESSIONS
      raise "bounded scan omitted its warning" unless scan.warnings.any? { |warning| warning.code == Adamantine::RecoveryStore::ErrorCode::ScanLimit }
    ensure
      bounded.try(&.close)
    end
  end

  it "rejects a streamed document larger than the per-document bound" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/large.txt")
      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      session.write_snapshot(source_path: source, version: 1_i64) do |io|
        io.write("small\n".to_slice)
      end

      too_large = Bytes.new((Adamantine::RecoveryStore::MAX_DOCUMENT_BYTES + 1).to_i, 120_u8)
      quota_error : Adamantine::RecoveryStore::Error? = nil
      begin
        session.write_snapshot(source_path: source, version: 2_i64) do |io|
          io.write(too_large)
        end
      rescue ex : Adamantine::RecoveryStore::Error
        quota_error = ex
      end
      raise "oversized document must be rejected" unless quota_error && quota_error.not_nil!.code == Adamantine::RecoveryStore::ErrorCode::Quota

      session.close
      reopened = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      candidate = reopened.candidates.first
      copy = reopened.recover(candidate)
      raise "oversized write replaced the accepted frame" unless File.read(copy.path) == "small\n"
    ensure
      reopened.try(&.close)
      store.try(&.close)
    end
  end

  it "discovers every small frame in a session below the full session scan cap" do
    with_recovery_workspace do |root|
      raise "scanner must admit one complete session quota" unless Adamantine::RecoveryStore::MAX_SCANNED_BYTES >= Adamantine::RecoveryStore::MAX_SESSION_BYTES

      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      4.times do |index|
        session.write_snapshot(source_path: "/workspace/project/src/buffer#{index}.txt", version: index.to_i64) do |io|
          io.write(("frame #{index}\n").to_slice)
        end
      end
      session.close

      scan = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project").candidates
      raise "a sub-quota multi-frame session should not hit the scan byte cap" unless scan.size == 4
    ensure
      store.try(&.close)
    end
  end

  it "rejects a sparse quota-peak replacement while retaining the prior frame" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/quota.txt")
      accepted_content = "accepted before quota\n"
      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      accepted = session.write_snapshot(source_path: source, version: 1_i64) do |io|
        io.write(accepted_content.to_slice)
      end

      frame_size = File.info(accepted.path).size
      frame_overhead = frame_size - accepted.bytes
      raise "test fixture expected a positive frame overhead" unless frame_overhead > 0
      padding_size = Adamantine::RecoveryStore::MAX_SESSION_BYTES - frame_size - frame_overhead - 4
      raise "test fixture cannot fit sparse quota padding" unless padding_size > 0

      padding_path = session.path / "quota-padding"
      File.open(padding_path.to_s, "w") do |padding|
        padding.truncate(padding_size)
      end
      File.chmod(padding_path.to_s, 0o600)

      quota_error : Adamantine::RecoveryStore::Error? = nil
      begin
        session.write_snapshot(source_path: source, version: 1_i64) do |io|
          io.write(Bytes.new(4, 0x41_u8))
          io.write(Bytes[0x42_u8])
        end
      rescue ex : Adamantine::RecoveryStore::Error
        quota_error = ex
      end
      raise "replacement crossing the session peak must be rejected" unless quota_error && quota_error.not_nil!.code == Adamantine::RecoveryStore::ErrorCode::Quota

      # Remove only the sparse fixture before recovery; the accepted frame is
      # the user-owned state whose preservation this test verifies.
      File.delete(padding_path.to_s)
      session.close
      reopened = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      scan = reopened.candidates
      raise "quota rejection must retain exactly one accepted frame" unless scan.size == 1
      copy = reopened.recover(scan.first)
      raise "quota rejection replaced the prior frame" unless File.read(copy.path) == accepted_content
    ensure
      reopened.try(&.close)
      store.try(&.close)
    end
  end

  it "fails closed when crash-left temp files exhaust count scans" do
    with_recovery_workspace do |root|
      source = Path.new("/workspace/project/src/temp-scan.txt")
      store = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      session = store.open_session
      accepted = session.write_snapshot(source_path: source, version: 1_i64) do |io|
        io.write("accepted before temp scan\n".to_slice)
      end

      session_temps = [] of Path
      Adamantine::RecoveryStore::MAX_SNAPSHOTS_PER_SESSION.times do |index|
        path = session.path / ".snapshot-crash-#{index}.tmp"
        File.open(path.to_s, "w") { }
        File.chmod(path.to_s, 0o600)
        session_temps << path
      end

      write_error : Adamantine::RecoveryStore::Error? = nil
      begin
        session.write_snapshot(source_path: "/workspace/project/src/new.txt", version: 2_i64) do |io|
          io.write("must not publish\n".to_slice)
        end
      rescue ex : Adamantine::RecoveryStore::Error
        write_error = ex
      end
      raise "snapshot count scan truncation must refuse new writes" unless write_error && write_error.not_nil!.code == Adamantine::RecoveryStore::ErrorCode::Quota
      session_temps.each { |path| File.delete(path.to_s) }
      session.close

      reopened = Adamantine::RecoveryStore.new(root: root, project: "/workspace/project")
      scan = reopened.candidates
      raise "count-scan refusal must retain the accepted frame" unless scan.size == 1
      candidate = scan.first

      recovered_dir = root / "recovered" / candidate.session_id
      Dir.mkdir_p(recovered_dir.to_s)
      File.chmod(recovered_dir.to_s, 0o700)
      recovered_temps = [] of Path
      (Adamantine::RecoveryStore::MAX_RECOVERED_COPIES_PER_SESSION + 2).times do |index|
        path = recovered_dir / ".recovered-crash-#{index}.tmp"
        File.open(path.to_s, "w") { }
        File.chmod(path.to_s, 0o600)
        recovered_temps << path
      end

      recover_error : Adamantine::RecoveryStore::Error? = nil
      begin
        reopened.recover(candidate)
      rescue ex : Adamantine::RecoveryStore::Error
        recover_error = ex
      end
      raise "recovery copy count scan truncation must refuse new copies" unless recover_error && recover_error.not_nil!.code == Adamantine::RecoveryStore::ErrorCode::Quota
      recovered_temps.each { |path| File.delete(path.to_s) }

      copy = reopened.recover(candidate)
      raise "accepted frame should remain recoverable after temp cleanup" unless File.read(copy.path) == "accepted before temp scan\n"
    ensure
      reopened.try(&.close)
      store.try(&.close)
    end
  end
end
