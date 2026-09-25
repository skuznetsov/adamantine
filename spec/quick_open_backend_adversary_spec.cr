require "spec"
require "file_utils"
require "../src/adamantine/quick_open_search"

private def with_quick_open_backend_adversary(&)
  root = Path.new(Dir.tempdir, "adamantine-quick-open-backend-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe "parent quick-open backend bounds" do
  it "charges directories against traversal limits even when no files exist" do
    with_quick_open_backend_adversary do |root|
      12.times { |i| Dir.mkdir(root / "directory-#{i}") }
      limits = Adamantine::QuickOpenSearch::Limits.new(max_entries: 3)
      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 1_u64, limits: limits)
      index.entries.should be_empty
      index.entries_seen.should eq(3)
      index.partial?.should be_true
      result = Adamantine::QuickOpenSearch.rank_file_paths(index, "missing", generation: 2_u64)
      result.matches.should be_empty
      result.partial?.should be_true
    end
  end

  it "bounds aggregate retained path storage independently of file count" do
    with_quick_open_backend_adversary do |root|
      20.times { |i| File.write(root / "candidate-#{i}.cr", "") }
      limits = Adamantine::QuickOpenSearch::Limits.new(max_retained_path_bytes: 512)
      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 1_u64, limits: limits)
      index.entries.should_not be_empty
      index.entries.size.should be < 20
      index.retained_path_bytes.should be <= 512
      index.partial?.should be_true
    end
  end

  it "does not follow symlink directories" do
    with_quick_open_backend_adversary do |root|
      real = root / "real"
      Dir.mkdir(real)
      File.write(real / "visible.cr", "")
      File.symlink(real, root / "alias")
      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 1_u64)
      paths = index.entries.map(&.relative_path)
      paths.should eq(["real/visible.cr"])
    end
  end

  it "observes pre-cancellation and clamps hostile result limits" do
    with_quick_open_backend_adversary do |root|
      File.write(root / "candidate.cr", "")
      cancellation = Adamantine::QuickOpenSearch::Cancellation.new
      cancellation.cancel
      cancelled = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 1_u64, cancellation: cancellation)
      cancelled.entries.should be_empty
      cancelled.cancelled?.should be_true
      cancelled.partial?.should be_true

      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 2_u64)
      Adamantine::QuickOpenSearch.rank_file_paths(index, "", generation: 3_u64, max_results: -1).matches.should be_empty
      result = Adamantine::QuickOpenSearch.rank_file_paths(index, "", generation: 4_u64, max_results: Int32::MAX)
      result.matches.size.should eq(1)
      result.generation.should eq(4_u64)
      result.root.should eq(root.expand)
    end
  end

  it "ranks uppercase basenames case-insensitively ahead of directory-only prefixes" do
    with_quick_open_backend_adversary do |root|
      Dir.mkdir(root / "application")
      File.write(root / "application" / "manual.cr", "")
      File.write(root / "APP.cr", "")
      index = Adamantine::QuickOpenSearch.index_file_paths(root, generation: 1_u64)
      result = Adamantine::QuickOpenSearch.rank_file_paths(index, "app", generation: 1_u64)
      result.matches.first.relative_path.should eq("APP.cr")
    end
  end
end
