require "spec"
require "file_utils"
require "../src/adamantine/git_repository"

module Adamantine::GitRepository
  def self.process_probe(root : Path, cancellation : Cancellation, timeout_span : Time::Span) : String
    run_command(root, ["probe"], cancellation, Time.instant + timeout_span).output
  end

  def self.diff_display_probe(raw : String) : String
    format_diff(raw, false)
  end
end

private def with_git_adversary(&)
  root = Path.new(Dir.tempdir, "adamantine-git-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def adversary_git(root : Path, args : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  Process.run("git", args, chdir: root, output: output, error: error).success?.should be_true, error.to_s
  output.to_s
end

private def with_fake_git(root : Path, body : String, &)
  bin = root / "bin"
  Dir.mkdir_p(bin)
  fake = bin / "git"
  File.write(fake, "#!/bin/sh\nprintf '%s' \"$$\" > #{(root / "pid").to_s.inspect}\n#{body}\n")
  File.chmod(fake, 0o700)
  previous = ENV["PATH"]?
  ENV["PATH"] = "#{bin}:#{previous}"
  yield
ensure
  if previous
    ENV["PATH"] = previous
  else
    ENV.delete("PATH")
  end
end

describe "Git process and parsing adversary" do
  it "retains the exact byte cap after control sanitization expands UTF-8" do
    (179..186).each do |length|
      raw = (("\u0001" * length) + "\n") * 2_800
      raw.bytesize.should be < Adamantine::GitRepository::MAX_OUTPUT_BYTES
      rendered = Adamantine::GitRepository.diff_display_probe(raw)
      rendered.valid_encoding?.should be_true
      rendered.bytesize.should be <= Adamantine::GitRepository::MAX_OUTPUT_BYTES
      rendered.should contain("[diff truncated]")
    end
  end

  it "terminates and reaps a hung command at its deadline" do
    with_git_adversary do |root|
      with_fake_git(root, "exec /bin/sleep 30") do
        started = Time.instant
        expect_raises(Adamantine::GitRepository::DeadlineExceededError) do
          Adamantine::GitRepository.process_probe(root, Adamantine::GitRepository::Cancellation.new, 500.milliseconds)
        end
        (Time.instant - started).should be < 2.seconds
        Process.exists?(File.read(root / "pid").to_i64).should be_false
      end
    end
  end

  it "terminates and reaps a command cancelled after launch" do
    with_git_adversary do |root|
      with_fake_git(root, "exec /bin/sleep 30") do
        cancellation = Adamantine::GitRepository::Cancellation.new
        spawn do
          deadline = Time.instant + 2.seconds
          until File.exists?(root / "pid") || Time.instant >= deadline
            sleep 5.milliseconds
          end
          cancellation.cancel
        end
        started = Time.instant
        expect_raises(Adamantine::GitRepository::CancellationError) do
          Adamantine::GitRepository.process_probe(root, cancellation, 5.seconds)
        end
        (Time.instant - started).should be < 2.seconds
        Process.exists?(File.read(root / "pid").to_i64).should be_false
      end
    end
  end

  it "rejects excessive output instead of publishing a partial success" do
    with_git_adversary do |root|
      with_fake_git(root, "exec /usr/bin/yes excessive-output") do
        expect_raises(Adamantine::GitRepository::OutputLimitError) do
          Adamantine::GitRepository.process_probe(root, Adamantine::GitRepository::Cancellation.new, 3.seconds)
        end
        Process.exists?(File.read(root / "pid").to_i64).should be_false
      end
    end
  end

  it "shares the output budget between stdout and stderr" do
    with_git_adversary do |root|
      with_fake_git(root, "exec /usr/bin/ruby -e 'STDOUT.write(\"x\" * 300_000); STDERR.write(\"y\" * 300_000)'") do
        expect_raises(Adamantine::GitRepository::OutputLimitError) do
          Adamantine::GitRepository.process_probe(root, Adamantine::GitRepository::Cancellation.new, 3.seconds)
        end
        Process.exists?(File.read(root / "pid").to_i64).should be_false
      end
    end
  end

  it "retains newline paths exactly and does not execute configured helpers" do
    with_git_adversary do |base|
      root = base / "repo\nline"
      Dir.mkdir(root)
      adversary_git(root, ["init", "--quiet"])
      adversary_git(root, ["config", "user.name", "Adversary"])
      adversary_git(root, ["config", "user.email", "adversary@example.invalid"])
      path = "odd\n\e[31m | *.txt"
      File.write(root / path, "before\n")
      File.write(root / ".gitattributes", "*.txt diff=hostile\n")
      adversary_git(root, ["add", "--", "."])
      adversary_git(root, ["commit", "--quiet", "-m", "controls | subject"])
      marker = base / "helper-ran"
      helper = base / "helper"
      File.write(helper, "#!/bin/sh\n/usr/bin/touch #{marker.to_s.inspect}\n")
      File.chmod(helper, 0o700)
      adversary_git(root, ["config", "diff.external", helper.to_s])
      adversary_git(root, ["config", "diff.hostile.textconv", helper.to_s])
      adversary_git(root, ["config", "core.fsmonitor", helper.to_s])
      File.write(root / path, "after\n")
      snapshot = Adamantine::GitRepository.snapshot(root, Adamantine::GitRepository::Cancellation.new)
      snapshot.root.should eq(Path.new(File.realpath(root)))
      entry = snapshot.files.find { |file| file.path == path }.not_nil!
      entry.display.includes?('\n').should be_false
      entry.display.includes?('\e').should be_false
      diff = Adamantine::GitRepository.file_diff(root, path, Adamantine::GitRepository::Cancellation.new)
      diff.should contain("+after")
      File.exists?(marker).should be_false

      worktree = base / "linked"
      adversary_git(root, ["worktree", "add", "--quiet", "--detach", worktree.to_s])
      linked = Adamantine::GitRepository.snapshot(worktree, Adamantine::GitRepository::Cancellation.new)
      linked.root.should eq(Path.new(File.realpath(worktree)))
      linked.commits.first.hash.should eq(snapshot.commits.first.hash)
      # Positive control: the configured helper really is executable and
      # ordinary unguarded Git invokes it for this repository.
      adversary_git(root, ["diff", "--ext-diff", "--", path])
      File.exists?(marker).should be_true
    end
  end
end
