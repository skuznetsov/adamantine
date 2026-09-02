require "spec"
require "file_utils"

require "../src/adamantine/project_search"

def with_temp_workspace(prefix : String = "project-search-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::ProjectSearch do
  it "finds a literal match across nested files" do
    with_temp_workspace do |tmp_dir|
      Dir.mkdir_p(tmp_dir / "src")
      File.write(tmp_dir / "src" / "a.cr", "hello\nunique_token_alpha\n")
      File.write(tmp_dir / "readme.txt", "nothing here\n")

      result = Adamantine::ProjectSearch.search(tmp_dir, "unique_token_alpha")
      raise "expected one match" unless result.matches.size == 1
      match = result.matches[0]
      raise "wrong file" unless match.path.basename == "a.cr"
      raise "wrong line" unless match.line == 1
      raise "wrong column" unless match.col == 0
    end
  end

  it "skips VCS directories" do
    with_temp_workspace do |tmp_dir|
      git_dir = tmp_dir / ".git"
      Dir.mkdir_p(git_dir)
      File.write(git_dir / "hidden.txt", "unique_token_git\n")
      File.write(tmp_dir / "visible.txt", "unique_token_git visible\n")

      result = Adamantine::ProjectSearch.search(tmp_dir, "unique_token_git")
      raise "git file must not be searched, got #{result.matches.map(&.path.to_s)}" unless result.matches.size == 1
      raise "expected visible.txt" unless result.matches[0].path.basename == "visible.txt"
    end
  end

  it "supports case-insensitive search" do
    with_temp_workspace do |tmp_dir|
      File.write(tmp_dir / "a.txt", "CamelCaseNeedle\n")
      sensitive = Adamantine::ProjectSearch.search(tmp_dir, "camelcaseneedle")
      raise "case-sensitive search should miss" unless sensitive.matches.empty?

      insensitive = Adamantine::ProjectSearch.search(tmp_dir, "camelcaseneedle", ignore_case: true)
      raise "case-insensitive search should hit" unless insensitive.matches.size == 1
    end
  end

  it "finds all matches in a buffer" do
    matches = Adamantine::ProjectSearch.search_text("alpha\nbeta\nbeta\n", "beta")
    raise "expected two matches" unless matches.size == 2
    raise "first match should be on line 1" unless matches[0].line == 1
    raise "second match should be on line 2" unless matches[1].line == 2
  end

  it "returns no matches for an empty needle" do
    with_temp_workspace do |tmp_dir|
      File.write(tmp_dir / "a.txt", "content\n")
      result = Adamantine::ProjectSearch.search(tmp_dir, "")
      raise "empty needle must not scan as a match" unless result.matches.empty?
      raise "empty needle should not scan files" unless result.files_scanned == 0
    end
  end

  it "skips binary files" do
    with_temp_workspace do |tmp_dir|
      File.open(tmp_dir / "blob.bin", "wb") do |file|
        file.write(Bytes[0, 1, 2, 3, 4])
      end
      File.write(tmp_dir / "ok.txt", "needle_in_text\n")
      result = Adamantine::ProjectSearch.search(tmp_dir, "needle_in_text")
      raise "binary should be skipped" unless result.matches.size == 1
      raise "expected ok.txt" unless result.matches[0].path.basename == "ok.txt"
    end
  end
end
