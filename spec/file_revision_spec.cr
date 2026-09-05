require "spec"
require "digest/sha256"
require "file_utils"

require "../src/adamantine/file_revision"

private def with_revision_workspace(prefix : String = "adamantine-file-revision-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::FileRevision do
  it "probes a regular file without reading its content" do
    with_revision_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      File.write(path, "alpha\n")

      stamp = Adamantine::FileRevision.probe(path)

      raise "file should exist" unless stamp.exists
      raise "file type should be regular" unless stamp.regular?
      raise "file type should be exposed" unless stamp.type == File::Type::File
      raise "file size should be six bytes" unless stamp.size == 6
      raise "resolved target should be present" unless stamp.resolved_target
      raise "target identity should be present" unless stamp.target_identity
    end
  end

  it "returns content and a stable SHA-256 revision from one snapshot read" do
    with_revision_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      content = "alpha\nβeta\n"
      File.write(path, content)

      snapshot = Adamantine::FileRevision.read(path, chunk_size: 3)

      raise "snapshot should be stable" unless snapshot.stable?
      raise "snapshot content mismatch" unless snapshot.content == content
      revision = snapshot.revision
      raise "stable snapshot should have a revision" unless revision
      raise "digest mismatch" unless revision.not_nil!.digest == Digest::SHA256.hexdigest(content)
      raise "before stamp missing" unless snapshot.stamp_before
      raise "after stamp missing" unless snapshot.stamp_after
      raise "stable read should preserve its stamp" unless snapshot.stamp_before.same_as?(snapshot.stamp_after.not_nil!)
    end
  end

  it "keeps digest-only capture streaming and yields between chunks" do
    with_revision_workspace do |tmp_dir|
      path = tmp_dir / "large.txt"
      content = "x" * 32_768
      File.write(path, content)
      yields = 0

      spawn do
        1_000.times do
          yields += 1
          Fiber.yield
        end
      end

      result = Adamantine::FileRevision.capture(path, chunk_size: 128)

      raise "capture should be stable" unless result.stable?
      raise "capture should not materialize content" unless result.content.nil?
      raise "capture digest mismatch" unless result.digest == Digest::SHA256.hexdigest(content)
      raise "capture should yield between bounded reads" unless yields > 0
    end
  end

  it "rejects a file that grows beyond the configured bound" do
    with_revision_workspace do |tmp_dir|
      path = tmp_dir / "bounded.txt"
      File.write(path, "0123456789")

      result = Adamantine::FileRevision.read(path, max_bytes: 4, chunk_size: 2)

      raise "oversized snapshot should be rejected" unless result.too_large?
      raise "oversized snapshot should not return content" unless result.content.nil?
      raise "oversized snapshot should not return a revision" unless result.revision.nil?
    end
  end

  it "reports an unstable snapshot when the path is replaced while reading" do
    with_revision_workspace do |tmp_dir|
      path = tmp_dir / "racing.txt"
      File.write(path, "a" * 256_000)
      replacement = "b" * 256_000

      spawn do
        3.times { Fiber.yield }
        File.write(path, replacement)
      end

      snapshot = Adamantine::FileRevision.read(path, chunk_size: 128)

      raise "concurrent replacement should not be accepted" unless snapshot.unstable?
      raise "unstable snapshot should not expose content" unless snapshot.content.nil?
      raise "unstable snapshot should not expose a revision" unless snapshot.revision.nil?
    end
  end

  it "distinguishes atomic replacement and symlink retargeting in stamps" do
    with_revision_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      replacement = tmp_dir / "replacement.txt"
      File.write(path, "same\n")
      File.write(replacement, "same\n")

      before = Adamantine::FileRevision.capture(path).revision.not_nil!.stamp
      File.rename(replacement, path)
      after = Adamantine::FileRevision.capture(path).revision.not_nil!.stamp

      raise "atomic replacement must change file identity" unless before.identity_changed?(after)

      target_a = tmp_dir / "target-a.txt"
      target_b = tmp_dir / "target-b.txt"
      link = tmp_dir / "link.txt"
      File.write(target_a, "target\n")
      File.write(target_b, "target\n")
      File.symlink(target_a.basename.to_s, link)

      link_before = Adamantine::FileRevision.probe(link)
      File.delete(link)
      File.symlink(target_b.basename.to_s, link)
      link_after = Adamantine::FileRevision.probe(link)

      raise "link should be reported as a symlink" unless link_before.symlink?
      raise "retargeted link should remain a symlink" unless link_after.symlink?
      raise "retargeted link should change resolved target" unless link_before.symlink_target_changed?(link_after)
    end
  end

  it "uses resolved target size and mtime for an unchanged symlink" do
    with_revision_workspace do |tmp_dir|
      target = tmp_dir / "target.txt"
      link = tmp_dir / "link.txt"
      File.write(target, "before\n")
      File.symlink(target.basename.to_s, link)

      before = Adamantine::FileRevision.probe(link)
      File.write(target, "after!\n")
      after = Adamantine::FileRevision.probe(link)

      raise "symlink should still resolve to a regular file" unless after.regular?
      raise "target size should be reflected in the stamp" unless before.size == 7 && after.size == 7
      raise "in-place target edit should change the cheap stamp" if before.same_as?(after)

      snapshot = Adamantine::FileRevision.capture(link)
      raise "target edit should be visible through the link" unless snapshot.digest == Digest::SHA256.hexdigest("after!\n")
    end
  end

  it "reports missing, non-regular, and unreadable probe states" do
    with_revision_workspace do |tmp_dir|
      missing = Adamantine::FileRevision.probe(tmp_dir / "missing.txt")
      raise "missing path should not exist" if missing.exists
      raise "missing path should be marked missing" unless missing.missing?

      directory = Adamantine::FileRevision.probe(tmp_dir)
      raise "directory should be non-regular" unless directory.non_regular?

      malformed = Adamantine::FileRevision.probe("bad\0path")
      raise "malformed path should fail closed as unreadable" unless malformed.unreadable?
    end
  end
end
