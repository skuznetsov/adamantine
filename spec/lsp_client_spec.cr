require "spec"
require "json"
require "crystal_tui"
require "../src/adamantine/app"

class LspClientParseTest < Adamantine::Lsp::Client
  def initialize
    super("", Path.new(Dir.current), [] of String)
  end

  def parse_diagnostics_public(raw : JSON::Any?) : Array(Adamantine::Lsp::Diagnostic)
    parse_diagnostics(raw)
  end

  def parse_hover_public(raw : JSON::Any?) : Adamantine::Lsp::Hover?
    parse_hover(raw)
  end

  def parse_completion_items_public(raw : JSON::Any?) : Array(Adamantine::Lsp::CompletionItem)
    parse_completion_items(raw)
  end

  def parse_signature_help_public(raw : JSON::Any?) : Adamantine::Lsp::SignatureHelp?
    parse_signature_help(raw)
  end

  def parse_locations_public(raw : JSON::Any?) : Array(Adamantine::Lsp::Location)
    parse_locations(raw)
  end

  def parse_range_public(raw : JSON::Any?) : Adamantine::Lsp::Range?
    parse_range(raw)
  end
end

describe Adamantine::Lsp::Client do
  describe "parse_diagnostics" do
    it "returns empty array for nil input" do
      client = LspClientParseTest.new
      result = client.parse_diagnostics_public(nil)
      raise "expected empty" unless result.empty?
    end

    it "parses valid diagnostic with range and message" do
      client = LspClientParseTest.new
      raw = JSON.parse([{
        "range" => {
          "start" => {"line" => 5, "character" => 10},
          "end"   => {"line" => 5, "character" => 15},
        },
        "message"  => "undefined variable",
        "severity" => 1,
        "source"   => "crystal",
      }].to_json)

      result = client.parse_diagnostics_public(raw)
      raise "expected 1 diagnostic" unless result.size == 1
      diag = result[0]
      raise "wrong line" unless diag.line == 5
      raise "wrong character" unless diag.character == 10
      raise "wrong end_line" unless diag.end_line == 5
      raise "wrong end_character" unless diag.end_character == 15
      raise "wrong message" unless diag.message == "undefined variable"
      raise "wrong severity" unless diag.severity == 1
      raise "wrong source" unless diag.source == "crystal"
    end

    it "skips entries without range" do
      client = LspClientParseTest.new
      raw = JSON.parse([{
        "message" => "no range",
      }].to_json)

      result = client.parse_diagnostics_public(raw)
      raise "should skip entry without range" unless result.empty?
    end

    it "adjusts end_character when end equals start on same line" do
      client = LspClientParseTest.new
      raw = JSON.parse([{
        "range" => {
          "start" => {"line" => 3, "character" => 7},
          "end"   => {"line" => 3, "character" => 7},
        },
        "message" => "zero-width",
      }].to_json)

      result = client.parse_diagnostics_public(raw)
      raise "expected 1 diagnostic" unless result.size == 1
      raise "end_character should be adjusted to character + 1" unless result[0].end_character == 8
    end

    it "parses multiple diagnostics" do
      client = LspClientParseTest.new
      raw = JSON.parse([
        {"range" => {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 5}}, "message" => "first"},
        {"range" => {"start" => {"line" => 1, "character" => 0}, "end" => {"line" => 1, "character" => 3}}, "message" => "second"},
      ].to_json)

      result = client.parse_diagnostics_public(raw)
      raise "expected 2 diagnostics" unless result.size == 2
    end

    it "defaults optional fields when missing" do
      client = LspClientParseTest.new
      raw = JSON.parse([{
        "range" => {
          "start" => {"line" => 0, "character" => 0},
          "end"   => {"line" => 0, "character" => 1},
        },
        "message" => "test",
      }].to_json)

      result = client.parse_diagnostics_public(raw)
      raise "expected 1 diagnostic" unless result.size == 1
      raise "source should be nil" unless result[0].source.nil?
      raise "severity should be nil" unless result[0].severity.nil?
    end
  end

  describe "parse_hover" do
    it "returns nil for nil input" do
      client = LspClientParseTest.new
      raise "expected nil" unless client.parse_hover_public(nil).nil?
    end

    it "parses string contents" do
      client = LspClientParseTest.new
      raw = JSON.parse({"contents" => "hello world"}.to_json)
      hover = client.parse_hover_public(raw)
      raise "expected hover" unless hover
      raise "wrong text" unless hover.text == "hello world"
    end

    it "parses MarkedString array contents" do
      client = LspClientParseTest.new
      raw = JSON.parse({"contents" => [{"value" => "line1"}, {"value" => "line2"}]}.to_json)
      hover = client.parse_hover_public(raw)
      raise "expected hover" unless hover
      raise "should join lines" unless hover.text == "line1\nline2"
    end

    it "parses MarkupContent object" do
      client = LspClientParseTest.new
      raw = JSON.parse({"contents" => {"value" => "markup content"}}.to_json)
      hover = client.parse_hover_public(raw)
      raise "expected hover" unless hover
      raise "wrong text" unless hover.text == "markup content"
    end

    it "returns nil for empty content" do
      client = LspClientParseTest.new
      raw = JSON.parse({"contents" => ""}.to_json)
      hover = client.parse_hover_public(raw)
      raise "expected nil for empty" unless hover.nil?
    end

    it "parses hover with range" do
      client = LspClientParseTest.new
      raw = JSON.parse({
        "contents" => "hover text",
        "range"    => {
          "start" => {"line" => 1, "character" => 0},
          "end"   => {"line" => 1, "character" => 5},
        },
      }.to_json)
      hover = client.parse_hover_public(raw)
      raise "expected hover" unless hover
      raise "expected range" unless hover.range
      range = hover.range.not_nil!
      raise "wrong start_line" unless range.start_line == 1
      raise "wrong end_character" unless range.end_character == 5
    end
  end

  describe "parse_completion_items" do
    it "returns empty array for nil input" do
      client = LspClientParseTest.new
      result = client.parse_completion_items_public(nil)
      raise "expected empty" unless result.empty?
    end

    it "parses CompletionList format with items key" do
      client = LspClientParseTest.new
      raw = JSON.parse({"items" => [{"label" => "puts"}]}.to_json)
      result = client.parse_completion_items_public(raw)
      raise "expected 1 item" unless result.size == 1
      raise "wrong label" unless result[0].label == "puts"
    end

    it "parses multiple completion items" do
      client = LspClientParseTest.new
      raw = JSON.parse({"items" => [{"label" => "foo"}, {"label" => "bar"}]}.to_json)
      result = client.parse_completion_items_public(raw)
      raise "expected 2 items" unless result.size == 2
    end

    it "skips entries without label" do
      client = LspClientParseTest.new
      raw = JSON.parse({"items" => [{"detail" => "no label here"}]}.to_json)
      result = client.parse_completion_items_public(raw)
      raise "should skip without label" unless result.empty?
    end

    it "extracts insertText" do
      client = LspClientParseTest.new
      raw = JSON.parse({"items" => [{"label" => "x", "insertText" => "x()"}]}.to_json)
      result = client.parse_completion_items_public(raw)
      raise "wrong insertText" unless result[0].insert_text == "x()"
    end

    it "uses textEdit.newText as insertText fallback" do
      client = LspClientParseTest.new
      raw = JSON.parse({"items" => [{"label" => "y", "textEdit" => {"newText" => "y()"}}]}.to_json)
      result = client.parse_completion_items_public(raw)
      raise "should use textEdit.newText" unless result[0].insert_text == "y()"
    end

    it "extracts detail and kind" do
      client = LspClientParseTest.new
      raw = JSON.parse({"items" => [{"label" => "z", "detail" => "Method", "kind" => 2}]}.to_json)
      result = client.parse_completion_items_public(raw)
      raise "wrong detail" unless result[0].detail == "Method"
      raise "wrong kind" unless result[0].kind == 2
    end
  end

  describe "parse_signature_help" do
    it "returns nil for nil input" do
      client = LspClientParseTest.new
      raise "expected nil" unless client.parse_signature_help_public(nil).nil?
    end

    it "parses valid signature help" do
      client = LspClientParseTest.new
      raw = JSON.parse({
        "signatures"      => [{"label" => "foo(a : Int32)"}],
        "activeSignature" => 0,
        "activeParameter" => 0,
      }.to_json)
      sig = client.parse_signature_help_public(raw)
      raise "expected signature" unless sig
      raise "wrong signature count" unless sig.signatures.size == 1
      raise "wrong label" unless sig.signatures[0] == "foo(a : Int32)"
    end

    it "returns nil for empty signatures" do
      client = LspClientParseTest.new
      raw = JSON.parse({"signatures" => [] of String}.to_json)
      raise "expected nil" unless client.parse_signature_help_public(raw).nil?
    end
  end

  describe "parse_locations" do
    it "returns empty array for nil input" do
      client = LspClientParseTest.new
      result = client.parse_locations_public(nil)
      raise "expected empty" unless result.empty?
    end

    it "parses single location object" do
      client = LspClientParseTest.new
      raw = JSON.parse({
        "uri"   => "file:///test.cr",
        "range" => {
          "start" => {"line" => 10, "character" => 5},
          "end"   => {"line" => 10, "character" => 15},
        },
      }.to_json)
      result = client.parse_locations_public(raw)
      raise "expected 1 location" unless result.size == 1
      raise "wrong uri" unless result[0].uri == "file:///test.cr"
      raise "wrong line" unless result[0].line == 10
      raise "wrong character" unless result[0].character == 5
    end

    it "parses array of locations" do
      client = LspClientParseTest.new
      raw = JSON.parse([
        {"uri" => "file:///a.cr", "range" => {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 1}}},
        {"uri" => "file:///b.cr", "range" => {"start" => {"line" => 5, "character" => 3}, "end" => {"line" => 5, "character" => 10}}},
      ].to_json)
      result = client.parse_locations_public(raw)
      raise "expected 2 locations" unless result.size == 2
      raise "wrong second uri" unless result[1].uri == "file:///b.cr"
    end

    it "parses LocationLink with targetRange" do
      client = LspClientParseTest.new
      raw = JSON.parse([{
        "uri"         => "file:///linked.cr",
        "targetRange" => {
          "start" => {"line" => 3, "character" => 0},
          "end"   => {"line" => 3, "character" => 10},
        },
      }].to_json)
      result = client.parse_locations_public(raw)
      raise "expected 1 location" unless result.size == 1
      raise "wrong line" unless result[0].line == 3
    end

    it "skips entries with empty URI" do
      client = LspClientParseTest.new
      raw = JSON.parse([{
        "uri"   => "",
        "range" => {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 1}},
      }].to_json)
      result = client.parse_locations_public(raw)
      raise "should skip empty URI" unless result.empty?
    end
  end

  describe "parse_range" do
    it "returns nil for nil input" do
      client = LspClientParseTest.new
      raise "expected nil" unless client.parse_range_public(nil).nil?
    end

    it "parses valid range" do
      client = LspClientParseTest.new
      raw = JSON.parse({
        "start" => {"line" => 1, "character" => 5},
        "end"   => {"line" => 3, "character" => 10},
      }.to_json)
      range = client.parse_range_public(raw)
      raise "expected range" unless range
      raise "wrong start_line" unless range.start_line == 1
      raise "wrong start_character" unless range.start_character == 5
      raise "wrong end_line" unless range.end_line == 3
      raise "wrong end_character" unless range.end_character == 10
    end
  end

  describe "semantic token capabilities" do
    it "advertises semanticTokens client capabilities" do
      parsed = Adamantine::Lsp::Client.client_capabilities
      semantic = parsed["textDocument"]["semanticTokens"]
      raise "should request full tokens" unless semantic["requests"]["full"]["delta"].as_bool == false
      types = semantic["tokenTypes"].as_a.map(&.as_s)
      raise "should include keyword" unless types.includes?("keyword")
      raise "should include string" unless types.includes?("string")
      raise "should advertise refreshSupport" unless parsed["workspace"]["semanticTokens"]["refreshSupport"].as_bool
    end

    it "detects semanticTokensProvider capability" do
      caps = JSON.parse(%({"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","string"]},"full":true}}))
      raise "provider should be supported" unless Adamantine::Lsp::SemanticTokens.supported?(caps)
      legend = Adamantine::Lsp::SemanticTokens.parse_legend(caps)
      raise "legend should come from server" unless legend == ["keyword", "string"]
    end

    it "treats missing provider as unsupported" do
      caps = JSON.parse(%({"hoverProvider":true}))
      raise "missing provider should be unsupported" if Adamantine::Lsp::SemanticTokens.supported?(caps)
    end
  end

  describe "Diagnostic struct" do
    it "defaults end_line to line when negative" do
      diag = Adamantine::Lsp::Diagnostic.new(5, 3, "test", end_line: -1, end_character: 10)
      raise "end_line should default to line" unless diag.end_line == 5
    end

    it "defaults end_character to character when negative" do
      diag = Adamantine::Lsp::Diagnostic.new(5, 3, "test", end_line: 5, end_character: -1)
      raise "end_character should default to character" unless diag.end_character == 3
    end
  end
end
