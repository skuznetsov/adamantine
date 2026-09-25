require "spec"
require "file_utils"
require "../src/adamantine/app"

private class ConfigAdversaryApp < Adamantine::App
  def open_public(path : Path) : Adamantine::EditingTextEditor
    raise "fixture open failed" unless open_file(path)
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def theme_public : Nil
    apply_theme
  end

  def width_public : Nil
    open_settings_dialog
    set_settings_selection(@settings.actions.index("setting:editor.indent_width").not_nil!)
    execute_selected_settings_action
    close_settings_dialog
  end
end

private def with_config_adversary(&)
  root = Path.new(Dir.tempdir, "adamantine-config-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root / "nested")
  File.write(root / "config.json", %({"editor":{"indent_width":2}}))
  app = ConfigAdversaryApp.new(root, lsp_command: "", keymap_path: (root / "config.json").to_s,
    recovery_root: root / "recovery", clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new)
  yield app, root
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

describe "EditorConfig adversarial integration" do
  it "keeps per-file overrides across global settings and theme changes without modifying bytes" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\n[*.cr]\nindent_size=4\nend_of_line=crlf\n")
      original = "a\r\nb\nc\r"
      File.write(root / "code.cr", original)
      File.write(root / "note.txt", "note")
      code = app.open_public(root / "code.cr")
      note = app.open_public(root / "note.txt")
      code.set_cursor(1, 1)
      app.width_public
      app.theme_public
      code.tab_size.should eq 4
      note.tab_size.should eq 3
      code.text.should eq original
      code.modified?.should be_false
      code.can_undo?.should be_false
      code.cursor_line.should eq 1
      code.cursor_col.should eq 1
      File.read(root / "code.cr").should eq original
      code.insert_newline
      code.text.should eq "a\r\nb\r\n\nc\r"
      code.undo
      code.text.should eq original
      code.modified?.should be_false
      code.save.should be_true
      File.read(root / "code.cr").should eq original
    end
  end

  it "inserts the requested visual indentation at a nonzero caret" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\n[*]\nindent_style=tab\nindent_size=4\ntab_width=3\n")
      File.write(root / "code.cr", "a")
      code = app.open_public(root / "code.cr")
      code.set_cursor(0, 1)
      code.indent
      code.text.should eq "a\t  "
      code.undo
      code.text.should eq "a"
      code.modified?.should be_false
    end
  end

  it "does not let invalid nearest values erase valid ancestor settings" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\n[*.cr]\nindent_size=6\n")
      File.write(root / "nested/.editorconfig", "[*.cr]\nindent_size=99999999999999999999\n")
      File.write(root / "nested/code.cr", "a")
      app.open_public(root / "nested/code.cr").tab_size.should eq 6
    end
  end

  it "honors unset and nested root without modifying project configuration" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\n[*]\nindent_size=6\n")
      config = "root=true\n[*]\nindent_size=4\n[*.cr]\nindent_size=unset\n"
      File.write(root / "nested/.editorconfig", config)
      File.write(root / "nested/code.cr", "a")
      app.open_public(root / "nested/code.cr").tab_size.should eq 2
      app.width_public
      File.read(root / "nested/.editorconfig").should eq config
    end
  end

  it "ignores non-root preamble properties and requires exactly one character for question globs" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\nindent_size=8\n[b?.cr]\nindent_size=7\n")
      File.write(root / "beta.cr", "a")
      app.open_public(root / "beta.cr").tab_size.should eq 2
      File.write(root / "ba.cr", "a")
      app.open_public(root / "ba.cr").tab_size.should eq 7
    end
  end

  it "dedents a tab-space unit as one command and restores it with Undo" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\n[*]\nindent_style=tab\nindent_size=4\ntab_width=3\n")
      File.write(root / "code.cr", "x")
      code = app.open_public(root / "code.cr")
      code.indent
      code.text.should eq "\t x"
      code.dedent
      code.text.should eq "x"
      code.undo
      code.text.should eq "\t x"
      code.undo
      code.text.should eq "x"
    end
  end

  it "reapplies a changed configuration without consuming existing Undo history" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\n[*]\nindent_size=4\n")
      File.write(root / "code.cr", "x")
      code = app.open_public(root / "code.cr")
      code.insert_text("z")
      File.write(root / ".editorconfig", "root=true\n[*]\nindent_size=6\nend_of_line=cr\n")
      app.theme_public
      code.text.should eq "zx"
      code.modified?.should be_true
      code.undo.should be_true
      code.text.should eq "x"
      code.modified?.should be_false
      code.indent
      code.text.should eq "      x"
      File.read(root / "code.cr").should eq "x"
    end
  end

  it "does not reinterpret character classes as regex ranges or inline comments" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\n[*]\nindent_size=4\n[[a-c].cr]\nindent_size=7\n[*.txt]\nindent_size=6 # comment\n")
      File.write(root / "b.cr", "x")
      File.write(root / "-.cr", "x")
      File.write(root / "a.txt", "x")
      app.open_public(root / "b.cr").tab_size.should eq 4
      app.open_public(root / "-.cr").tab_size.should eq 7
      app.open_public(root / "a.txt").tab_size.should eq 4
    end
  end

  it "matches Unicode paths and patterns using character-safe indexes" do
    with_config_adversary do |app, root|
      Dir.mkdir_p(root / "папка")
      File.write(root / "папка/.editorconfig", "root=true\n[🙂*.cr]\nindent_size=5\n")
      File.write(root / "папка/🙂код.cr", "x")
      app.open_public(root / "папка/🙂код.cr").tab_size.should eq 5
    end
  end

  it "uses tab_width for indent_size=tab without implying tab-style insertion" do
    with_config_adversary do |app, root|
      File.write(root / ".editorconfig", "root=true\n[*]\nindent_size=tab\ntab_width=6\n")
      File.write(root / "code.cr", "x")
      code = app.open_public(root / "code.cr")
      code.indent
      code.text.should eq "      x"
    end
  end

  it "does not let recursive directory globs consume part of a basename" do
    with_config_adversary do |app, root|
      Dir.mkdir_p(root / "src/deep")
      File.write(root / ".editorconfig", "root=true\n[src/**/beta.cr]\nindent_size=7\n")
      File.write(root / "src/notbeta.cr", "x")
      File.write(root / "src/beta.cr", "x")
      File.write(root / "src/deep/beta.cr", "x")
      app.open_public(root / "src/notbeta.cr").tab_size.should eq 2
      app.open_public(root / "src/beta.cr").tab_size.should eq 7
      app.open_public(root / "src/deep/beta.cr").tab_size.should eq 7
    end
  end

  it "bounds cumulative pattern matching and warns rather than claiming complete resolution" do
    with_config_adversary do |_app, root|
      pattern = "?" * 200 + "*"
      File.write(root / ".editorconfig", "root=true\n" + ("[#{pattern}]\nindent_size=4\n" * 64))
      result = Adamantine::EditorConfig.resolve(root / ("a" * 200 + ".cr"), 2)
      result.warnings.any?(&.includes?("work limit")).should be_true
      result.warnings.size.should be <= Adamantine::EditorConfig::MAX_WARNINGS
    end
  end
end
