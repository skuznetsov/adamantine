require "spec"
require "file_utils"

require "../src/adamantine/editor_config"

private def with_editor_config_workspace(prefix : String = "adamantine-editor-config-spec", &)
  root = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def write_editor_config(path : Path, content : String)
  File.write(path.to_s, content)
end

describe Adamantine::EditorConfig do
  it "applies farthest ancestors first and later matching sections last" do
    with_editor_config_workspace do |root|
      nested = root / "lib" / "deep"
      Dir.mkdir_p(nested)
      target = nested / "main.cr"
      File.write(target.to_s, "puts 1\n")

      write_editor_config(root / ".editorconfig", <<-CONFIG)
        root = true

        [*.cr]
        indent_style = tab
        indent_size = 4
        tab_width = 8

        [*.cr]
        indent_size = 2

        [*.cr]
        end_of_line = crlf
      CONFIG
      write_editor_config(root / "lib" / ".editorconfig", <<-CONFIG)
        [*.cr]
        indent_size = 3

        [deep/*.cr]
        indent_size = 5
      CONFIG

      result = Adamantine::EditorConfig.resolve(target, 2)
      result.indent_style.should eq("tab")
      result.indent_size.should eq(5)
      result.indent_size_tab.should be_false
      result.tab_width.should eq(8)
      result.end_of_line.should eq("crlf")
      result.warnings.should be_empty
    end
  end

  it "stops at root and lets unset remove inherited supported values" do
    with_editor_config_workspace do |root|
      nested = root / "project" / "src"
      Dir.mkdir_p(nested)
      target = nested / "sample.cr"
      File.write(target.to_s, "")

      write_editor_config(root / ".editorconfig", <<-CONFIG)
        [*.cr]
        indent_style = tab
        indent_size = 6
        tab_width = 7
        end_of_line = cr
      CONFIG
      write_editor_config(root / "project" / ".editorconfig", <<-CONFIG)
        root = true
        [*.cr]
        indent_style = unset
        indent_size = tab
        tab_width = 9
        end_of_line = invalid
      CONFIG

      result = Adamantine::EditorConfig.resolve(target, 2)
      result.indent_style.should be_nil
      result.indent_size.should be_nil
      result.indent_size_tab.should be_true
      result.tab_width.should be_nil
      result.end_of_line.should be_nil
      result.warnings.size.should eq(2)
      result.warnings.join(" ").should contain("tab_width")
      result.warnings.join(" ").should contain("end_of_line")
    end
  end

  it "matches basename, recursive, question, class, and brace-list globs" do
    with_editor_config_workspace do |root|
      nested = root / "src" / "deep"
      Dir.mkdir_p(nested)
      target = nested / "beta.cr"
      File.write(target.to_s, "")

      write_editor_config(root / ".editorconfig", <<-CONFIG)
        root = true
        [*.cr]
        indent_size = 2
        [**/*.cr]
        indent_size = 3
        [src/**/b???.cr]
        indent_size = 4
        [{alpha,beta}.cr]
        tab_width = 6
        [b[ae]ta.cr]
        end_of_line = cr
      CONFIG

      result = Adamantine::EditorConfig.resolve(target, 2)
      result.indent_size.should eq(4)
      result.tab_width.should eq(6)
      result.end_of_line.should eq("cr")
      result.warnings.should be_empty
    end
  end

  it "rejects numeric brace expansion instead of applying it broadly" do
    with_editor_config_workspace do |root|
      target = root / "value2.cr"
      File.write(target.to_s, "")
      write_editor_config(root / ".editorconfig", <<-CONFIG)
        root = true
        [value{1..999999}.cr]
        indent_size = 8
      CONFIG

      result = Adamantine::EditorConfig.resolve(target, 2)
      result.indent_size.should be_nil
      result.warnings.join(" ").should contain("brace")
    end
  end

  it "preserves valid ancestor settings when a nearer config is oversized" do
    with_editor_config_workspace do |root|
      nested = root / "src"
      Dir.mkdir_p(nested)
      target = nested / "main.cr"
      File.write(target.to_s, "")
      write_editor_config(root / ".editorconfig", <<-CONFIG)
        root = true
        [*.cr]
        indent_size = 6
      CONFIG

      oversized = "#" + ("x" * Adamantine::EditorConfig::MAX_FILE_BYTES)
      write_editor_config(nested / ".editorconfig", oversized)

      result = Adamantine::EditorConfig.resolve(target, 2)
      result.indent_size.should eq(6)
      result.warnings.join(" ").should contain("exceeds")
    end
  end

  it "ignores non-regular editorconfig paths and bounds an overlong target path" do
    with_editor_config_workspace do |root|
      target_dir = root / ".editorconfig"
      Dir.mkdir(target_dir)
      result = Adamantine::EditorConfig.resolve(root / "sample.cr", 2)
      result.indent_size.should be_nil
      result.warnings.join(" ").should contain("regular")
    end

    long_path = Path.new("/tmp" + ("/x" * 2050) + ".cr")
    result = Adamantine::EditorConfig.resolve(long_path, 2)
    result.indent_size.should be_nil
    result.warnings.join(" ").should contain("path")
  end

  it "does not treat braces inside a character class or a colon as supported syntax" do
    with_editor_config_workspace do |root|
      write_editor_config(root / ".editorconfig", <<-CONFIG)
        root = true
        [[{,a}].cr]
        indent_size = 7
      CONFIG
      brace_target = root / "{.cr"
      colon_target = root / "plain.cr"
      File.write(brace_target.to_s, "")
      File.write(colon_target.to_s, "")

      brace_result = Adamantine::EditorConfig.resolve(brace_target, 2)
      brace_result.indent_size.should eq(7)
      brace_result.warnings.should be_empty

      write_editor_config(root / ".editorconfig", <<-CONFIG)
        root = true
        [*.cr]
        indent_size: 8
      CONFIG
      colon_result = Adamantine::EditorConfig.resolve(colon_target, 2)
      colon_result.indent_size.should be_nil
      colon_result.warnings.join(" ").should contain("malformed")
    end
  end

  it "does not allow a late root marker after a malformed section header" do
    with_editor_config_workspace do |root|
      nested = root / "nested"
      Dir.mkdir_p(nested)
      target = nested / "main.cr"
      File.write(target.to_s, "")
      write_editor_config(root / ".editorconfig", <<-CONFIG)
        root = true
        [*.cr]
        indent_size = 6
      CONFIG
      write_editor_config(nested / ".editorconfig", "[broken\nroot = true\n")

      result = Adamantine::EditorConfig.resolve(target, 2)
      result.indent_size.should eq(6)
      result.warnings.join(" ").should contain("malformed")
    end
  end
end
