require "spec"
require "file_utils"

require "../src/adamantine/external_file_monitor"

private def with_monitor_workspace(prefix : String = "adamantine-file-monitor-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def monitor_for(events : Array(Adamantine::ExternalFileMonitor::Event), max_bytes : Int64? = nil, chunk_size : Int32 = 4_096)
  Adamantine::ExternalFileMonitor.new(
    ->(event : Adamantine::ExternalFileMonitor::Event) { events << event },
    chunk_size: chunk_size,
    max_bytes: max_bytes
  )
end

describe Adamantine::ExternalFileMonitor do
  it "watches all files through one callback and ignores the initial baseline" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      File.write(path, "before\n")
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)

      token = monitor.watch(path)
      raise "token should identify watched path" unless token.path == path
      initial_hash_passes = monitor.hash_passes
      raise "initial watch should not report a conflict" unless monitor.poll == 0
      raise "initial event list should be empty" unless events.empty?
      raise "unchanged stamp should not hash again" unless monitor.hash_passes == initial_hash_passes

      File.write(path, "after\n")
      raise "changed file should report one event" unless monitor.poll == 1
      raise "changed event should be typed" unless events.first.kind == Adamantine::ExternalFileMonitor::Event::Kind::Changed
      raise "event should carry the watch token" unless events.first.token == token
      raise "event should carry the latest digest" unless events.first.revision
    end
  end

  it "starts from an exact snapshot baseline without hashing it again" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      File.write(path, "before\n")
      snapshot = Adamantine::FileRevision.read(path, chunk_size: 2)
      revision = snapshot.revision
      raise "test snapshot should be stable" unless revision

      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      token = monitor.watch(path, baseline: revision.not_nil!)

      raise "baseline watch should not hash exact snapshot again" unless monitor.hash_passes == 0
      File.write(path, "after\n")
      raise "changed baseline should emit one event" unless monitor.poll == 1
      raise "event should retain the baseline token" unless events.first.token == token
    end
  end

  it "detects deletion, non-regular replacement, and unreadable transitions" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      File.write(path, "before\n")
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      token = monitor.watch(path)

      File.delete(path)
      monitor.poll
      raise "deletion should be reported" unless events.last.kind == Adamantine::ExternalFileMonitor::Event::Kind::Deleted

      Dir.mkdir(path)
      monitor.poll
      raise "directory transition should be non-regular" unless events.last.kind == Adamantine::ExternalFileMonitor::Event::Kind::NonRegular

      Dir.delete(path)
      File.write(path, "restored\n")
      File.chmod(path, 0o000)
      monitor.poll
      # Permission checks are identity-dependent (the test process may be root),
      # so accept either a readable restoration or a fail-closed unreadable event.
      unless events.last.kind.in?(Adamantine::ExternalFileMonitor::Event::Kind::Changed, Adamantine::ExternalFileMonitor::Event::Kind::Unreadable)
        raise "restoration should not be silently ignored"
      end
      File.chmod(path, 0o600)
      raise "token should remain active" unless monitor.watched?(token)
    end
  end

  it "distinguishes atomic replacement and symlink retargeting" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      replacement = tmp_dir / "replacement.txt"
      File.write(path, "same\n")
      File.write(replacement, "same\n")
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      monitor.watch(path)

      File.rename(replacement, path)
      monitor.poll
      raise "same-content inode replacement should be typed" unless events.last.kind == Adamantine::ExternalFileMonitor::Event::Kind::Replaced

      target_a = tmp_dir / "target-a.txt"
      target_b = tmp_dir / "target-b.txt"
      link = tmp_dir / "link.txt"
      File.write(target_a, "same-target\n")
      File.write(target_b, "same-target\n")
      File.symlink(target_a.basename.to_s, link)
      link_monitor = monitor_for(events)
      link_monitor.watch(link)

      File.delete(link)
      File.symlink(target_b.basename.to_s, link)
      link_monitor.poll
      raise "symlink retarget should be typed" unless events.last.kind == Adamantine::ExternalFileMonitor::Event::Kind::SymlinkRetargeted
    end
  end

  it "detects content edits through a symlink without retargeting it" do
    with_monitor_workspace do |tmp_dir|
      target = tmp_dir / "target.txt"
      link = tmp_dir / "link.txt"
      File.write(target, "before\n")
      File.symlink(target.basename.to_s, link)
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      monitor.watch(link)

      File.write(target, "after!\n")
      raise "target edit through link should emit one event" unless monitor.poll == 1
      raise "target edit should be Changed, not retargeted" unless events.first.kind == Adamantine::ExternalFileMonitor::Event::Kind::Changed
    end
  end

  it "classifies replacement of the same symlink target as replacement, not retargeting" do
    with_monitor_workspace do |tmp_dir|
      target = tmp_dir / "target.txt"
      replacement = tmp_dir / "replacement.txt"
      link = tmp_dir / "link.txt"
      File.write(target, "before\n")
      File.write(replacement, "after!\n")
      File.symlink(target.basename.to_s, link)
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      monitor.watch(link)

      File.rename(replacement, target)
      raise "target replacement should emit one event" unless monitor.poll == 1
      raise "unchanged symlink path should be a replacement" unless events.first.kind == Adamantine::ExternalFileMonitor::Event::Kind::Replaced
    end
  end

  it "reports retargeting even when a symlink becomes broken" do
    with_monitor_workspace do |tmp_dir|
      target = tmp_dir / "target.txt"
      missing_target = tmp_dir / "missing.txt"
      link = tmp_dir / "link.txt"
      File.write(target, "before\n")
      File.symlink(target.basename.to_s, link)
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      monitor.watch(link)

      File.delete(link)
      File.symlink(missing_target.basename.to_s, link)
      raise "broken symlink retarget should emit one event" unless monitor.poll == 1
      raise "broken symlink retarget should be typed" unless events.first.kind == Adamantine::ExternalFileMonitor::Event::Kind::SymlinkRetargeted
    end
  end

  it "supports forced rechecks and acknowledges an own save" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      File.write(path, "before\n")
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      token = monitor.watch(path)

      File.write(path, "after\n")
      raise "forced recheck should be accepted" unless monitor.force_recheck(token)
      raise "forced recheck should report changed content" unless events.size == 1

      File.write(path, "owned\n")
      owned = Adamantine::FileRevision.capture(path)
      raise "own save capture should be stable" unless owned.revision
      raise "exact own save acknowledgement should succeed" unless monitor.acknowledge(token, owned.revision.not_nil!)
      raise "acknowledged save should not report itself" unless monitor.poll == 0
      raise "acknowledged save should remain quiet on forced recheck" unless monitor.force_recheck(token)
      raise "forced same-revision check should not report itself" unless events.size == 1
    end
  end

  it "uses a forced recheck when content changes but the cheap stamp is restored" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "same-stamp.txt"
      File.write(path, "before\n")
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      token = monitor.watch(path)
      original_mtime = Adamantine::FileRevision.probe(path).modification_time
      raise "test file should have an mtime" unless original_mtime

      File.write(path, "after!\n")
      time = original_mtime.not_nil!
      File.utime(time, time, path)

      raise "restored cheap stamp should not trigger ordinary polling" unless monitor.poll == 0
      raise "forced recheck should detect restored-stamp content" unless monitor.force_recheck(token)
      raise "forced recheck should report changed content" unless events.size == 1 && events.first.kind == Adamantine::ExternalFileMonitor::Event::Kind::Changed
    end
  end

  it "classifies an external mismatch without mutating monitor state" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      File.write(path, "before\n")
      before = Adamantine::FileRevision.capture(path)
      File.write(path, "after!\n")
      after = Adamantine::FileRevision.capture(path)
      token = Adamantine::ExternalFileMonitor::WatchToken.new(path, 99_u64)

      kind = Adamantine::ExternalFileMonitor.event_kind(before, after)
      raise "digest mismatch should classify as changed" unless kind == Adamantine::ExternalFileMonitor::Event::Kind::Changed
      event = Adamantine::ExternalFileMonitor.event_for(token, before, after)
      raise "classifier should build a typed event" unless event && event.not_nil!.token == token
    end
  end

  it "reports an externally expanded file as too large without hashing it whole" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "bounded.txt"
      File.write(path, "small\n")
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events, 64, 8)
      token = monitor.watch(path)

      File.write(path, "x" * 1_024)
      monitor.poll

      raise "expanded file should report one event" unless events.size == 1
      raise "expanded file should be too large" unless events.first.kind == Adamantine::ExternalFileMonitor::Event::Kind::TooLarge
      raise "too-large event should retain token" unless events.first.token == token
    end
  end

  it "drops a stale hash result after unwatch or reopen" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "racing.txt"
      File.write(path, "a" * 128_000)
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events, nil, 128)
      token = monitor.watch(path)
      File.write(path, "b" * 128_000)

      spawn do
        3.times { Fiber.yield }
        monitor.unwatch(token)
      end

      monitor.force_recheck(token)
      raise "unwatched token must not publish a stale event" unless events.empty?

      reopened = monitor.watch(path)
      File.write(path, "c" * 128_000)
      spawn do
        3.times { Fiber.yield }
        monitor.watch(path)
      end
      monitor.force_recheck(reopened)
      raise "reopened path must not publish an old-generation event" unless events.empty?
    end
  end

  it "does not emit after an old token is unregistered" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "sample.txt"
      File.write(path, "before\n")
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      token = monitor.watch(path)

      raise "unwatch should remove the token" unless monitor.unwatch(token)
      File.write(path, "after\n")
      raise "stale unwatch should block polling" unless monitor.poll == 0
      raise "stale token should no longer be watched" if monitor.watched?(token)
    end
  end

  it "polls in one background fiber and can restart without reviving the old worker" do
    with_monitor_workspace do |tmp_dir|
      path = tmp_dir / "background.txt"
      File.write(path, "before\n")
      events = [] of Adamantine::ExternalFileMonitor::Event
      monitor = monitor_for(events)
      monitor.watch(path)

      raise "first worker should start" unless monitor.start(1.millisecond)
      raise "a second worker must not start" if monitor.start(1.millisecond)
      File.write(path, "after-one\n")
      100.times do
        break unless events.empty?
        sleep 1.millisecond
      end
      raise "background worker did not publish the change" unless events.size == 1
      raise "worker should stop" unless monitor.stop
      raise "monitor should report stopped" if monitor.running?

      raise "monitor should restart with a new worker generation" unless monitor.start(1.millisecond)
      File.write(path, "after-two\n")
      100.times do
        break if events.size == 2
        sleep 1.millisecond
      end
      raise "restarted worker did not publish exactly once" unless events.size == 2
      raise "restarted worker should stop" unless monitor.stop
    ensure
      monitor.try(&.stop)
    end
  end
end
