require "spec"
require "json"
require "file_utils"
require "crystal_tui"
require "../src/editor/app"

def with_temp_workspace(prefix : String = "editor-theme-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::Theme do
  # Preset resolution

  it "loads vscode-dark preset" do
    CrystalEditor::Theme.reset
    result = CrystalEditor::Theme.load("vscode-dark")
    raise "expected true" unless result
    raise "expected vscode-dark name" unless CrystalEditor::Theme.name == "vscode-dark"
  end

  it "resolves 'dark' alias to vscode-dark" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("dark")
    raise "expected vscode-dark" unless CrystalEditor::Theme.name == "vscode-dark"
  end

  it "loads vscode-light preset" do
    CrystalEditor::Theme.reset
    result = CrystalEditor::Theme.load("vscode-light")
    raise "expected true" unless result
    raise "expected vscode-light" unless CrystalEditor::Theme.name == "vscode-light"
  end

  it "resolves 'light' alias to vscode-light" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("light")
    raise "expected vscode-light" unless CrystalEditor::Theme.name == "vscode-light"
  end

  it "loads vscode-high-contrast preset" do
    CrystalEditor::Theme.reset
    result = CrystalEditor::Theme.load("vscode-high-contrast")
    raise "expected true" unless result
    raise "expected vscode-high-contrast" unless CrystalEditor::Theme.name == "vscode-high-contrast"
  end

  it "resolves 'hc' alias to vscode-high-contrast" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("hc")
    raise "expected vscode-high-contrast" unless CrystalEditor::Theme.name == "vscode-high-contrast"
  end

  it "falls back to vscode-dark for invalid preset name" do
    CrystalEditor::Theme.reset
    result = CrystalEditor::Theme.load("nonexistent-theme-xyz")
    raise "expected false" if result
    raise "expected vscode-dark fallback" unless CrystalEditor::Theme.name == "vscode-dark"
  end

  it "returns false for nil path" do
    CrystalEditor::Theme.reset
    result = CrystalEditor::Theme.load(nil)
    raise "expected false" if result
  end

  it "rejects names with path traversal characters" do
    CrystalEditor::Theme.reset
    result = CrystalEditor::Theme.load("../evil")
    raise "expected false for path traversal" if result

    result2 = CrystalEditor::Theme.load("theme.json")
    raise "expected false for dotted name" if result2
  end

  # Color lookup

  it "returns correct color for known key after vscode-dark" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-dark")
    color = CrystalEditor::Theme.color("editor.text_fg")
    expected = Tui::Color.rgb(212, 212, 212)
    raise "expected editor text fg to be rgb(212,212,212)" unless color == expected
  end

  it "returns default color for unknown key" do
    CrystalEditor::Theme.reset
    color = CrystalEditor::Theme.color("nonexistent.key")
    raise "expected default color" unless color == Tui::Color.default
  end

  # Module accessors

  it "provides editor colors via Theme::Editor module" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-dark")
    raise "editor text_fg should match" unless CrystalEditor::Theme::Editor.text_fg == Tui::Color.rgb(212, 212, 212)
    raise "editor text_bg should match" unless CrystalEditor::Theme::Editor.text_bg == Tui::Color.rgb(30, 30, 30)
  end

  it "provides popup colors via Theme::Popup module" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-dark")
    raise "popup text should be non-default" unless CrystalEditor::Theme::Popup.text != Tui::Color.default
  end

  # Preset names

  it "returns sorted deduplicated preset names" do
    names = CrystalEditor::Theme.preset_names
    raise "should include vscode-dark" unless names.includes?("vscode-dark")
    raise "should include vscode-light" unless names.includes?("vscode-light")
    raise "should include vscode-high-contrast" unless names.includes?("vscode-high-contrast")
    raise "should be sorted" unless names == names.sort
    raise "should have no duplicates" unless names.size == names.uniq.size
  end

  # Diagnostic styles

  it "returns error style for severity 1" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-dark")
    base = Tui::Style.new
    style = CrystalEditor::Theme.editor_diagnostic_style(base, 1)
    expected_fg = CrystalEditor::Theme.color("lsp.error_fg")
    raise "severity 1 should use error fg" unless style.fg == expected_fg
  end

  it "returns warning style for severity 2" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-dark")
    base = Tui::Style.new
    style = CrystalEditor::Theme.editor_diagnostic_style(base, 2)
    expected_fg = CrystalEditor::Theme.color("lsp.warning_fg")
    raise "severity 2 should use warning fg" unless style.fg == expected_fg
  end

  it "returns hint style for nil severity" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-dark")
    base = Tui::Style.new
    style = CrystalEditor::Theme.editor_diagnostic_style(base, nil)
    expected_fg = CrystalEditor::Theme.color("lsp.hint_fg")
    raise "nil severity should use hint fg" unless style.fg == expected_fg
  end

  it "applies underline when lsp_use_underline is true" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-dark")
    base = Tui::Style.new
    style = CrystalEditor::Theme.editor_diagnostic_style(base, 1)
    raise "should include underline" unless (style.attrs & Tui::Attributes::Underline) != Tui::Attributes::None
  end

  # Reset

  it "resets to vscode-dark defaults" do
    CrystalEditor::Theme.load("vscode-light")
    raise "should be light before reset" unless CrystalEditor::Theme.name == "vscode-light"
    CrystalEditor::Theme.reset
    raise "should be vscode-dark after reset" unless CrystalEditor::Theme.name == "vscode-dark"
  end

  # JSON file loading

  it "loads theme from JSON file with nested editor colors" do
    with_temp_workspace do |tmp|
      theme_file = tmp / "theme.json"
      File.write(theme_file.to_s, {
        "editor" => {
          "text_fg" => "#FF0000",
        },
      }.to_json)

      CrystalEditor::Theme.reset
      result = CrystalEditor::Theme.load(theme_file.to_s)
      raise "expected true for valid JSON" unless result
      raise "editor text_fg should be red" unless CrystalEditor::Theme::Editor.text_fg == Tui::Color.rgb(255, 0, 0)
    end
  end

  it "loads theme from JSON file with flat keys" do
    with_temp_workspace do |tmp|
      theme_file = tmp / "theme.json"
      File.write(theme_file.to_s, {
        "editor_text_bg" => "#00FF00",
      }.to_json)

      CrystalEditor::Theme.reset
      result = CrystalEditor::Theme.load(theme_file.to_s)
      raise "expected true" unless result
      raise "editor text_bg should be green" unless CrystalEditor::Theme::Editor.text_bg == Tui::Color.rgb(0, 255, 0)
    end
  end

  it "loads color from array format [r, g, b]" do
    with_temp_workspace do |tmp|
      theme_file = tmp / "theme.json"
      File.write(theme_file.to_s, {
        "editor" => {
          "cursor_fg" => [128, 64, 32],
        },
      }.to_json)

      CrystalEditor::Theme.reset
      CrystalEditor::Theme.load(theme_file.to_s)
      raise "cursor_fg should match array" unless CrystalEditor::Theme::Editor.cursor_fg == Tui::Color.rgb(128, 64, 32)
    end
  end

  it "loads color from object format {r, g, b}" do
    with_temp_workspace do |tmp|
      theme_file = tmp / "theme.json"
      File.write(theme_file.to_s, {
        "editor" => {
          "cursor_bg" => {"r" => 10, "g" => 20, "b" => 30},
        },
      }.to_json)

      CrystalEditor::Theme.reset
      CrystalEditor::Theme.load(theme_file.to_s)
      raise "cursor_bg should match object" unless CrystalEditor::Theme::Editor.cursor_bg == Tui::Color.rgb(10, 20, 30)
    end
  end

  it "falls back gracefully on invalid JSON" do
    with_temp_workspace do |tmp|
      theme_file = tmp / "theme.json"
      File.write(theme_file.to_s, "not valid json {{{")

      CrystalEditor::Theme.reset
      result = CrystalEditor::Theme.load(theme_file.to_s)
      raise "expected false for invalid JSON" if result
      raise "should fall back to vscode-dark" unless CrystalEditor::Theme.name == "vscode-dark"
    end
  end

  it "rejects oversized theme files" do
    with_temp_workspace do |tmp|
      theme_file = tmp / "theme.json"
      payload = {"editor" => {"text_bg" => "#000000"}}.to_json
      overflow = "{" * (CrystalEditor::Theme::MAX_THEME_FILE_BYTES + 1 - payload.bytesize)
      File.write(theme_file.to_s, payload + overflow)

      CrystalEditor::Theme.reset
      result = CrystalEditor::Theme.load(theme_file.to_s)
      raise "expected false for oversized theme file" if result
      raise "should fall back to vscode-dark" unless CrystalEditor::Theme.name == "vscode-dark"
    end
  end

  it "skips malformed color strings without crashing" do
    with_temp_workspace do |tmp|
      theme_file = tmp / "theme.json"
      File.write(theme_file.to_s, {
        "editor" => {
          "text_fg"   => "#ZZZZZZ",
          "cursor_fg" => "#FF0000",
        },
      }.to_json)

      CrystalEditor::Theme.reset
      result = CrystalEditor::Theme.load(theme_file.to_s)
      raise "should load without crash" unless result
      raise "cursor_fg should still be set" unless CrystalEditor::Theme::Editor.cursor_fg == Tui::Color.rgb(255, 0, 0)
    end
  end

  it "loads preset by name in JSON file" do
    with_temp_workspace do |tmp|
      theme_file = tmp / "theme.json"
      File.write(theme_file.to_s, {
        "theme" => {
          "name" => "vscode-light",
        },
      }.to_json)

      CrystalEditor::Theme.reset
      result = CrystalEditor::Theme.load(theme_file.to_s)
      raise "expected true" unless result
      # light theme should have different text_bg than dark
      raise "should load light preset colors" unless CrystalEditor::Theme::Editor.text_bg == Tui::Color.white
    end
  end

  # lsp_underline? accessor

  it "reports lsp_underline? status" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-dark")
    raise "vscode-dark should have underline enabled" unless CrystalEditor::Theme.lsp_underline?
  end
end
