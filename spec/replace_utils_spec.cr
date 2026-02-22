require "spec"
require "../src/editor/replace_utils"

describe CrystalEditor::ReplaceUtils do
  describe ".parse_replace_arguments" do
    it "parses default replace command" do
      result = CrystalEditor::ReplaceUtils.parse_replace_arguments("/old/new/")
      raise "expected parsed arguments" unless result
      old_text, new_text, flags = result
      raise "wrong old text" unless old_text == "old"
      raise "wrong new text" unless new_text == "new"
      raise "wrong flags" unless !flags.global && !flags.ignore_case && !flags.preview
    end

    it "parses flags" do
      result = CrystalEditor::ReplaceUtils.parse_replace_arguments("/old/new/ gic")
      raise "expected parsed arguments" unless result
      old_text, new_text, flags = result
      raise "wrong flags" unless flags.global && flags.ignore_case && flags.preview
    end

    it "rejects unsupported flags" do
      result = CrystalEditor::ReplaceUtils.parse_replace_arguments("/old/new/x")
      raise "expected nil" unless result.nil?
    end

    it "handles escaped delimiter" do
      result = CrystalEditor::ReplaceUtils.parse_replace_arguments("/old\\/old/new/")
      raise "expected parsed arguments" unless result
      old_text, new_text, flags = result
      raise "wrong old text" unless old_text == "old/old"
      raise "wrong new text" unless new_text == "new"
      raise "wrong flags" unless !flags.global && !flags.ignore_case && !flags.preview
    end

    it "accepts empty replacement text" do
      result = CrystalEditor::ReplaceUtils.parse_replace_arguments("/old//g")
      raise "expected parsed arguments" unless result
      old_text, new_text, flags = result
      raise "wrong old text" unless old_text == "old"
      raise "wrong new text" unless new_text.empty?
      raise "wrong flags" unless flags.global
    end
  end

  describe ".replace_text_content" do
    it "replaces first occurrence by default" do
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new
      replaced = CrystalEditor::ReplaceUtils.replace_text_content("a b a b", "a", "x", flags)
      raise "wrong replaced" unless replaced == "x b a b"
    end

    it "replaces all occurrences with global flag" do
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new(global: true)
      replaced = CrystalEditor::ReplaceUtils.replace_text_content("a b a b", "a", "x", flags)
      raise "wrong replaced" unless replaced == "x b x b"
    end

    it "ignores case when requested" do
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new(ignore_case: true, global: true)
      replaced = CrystalEditor::ReplaceUtils.replace_text_content("Ab c aB", "ab", "x", flags)
      raise "wrong replaced" unless replaced == "x c x"
    end

    it "handles escaped pattern as plain text" do
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new(global: true)
      replaced = CrystalEditor::ReplaceUtils.replace_text_content("a/b a/b", "a/b", "x", flags)
      raise "wrong replaced" unless replaced == "x x"
    end
  end

  describe ".replace_match_count" do
    it "counts occurrences with global flag and ignore case" do
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new(global: true, ignore_case: true)
      count = CrystalEditor::ReplaceUtils.replace_match_count("AbAb", "ab", flags)
      raise "wrong count" unless count == 2
    end
  end

  describe ".make_replace_previews" do
    it "reports line and columns for matches" do
      text = "one foo two\nfoo three"
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new
      output = CrystalEditor::ReplaceUtils.make_replace_previews(text, "foo", "bar", 2, flags)
      raise "wrong preview count" unless output.size == 2
      raise "missing line info" unless output[0].starts_with?("1) L1:5")
      raise "missing second line info" unless output[1].starts_with?("2) L2:1")
      raise "missing match highlight" unless output[0].includes?("[foo]")
    end

    it "handles long lines with truncation" do
      text = "#{"a" * 120}\n"
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new
      output = CrystalEditor::ReplaceUtils.make_replace_previews(text, "a", "x", 1, flags)
      raise "expected preview" unless output.size == 1
    end

    it "highlights unicode safely" do
      text = "😀 old ✅\n"
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new
      output = CrystalEditor::ReplaceUtils.make_replace_previews(text, "old", "new", 10, flags)
      raise "expected one line preview" unless output.size == 1
      raise "missing unicode context" unless output[0].includes?("[old]")
    end

    it "respects preview limit" do
      text = "old old old old old"
      flags = CrystalEditor::ReplaceUtils::ReplaceFlags.new(global: true)
      output = CrystalEditor::ReplaceUtils.make_replace_previews(text, "old", "x", 2, flags)
      raise "expected limit respected" unless output.size == 2
    end
  end

  describe ".flags_to_label" do
    it "returns readable labels for all flag combos" do
      raise "wrong single label" unless CrystalEditor::ReplaceUtils.flags_to_label(CrystalEditor::ReplaceUtils::ReplaceFlags.new) == "single"
      raise "wrong ignore label" unless CrystalEditor::ReplaceUtils.flags_to_label(CrystalEditor::ReplaceUtils::ReplaceFlags.new(ignore_case: true)) == "first (ignore case)"
      raise "wrong global label" unless CrystalEditor::ReplaceUtils.flags_to_label(CrystalEditor::ReplaceUtils::ReplaceFlags.new(global: true)) == "all (global)"
      raise "wrong all ignore label" unless CrystalEditor::ReplaceUtils.flags_to_label(CrystalEditor::ReplaceUtils::ReplaceFlags.new(global: true, ignore_case: true)) == "all (global, ignore case)"
    end
  end
end
