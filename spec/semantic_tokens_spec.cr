require "spec"
require "json"
require "file_utils"
require "crystal_tui"

require "../src/editor/semantic_tokens"
require "../src/editor/theme"

describe CrystalEditor::SemanticOverlay do
  it "returns nil for empty overlay" do
    overlay = CrystalEditor::SemanticOverlay.empty
    raise "empty overlay should have no token" unless overlay.name_at(0, 0).nil?
    raise "empty overlay should report no tokens" if overlay.any_tokens?
  end

  it "decodes a single delta-encoded token" do
    # one token: line 0, col 0, length 3, type keyword (15), modifiers 0
    data = [0, 0, 3, 15, 0]
    overlay = CrystalEditor::SemanticOverlay.build(data, ["def foo"], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    raise "col 0 should be keyword" unless overlay.name_at(0, 0) == "keyword"
    raise "col 2 should be keyword" unless overlay.name_at(0, 2) == "keyword"
    raise "col 3 should be uncolored" unless overlay.name_at(0, 3).nil?
  end

  it "decodes two tokens on the same line with relative start" do
    # "x = 42" → variable at 0 len 1, number at 4 len 2
    data = [0, 0, 1, 8, 0, 0, 4, 2, 19, 0]
    overlay = CrystalEditor::SemanticOverlay.build(data, ["x = 42"], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    raise "x should be variable" unless overlay.name_at(0, 0) == "variable"
    raise "space should be uncolored" unless overlay.name_at(0, 1).nil?
    raise "4 should be number" unless overlay.name_at(0, 4) == "number"
    raise "2 should be number" unless overlay.name_at(0, 5) == "number"
  end

  it "decodes tokens on a later line using deltaLine" do
    data = [1, 2, 3, 18, 0]
    overlay = CrystalEditor::SemanticOverlay.build(data, ["", "  foo"], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    raise "line 1 col 2 should be string" unless overlay.name_at(1, 2) == "string"
    raise "line 0 should be empty" unless overlay.name_at(0, 0).nil?
  end

  it "ignores trailing incomplete quintuples" do
    data = [0, 0, 3, 15, 0, 1, 0]
    overlay = CrystalEditor::SemanticOverlay.build(data, ["def"], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    raise "complete token should still apply" unless overlay.name_at(0, 0) == "keyword"
  end

  it "clamps token length to the line" do
    data = [0, 0, 50, 15, 0]
    overlay = CrystalEditor::SemanticOverlay.build(data, ["ab"], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    raise "col 0 should be keyword" unless overlay.name_at(0, 0) == "keyword"
    raise "col 1 should be keyword" unless overlay.name_at(0, 1) == "keyword"
    raise "past EOL should be nil" unless overlay.name_at(0, 2).nil?
  end

  it "skips out-of-range token types" do
    data = [0, 0, 3, 99, 0]
    overlay = CrystalEditor::SemanticOverlay.build(data, ["foo"], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    raise "unknown type should not color" unless overlay.name_at(0, 0).nil?
  end

  it "reports tokens after decode" do
    overlay = CrystalEditor::SemanticOverlay.build([0, 0, 3, 15, 0], ["def"], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    raise "decoded overlay should report tokens" unless overlay.any_tokens?
  end

  it "fills Crystal hash comments outside strings" do
    data = [0, 0, 5, 18, 0] # "hello" as string
    overlay = CrystalEditor::SemanticOverlay.build(data, [%("hello" # note)], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    overlay.apply_hash_comments([%("hello" # note)])
    raise "string should stay string" unless overlay.name_at(0, 1) == "string"
    raise "comment hash should be comment" unless overlay.name_at(0, 8) == "comment"
    raise "comment text should be comment" unless overlay.name_at(0, 12) == "comment"
  end

  it "does not treat # inside a string token as a comment" do
    overlay = CrystalEditor::SemanticOverlay.build([0, 0, 9, 18, 0], [%("a#b#cde")], CrystalEditor::SemanticOverlay::STANDARD_LEGEND)
    overlay.apply_hash_comments([%("a#b#cde")])
    raise "# inside string should stay string" unless overlay.name_at(0, 2) == "string"
    raise "later # inside string should stay string" unless overlay.name_at(0, 4) == "string"
  end
end

describe CrystalEditor::Lsp::SemanticTokens do
  it "parses data array from a full semantic tokens result" do
    raw = JSON.parse(%({"data":[0,0,3,15,0,0,4,3,8,0],"resultId":"v1"}))
    data = CrystalEditor::Lsp::SemanticTokens.parse_data(raw)
    raise "expected 10 integers" unless data.size == 10
    raise "first deltaLine wrong" unless data[0] == 0
    raise "token type wrong" unless data[3] == 15
  end

  it "returns empty for nil or null result" do
    raise "nil should be empty" unless CrystalEditor::Lsp::SemanticTokens.parse_data(nil).empty?
    raise "null should be empty" unless CrystalEditor::Lsp::SemanticTokens.parse_data(JSON.parse("null")).empty?
  end

  it "returns empty for missing data field" do
    raise "missing data should be empty" unless CrystalEditor::Lsp::SemanticTokens.parse_data(JSON.parse(%({"resultId":"v1"}))).empty?
  end
end

describe CrystalEditor::Theme::Syntax do
  it "uses vscode-dark keyword color after reset" do
    CrystalEditor::Theme.reset
    color = CrystalEditor::Theme::Syntax.color("keyword")
    raise "keyword color should be set" if color.nil?
    raise "keyword should match dark+ blue" unless color == Tui::Color.rgb(86, 156, 214)
  end

  it "applies token color without replacing background" do
    CrystalEditor::Theme.reset
    base = Tui::Style.new(fg: Tui::Color.white, bg: Tui::Color.rgb(30, 30, 30))
    styled = CrystalEditor::Theme::Syntax.apply(base, "string")
    raise "string fg should change" unless styled.fg == Tui::Color.rgb(206, 145, 120)
    raise "background should be preserved" unless styled.bg == base.bg
  end

  it "keeps base style when token type is unknown" do
    CrystalEditor::Theme.reset
    base = Tui::Style.new(fg: Tui::Color.white, bg: Tui::Color.rgb(1, 2, 3))
    styled = CrystalEditor::Theme::Syntax.apply(base, "not-a-token")
    raise "unknown token should keep base fg" unless styled.fg == base.fg
    raise "unknown token should keep base bg" unless styled.bg == base.bg
  end

  it "loads syntax overrides from JSON" do
    tmp = Path.new(Dir.tempdir, "editor-syntax-theme-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(tmp)
    begin
      theme_file = tmp / "theme.json"
      File.write(theme_file.to_s, {
        "syntax" => {
          "keyword" => "#FF00AA",
        },
      }.to_json)

      CrystalEditor::Theme.reset
      raise "load should succeed" unless CrystalEditor::Theme.load(theme_file.to_s)
      raise "keyword override should apply" unless CrystalEditor::Theme::Syntax.color("keyword") == Tui::Color.rgb(255, 0, 170)
      raise "string should keep preset" unless CrystalEditor::Theme::Syntax.color("string") == Tui::Color.rgb(206, 145, 120)
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  it "switches syntax palette with light preset" do
    CrystalEditor::Theme.reset
    CrystalEditor::Theme.load("vscode-light")
    raise "light keyword should be blue" unless CrystalEditor::Theme::Syntax.color("keyword") == Tui::Color.rgb(0, 0, 255)
  end
end
