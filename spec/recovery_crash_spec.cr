require "spec"
require "file_utils"

require "../src/adamantine/recovery_store"

private RECOVERY_CRASH_CHILD_ENV   = "ADAMANTINE_RECOVERY_CRASH_CHILD"
private RECOVERY_CRASH_ROOT_ENV    = "ADAMANTINE_RECOVERY_CRASH_ROOT"
private RECOVERY_CRASH_PROJECT_ENV = "ADAMANTINE_RECOVERY_CRASH_PROJECT"
private RECOVERY_CRASH_SOURCE_ENV  = "ADAMANTINE_RECOVERY_CRASH_SOURCE"

private def run_recovery_crash_child : NoReturn
  root = Path.new(ENV[RECOVERY_CRASH_ROOT_ENV].not_nil!)
  project = ENV[RECOVERY_CRASH_PROJECT_ENV].not_nil!
  source = Path.new(ENV[RECOVERY_CRASH_SOURCE_ENV].not_nil!)

  store = Adamantine::RecoveryStore.new(root: root, project: project)
  session = store.open_session
  session.write_snapshot(
    source_path: source,
    modified: true,
    version: 1_i64,
    freshness: -> { true },
  ) do |io|
    io.write("puts :recovered_from_crash\n".to_slice)
  end

  # The parent only proceeds after the complete checkpoint has been
  # published. The session remains open so the parent can verify that a live
  # owner is excluded before it kills this disposable child.
  STDOUT.puts("READY")
  STDOUT.flush
  loop { sleep 1.second }
end

if ENV[RECOVERY_CRASH_CHILD_ENV]? == "1"
  run_recovery_crash_child
end

private def with_recovery_crash_workspace(&)
  # RecoveryStore rejects symlinked path components. macOS commonly exposes
  # Dir.tempdir through /var -> /private/var, so canonicalize the fixture
  # parent before creating the private recovery root.
  tmp_parent = Path.new(File.realpath(Dir.tempdir))
  tmp_dir = tmp_parent / "adamantine-recovery-crash-#{Random::Secure.hex(8)}"
  project_dir = tmp_dir / "project"
  recovery_dir = tmp_dir / "recovery"
  Dir.mkdir_p(project_dir)
  Dir.mkdir_p(recovery_dir)
  yield project_dir, recovery_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe "RecoveryStore crash ownership" do
  it "excludes a live child, then recovers its checkpoint after abrupt termination" do
    with_recovery_crash_workspace do |project_dir, recovery_dir|
      source = project_dir / "example.cr"
      original = "puts :original_on_disk\n"
      File.write(source, original)
      project = project_dir.to_s

      child_env = {
        RECOVERY_CRASH_CHILD_ENV   => "1",
        RECOVERY_CRASH_ROOT_ENV    => recovery_dir.to_s,
        RECOVERY_CRASH_PROJECT_ENV => project,
        RECOVERY_CRASH_SOURCE_ENV  => source.to_s,
      }
      executable = Process.executable_path.not_nil!
      child : Process? = nil
      child = Process.new(
        executable,
        env: child_env,
        input: Process::Redirect::Close,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Close,
      )
      waited = false

      ready = Channel(String?).new(1)
      spawn do
        begin
          ready.send(child.not_nil!.output.gets)
        rescue
          ready.send(nil)
        end
      end

      line = select
      when message = ready.receive
        message
      when timeout(5.seconds)
        nil
      end
      raise "child did not publish a durable checkpoint" unless line.try(&.strip) == "READY"
      running_child = child.not_nil!
      raise "child exited before ownership check" unless running_child.exists? && !running_child.terminated?

      changed_on_disk = "puts :changed_on_disk_after_checkpoint\n"
      File.write(source, changed_on_disk)

      live_store = Adamantine::RecoveryStore.new(root: recovery_dir, project: project)
      live_candidates = live_store.candidates(project: project)
      raise "live child checkpoint must stay hidden" unless live_candidates.empty?
      live_store.close

      running_child.signal(Signal::KILL)
      status = running_child.wait
      waited = true
      raise "child must terminate by signal" unless status.signal_exit?

      store = Adamantine::RecoveryStore.new(root: recovery_dir, project: project)
      candidates = store.candidates(project: project)
      raise "abandoned child checkpoint should be discoverable" unless candidates.size == 1
      candidate = candidates.first
      raise "candidate source mismatch" unless candidate.source_path == source
      raise "candidate version mismatch" unless candidate.version == 1_i64

      copy = store.recover(candidate)
      raise "recovery copy should be private" unless copy.path != source
      raise "recovery copy should stay in the recovery store" unless copy.path.to_s.starts_with?(recovery_dir.to_s)
      raise "recovery bytes mismatch" unless File.read(copy.path) == "puts :recovered_from_crash\n"
      raise "recovery must not overwrite changed original bytes" unless File.read(source) == changed_on_disk

      File.delete(source.to_s)
      second_copy = store.recover(candidate)
      raise "recovery copy should remain available after the original is deleted" unless File.read(second_copy.path) == "puts :recovered_from_crash\n"
      raise "recovery must not recreate a deleted original file" if File.exists?(source)
    ensure
      unless waited
        begin
          child.try(&.signal(Signal::KILL))
        rescue
        end
        begin
          child.try do |process|
            process.wait
          end
        rescue
        end
      end
      store.try(&.close)
    end
  end
end
