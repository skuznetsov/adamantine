require "spec"
require "file_utils"

require "../src/adamantine/git_repository"

private def with_git_repository(prefix : String = "adamantine-git-repository-spec", &)
  root = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def git!(root : Path, *args : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("git", args.to_a, chdir: root.to_s, output: output, error: error)
  unless status.success?
    raise "git #{args.join(' ')} failed: #{error.to_s}"
  end
  output.to_s
end

private def configure_git!(root : Path) : Nil
  git!(root, "config", "user.name", "Adamantine Spec")
  git!(root, "config", "user.email", "adamantine-spec@example.invalid")
end

private def init_git!(root : Path) : Nil
  Process.run("git", ["init", "--quiet", root.to_s]).success?.should be_true
  configure_git!(root)
end

describe Adamantine::GitRepository do
  it "reads a bounded snapshot with a pipe-containing subject and graph" do
    with_git_repository do |root|
      init_git!(root)
      File.write(root / "tracked.txt", "one\n")
      git!(root, "add", "--", "tracked.txt")
      git!(root, "commit", "--quiet", "-m", "first")
      File.write(root / "tracked.txt", "two\n")
      git!(root, "add", "--", "tracked.txt")
      git!(root, "commit", "--quiet", "-m", "subject | keeps separators")
      File.write(root / "tracked.txt", "three\n")
      File.write(root / "odd | name.txt", "unusual\n")

      snapshot = Adamantine::GitRepository.snapshot(root, Adamantine::GitRepository::Cancellation.new)

      snapshot.root.should eq(Path.new(File.realpath(root.to_s)))
      snapshot.commits.size.should eq(2)
      snapshot.commits[0].message.should eq("subject | keeps separators")
      snapshot.commits[0].graph.empty?.should be_false
      snapshot.files.any? { |file| file.path == "tracked.txt" && file.status == ".M" }.should be_true
      snapshot.files.any? { |file| file.path == "odd | name.txt" && file.status == "??" }.should be_true
    end
  end

  it "preserves rename paths and the exact XY status" do
    with_git_repository do |root|
      init_git!(root)
      File.write(root / "old | name.txt", "content\n")
      git!(root, "add", "--", "old | name.txt")
      git!(root, "commit", "--quiet", "-m", "rename source")
      File.rename(root / "old | name.txt", root / "new | name.txt")
      git!(root, "add", "-A", "--", ".")

      snapshot = Adamantine::GitRepository.snapshot(root, Adamantine::GitRepository::Cancellation.new)
      rename = snapshot.files.find { |file| file.path == "new | name.txt" }

      rename.should_not be_nil
      rename.not_nil!.status[0].should eq('R')
      rename.not_nil!.display.includes?("new | name.txt").should be_true
      rename.not_nil!.display.includes?("old | name.txt").should be_true
    end
  end

  it "returns commit and combined staged/unstaged file diffs" do
    with_git_repository do |root|
      init_git!(root)
      File.write(root / "tracked.txt", "one\n")
      git!(root, "add", "--", "tracked.txt")
      git!(root, "commit", "--quiet", "-m", "diff subject")
      File.write(root / "tracked.txt", "one\nworktree\n")
      git!(root, "add", "--", "tracked.txt")
      File.write(root / "tracked.txt", "one\nworktree\nstill dirty\n")

      snapshot = Adamantine::GitRepository.snapshot(root, Adamantine::GitRepository::Cancellation.new)
      hash = snapshot.commits.first.hash
      commit_diff = Adamantine::GitRepository.commit_diff(root, hash, Adamantine::GitRepository::Cancellation.new)
      file_diff = Adamantine::GitRepository.file_diff(root, "tracked.txt", Adamantine::GitRepository::Cancellation.new)

      commit_diff.includes?("diff --git").should be_true
      file_diff.includes?("[staged]").should be_true
      file_diff.includes?("[unstaged]").should be_true
      file_diff.includes?("still dirty").should be_true
    end
  end

  it "rejects untracked file diffs without reading the file" do
    with_git_repository do |root|
      init_git!(root)
      File.write(root / "untracked.txt", "must not be read\n")

      expect_raises(Adamantine::GitRepository::UnsupportedDiffError) do
        Adamantine::GitRepository.file_diff(root, "untracked.txt", Adamantine::GitRepository::Cancellation.new)
      end
    end
  end

  it "cancels before starting a child and rejects malformed hashes" do
    with_git_repository do |root|
      init_git!(root)
      cancellation = Adamantine::GitRepository::Cancellation.new
      cancellation.cancel

      expect_raises(Adamantine::GitRepository::CancellationError) do
        Adamantine::GitRepository.snapshot(root, cancellation)
      end

      expect_raises(ArgumentError) do
        Adamantine::GitRepository.commit_diff(root, "not-a-hash", Adamantine::GitRepository::Cancellation.new)
      end
    end
  end

  it "sanitizes controls and bounds displayed output" do
    raw = "prefix\u0000\u0001\u001b[31m\n" + ("x" * 800)
    displayed = Adamantine::GitRepository.display(raw, max_chars: 80)

    displayed.bytesize.should be <= 80
    displayed.includes?("\u0000").should be_false
    displayed.includes?("\u0001").should be_false
    displayed.includes?("\u001b").should be_false
    displayed.includes?("[truncated]").should be_true
  end
end
