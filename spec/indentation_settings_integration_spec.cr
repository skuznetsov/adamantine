require "spec"
require "file_utils"
require "../src/adamantine/app"

private class IndentationSettingsApp < Adamantine::App
  def open_editor(path : Path) : Adamantine::EditingTextEditor
    raise "could not open fixture" unless open_file(path)
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def change_setting(action : String) : Nil
    open_settings_dialog
    index = @settings.actions.index(action) || raise "missing settings row: #{action}"
    set_settings_selection(index)
    raise "setting not handled" unless execute_selected_settings_action
    close_settings_dialog
  end

  def reapply_theme : Nil
    apply_theme
  end

  def warnings : Array(String)
    @status_log.entries.select { |entry| entry.level == Tui::Log::Level::Warning }.map(&.message)
  end
end

private def with_indentation_settings(config : String, &)
  root = Path.new(Dir.tempdir, "adamantine-indent-settings-ui-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "config.json"
  File.write(path, config)
  ["first.txt", "second.txt", "third.txt"].each { |name| File.write(root / name, "  sample") }
  app = IndentationSettingsApp.new(root, lsp_command: "", keymap_path: path.to_s,
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new)
  yield app, root, path
ensure
  FileUtils.rm_rf(root) if root
end

describe "indentation settings integration" do
  it "updates existing and future editors, persists changes, and survives theme application" do
    with_indentation_settings(%({"editor":{"indent_width":4,"auto_indent":false},"plugin":"keep"})) do |app, root, path|
      first = app.open_editor(root / "first.txt")
      second = app.open_editor(root / "second.txt")
      first.tab_size.should eq 4
      second.auto_indent.should be_false

      app.change_setting("setting:editor.indent_width")
      app.change_setting("setting:editor.auto_indent")
      third = app.open_editor(root / "third.txt")
      app.reapply_theme
      [first, second, third].each do |editor|
        editor.tab_size.should eq 5
        editor.auto_indent.should be_true
        editor.text.should eq "  sample"
        editor.modified?.should be_false
        editor.can_undo?.should be_false
      end
      config = JSON.parse(File.read(path))
      config["editor"]["indent_width"].as_i.should eq 5
      config["editor"]["auto_indent"].as_bool.should be_true
      config["plugin"].as_s.should eq "keep"
    end
  end

  it "wraps width at eight and retains runtime settings if config saving fails" do
    with_indentation_settings(%({"editor":{"indent_width":8,"auto_indent":true}})) do |app, root, path|
      editor = app.open_editor(root / "first.txt")
      # Corrupt only our fixture after load to exercise fail-safe persistence.
      File.write(path, "{broken")
      app.change_setting("setting:editor.indent_width")
      app.change_setting("setting:editor.auto_indent")
      editor.tab_size.should eq 1
      editor.auto_indent.should be_false
      File.read(path).should eq "{broken"
      app.warnings.any?(&.includes?("not saved")).should be_true
      app.open_editor(root / "second.txt").tab_size.should eq 1
    end
  end
end
