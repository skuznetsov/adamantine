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

  it "stops an in-flight search when it is cancelled" do
    with_temp_workspace do |tmp_dir|
      20.times do |index|
        File.write(tmp_dir / "file-#{index}.txt", "cancel_probe_token\n")
      end

      cancellation = Adamantine::ProjectSearch::Cancellation.new
      spawn do
        10.times { Fiber.yield }
        cancellation.cancel
      end

      result = Adamantine::ProjectSearch.search(tmp_dir, "cancel_probe_token", cancellation: cancellation)

      raise "cancelled search must report cancellation" unless result.cancelled?
      raise "cancelled search must be incomplete" unless result.incomplete?
      raise "probe must cancel after scanning starts" unless result.files_scanned > 0
      raise "cancelled search must stop before scanning the full workspace" unless result.files_scanned < 20
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

  it "skips a binary marker that appears after the initial sample" do
    with_temp_workspace do |tmp_dir|
      File.open(tmp_dir / "late-binary.bin", "wb") do |file|
        file.write(Bytes.new(512, 'a'.ord.to_u8))
        file.write(Bytes[0])
        file.write("needle_after_late_nul\n".to_slice)
      end
      File.write(tmp_dir / "ok.txt", "needle_after_late_nul\n")

      result = Adamantine::ProjectSearch.search(tmp_dir, "needle_after_late_nul")
      raise "late binary marker must exclude the binary file" unless result.matches.size == 1
      raise "expected the text file match" unless result.matches[0].path.basename == "ok.txt"
    end
  end

  it "finds a match after column 4096" do
    line = "a" * 5000 + "needle_after_column_limit"
    matches = Adamantine::ProjectSearch.search_text(line, "needle_after_column_limit")

    raise "expected a match beyond column 4096" unless matches.size == 1
    raise "wrong column for a long line" unless matches[0].col == 5000
  end

  it "does not split a grapheme when truncating snippets" do
    line = "needle " + ("x" * 64) + "e\u0301tail"
    matches = Adamantine::ProjectSearch.search_text(line, "needle")

    raise "expected one match" unless matches.size == 1
    raise "snippet must preserve the final grapheme" unless matches[0].snippet.ends_with?("e\u0301")
  end

  it "marks a depth-limited subtree as truncated" do
    with_temp_workspace do |tmp_dir|
      nested = tmp_dir
      (Adamantine::ProjectSearch::MAX_DEPTH + 1).times do |index|
        nested /= "level-#{index}"
        Dir.mkdir_p(nested)
      end
      File.write(nested / "hidden.txt", "needle_below_depth_limit\n")

      result = Adamantine::ProjectSearch.search(tmp_dir, "needle_below_depth_limit")
      raise "depth-limited match must not be returned" unless result.matches.empty?
      raise "depth omission must mark the result truncated" unless result.truncated
    end
  end

  it "marks an oversized file omission as truncated" do
    with_temp_workspace do |tmp_dir|
      oversized = "needle_in_oversized_file" + ("x" * Adamantine::ProjectSearch::MAX_FILE_BYTES)
      File.write(tmp_dir / "oversized.txt", oversized)

      result = Adamantine::ProjectSearch.search(tmp_dir, "needle_in_oversized_file")
      raise "oversized file must not be searched" unless result.matches.empty?
      raise "oversized-file omission must mark the result truncated" unless result.truncated
    end
  end

  it "marks a missing search root as truncated" do
    with_temp_workspace do |tmp_dir|
      result = Adamantine::ProjectSearch.search(tmp_dir / "missing", "needle")

      raise "missing-root search must return no matches" unless result.matches.empty?
      raise "missing-root traversal omission must mark the result truncated" unless result.truncated
    end
  end
end
