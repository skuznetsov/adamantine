require "spec"
require "file_utils"

require "../src/adamantine/quick_open_search"

private def with_quick_open_workspace(prefix : String = "adamantine-quick-open-search", &)
  root = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def quick_open_test_limits(**overrides)
  Adamantine::QuickOpenSearch::Limits.new(**overrides)
end

describe Adamantine::QuickOpenSearch do
  it "indexes metadata paths while skipping known directories and symlinks" do
    with_quick_open_workspace do |root|
      source = root / "src"
      hidden = root / ".git"
      dependencies = root / "node_modules"
      Dir.mkdir_p(source)
      Dir.mkdir_p(hidden)
      Dir.mkdir_p(dependencies)
      File.write(root / "README.md", "this content is not read")
      File.write(source / "app.cr", "visible source")
      File.write(hidden / "secret.cr", "must not be indexed")
      File.write(dependencies / "package.js", "must not be indexed")

      unreadable = root / "metadata-only.txt"
      File.write(unreadable, "the index must not read this")
      File.chmod(unreadable.to_s, 0o000)

      symlink_created = false
      symlink = root / "linked.cr"
      begin
        File.symlink((source / "app.cr").to_s, symlink.to_s)
        symlink_created = true
      rescue
      end

      begin
        index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 7_u64)
        relative_paths = index.entries.map(&.relative_path).sort

        relative_paths.should contain("README.md")
        relative_paths.should contain("metadata-only.txt")
        relative_paths.should contain("src/app.cr")
        relative_paths.should_not contain(".git/secret.cr")
        relative_paths.should_not contain("node_modules/package.js")
        relative_paths.should_not contain("linked.cr") if symlink_created
        index.root.should eq(root.expand)
        index.generation.should eq(7_u64)
        # Every child entry, including skipped names and directories, counts.
        index.entries_seen.should be >= 6
        index.partial?.should be_false
      ensure
        File.chmod(unreadable.to_s, 0o600)
      end
    end
  end

  it "prefers exact and prefix basenames over directory-only prefixes" do
    with_quick_open_workspace do |root|
      Dir.mkdir_p(root / "src")
      Dir.mkdir_p(root / "z")
      Dir.mkdir_p(root / "application" / "docs")
      File.write(root / "src" / "app.cr", "")
      File.write(root / "z" / "app.cr", "")
      File.write(root / "appkit.cr", "")
      File.write(root / "application" / "docs" / "readme.cr", "")

      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 1_u64)
      result = Adamantine::QuickOpenSearch.rank_file_paths(index, "app", generation: 1_u64)
      paths = result.matches.map(&.relative_path)

      paths[0, 2].should eq(["src/app.cr", "z/app.cr"])
      paths[2].should eq("appkit.cr")
      paths[-1].should eq("application/docs/readme.cr")

      lexical = Adamantine::QuickOpenSearch.rank_file_paths(index, "", generation: 1_u64)
      lexical.matches.map(&.relative_path).should eq(paths.sort)
      result.partial?.should be_false
      result.query.should eq("app")
      result.root.should eq(root.expand)
    end
  end

  it "bounds entries, depth, path storage, results, and query length" do
    with_quick_open_workspace do |root|
      Dir.mkdir_p(root / "level-0" / "level-1")
      File.write(root / "one.txt", "")
      File.write(root / "two.txt", "")
      File.write(root / "three.txt", "")
      File.write(root / "level-0" / "level-1" / "deep.txt", "")
      File.write(root / ("x" * 80), "")

      limits = quick_open_test_limits(
        max_entries: 2,
        max_depth: 1,
        max_path_bytes: 32,
        max_query_codepoints: 4,
        max_results: 1,
        max_retained_path_bytes: 512,
        checkpoint_interval: 1
      )
      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 9_u64, limits: limits)

      index.entries_seen.should eq(2)
      index.entries.size.should be <= 2
      index.retained_path_bytes.should be <= 512
      index.partial?.should be_true
      index.entries.all? { |entry| entry.relative_path.bytesize <= 32 }.should be_true

      one_result = Adamantine::QuickOpenSearch.rank_file_paths(index, "", generation: 9_u64, limits: limits)
      one_result.matches.size.should be <= 1

      too_long = Adamantine::QuickOpenSearch.rank_file_paths(index, "12345", generation: 9_u64, limits: limits)
      too_long.matches.should be_empty
      too_long.query.should be_nil
      too_long.query_too_long?.should be_true
      too_long.partial?.should be_true
    end
  end

  it "preserves partial state even when no query matches" do
    with_quick_open_workspace do |root|
      3.times { |index| File.write(root / "entry-#{index}.txt", "") }
      limits = quick_open_test_limits(max_entries: 1, checkpoint_interval: 1)
      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 4_u64, limits: limits)
      result = Adamantine::QuickOpenSearch.rank_file_paths(index, "never-matches", generation: 4_u64, limits: limits)

      result.matches.should be_empty
      result.partial?.should be_true
      result.cancelled?.should be_false
    end
  end

  it "charges pending directory paths against the retained-path budget" do
    with_quick_open_workspace do |root|
      20.times { |index| Dir.mkdir(root / "directory-#{index}") }
      limits = quick_open_test_limits(max_retained_path_bytes: 256)
      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 5_u64, limits: limits)

      index.entries.should be_empty
      index.entries_seen.should be < 20
      index.retained_path_bytes.should be <= 256
      index.partial?.should be_true
    end
  end

  it "cooperatively checkpoints and reports cancellation during indexing and ranking" do
    with_quick_open_workspace do |root|
      4.times { |index| File.write(root / "entry-#{index}.txt", "") }
      limits = quick_open_test_limits(checkpoint_interval: 1)

      index_cancel = Adamantine::QuickOpenSearch::Cancellation.new
      index_checkpoints = 0
      index = Adamantine::QuickOpenSearch.index_file_paths(
        root,
        generation: 12_u64,
        limits: limits,
        cancellation: index_cancel,
        checkpoint: -> {
          index_checkpoints += 1
          index_cancel.cancel if index_checkpoints == 1
        }
      )
      index_checkpoints.should be >= 1
      index.cancelled?.should be_true
      index.partial?.should be_true

      complete = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 13_u64, limits: limits)
      rank_cancel = Adamantine::QuickOpenSearch::Cancellation.new
      rank_checkpoints = 0
      ranked = Adamantine::QuickOpenSearch.rank_file_paths(
        complete,
        "entry",
        generation: 13_u64,
        limits: limits,
        cancellation: rank_cancel,
        checkpoint: -> {
          rank_checkpoints += 1
          rank_cancel.cancel if rank_checkpoints == 1
        }
      )
      rank_checkpoints.should be >= 1
      ranked.matches.should be_empty
      ranked.cancelled?.should be_true
      ranked.partial?.should be_true
    end
  end

  it "rejects a missing or non-directory root as an explicit partial result" do
    with_quick_open_workspace do |root|
      missing = root / "missing"
      index = Adamantine::QuickOpenSearch.index_file_paths(missing, generation: 21_u64)

      index.entries.should be_empty
      index.entries_seen.should eq(0)
      index.partial?.should be_true
      index.cancelled?.should be_false
      index.root.should eq(missing.expand)
    end
  end
end
