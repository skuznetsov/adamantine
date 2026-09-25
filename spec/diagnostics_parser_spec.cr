require "spec"
require "json"
require "../src/adamantine/app"

class DiagnosticsParserSpecClient < Adamantine::Lsp::Client
  def initialize
    super("", Path.new(Dir.current), [] of String)
  end

  def handle_diagnostics_public(message : JSON::Any) : Nil
    handle_diagnostics_notification(message)
  end
end

describe "bounded LSP diagnostics publication" do
  it "advertises publishDiagnostics version support" do
    capabilities = Adamantine::Lsp::Client.client_capabilities
    publish = capabilities["textDocument"]["publishDiagnostics"]
    raise "versionSupport must be advertised" unless publish["versionSupport"].as_bool
  end

  it "publishes a version and preserves zero-length ranges" do
    client = DiagnosticsParserSpecClient.new
    seen_uri = nil.as(String?)
    seen_version = nil.as(Int32?)
    seen_diagnostics = [] of Adamantine::Lsp::Diagnostic
    seen_partial = false
    calls = 0
    legacy_calls = 0

    client.on_diagnostics = ->(uri : String, diagnostics : Array(Adamantine::Lsp::Diagnostic)) {
      legacy_calls += 1
    }

    client.on_versioned_diagnostics = ->(uri : String, version : Int32?, diagnostics : Array(Adamantine::Lsp::Diagnostic), partial : Bool) {
      calls += 1
      seen_uri = uri
      seen_version = version
      seen_diagnostics = diagnostics
      seen_partial = partial
    }

    message = JSON.parse({
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri"         => "file:///workspace/main.cr",
        "version"     => 7,
        "diagnostics" => [{
          "range" => {
            "start" => {"line" => 2, "character" => 4},
            "end"   => {"line" => 2, "character" => 4},
          },
          "message" => "zero-width",
        }],
      },
    }.to_json)

    client.handle_diagnostics_public(message)
    raise "expected one publication" unless calls == 1
    raise "wrong URI" unless seen_uri == "file:///workspace/main.cr"
    raise "wrong version" unless seen_version == 7
    raise "unexpected partial publication" if seen_partial
    raise "versioned callback must supersede legacy callback" unless legacy_calls == 0
    raise "expected one diagnostic" unless seen_diagnostics.size == 1
    diagnostic = seen_diagnostics[0]
    raise "zero-length range was changed" unless diagnostic.line == 2 && diagnostic.character == 4 && diagnostic.end_line == 2 && diagnostic.end_character == 4
  end

  it "uses the legacy callback only when the versioned callback is absent" do
    client = DiagnosticsParserSpecClient.new
    legacy_calls = 0
    legacy_count = 0
    client.on_diagnostics = ->(uri : String, diagnostics : Array(Adamantine::Lsp::Diagnostic)) {
      legacy_calls += 1
      legacy_count = diagnostics.size
    }

    message = JSON.parse({
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri"         => "file:///workspace/main.cr",
        "diagnostics" => [] of String,
      },
    }.to_json)
    client.handle_diagnostics_public(message)
    raise "legacy callback should be retained" unless legacy_calls == 1 && legacy_count == 0
  end

  it "maps absent and explicit null versions to nil" do
    client = DiagnosticsParserSpecClient.new
    versions = [] of Int32?
    client.on_versioned_diagnostics = ->(uri : String, version : Int32?, diagnostics : Array(Adamantine::Lsp::Diagnostic), partial : Bool) { versions << version }

    [
      {"uri" => "file:///workspace/main.cr", "diagnostics" => [] of String},
      {"uri" => "file:///workspace/main.cr", "version" => nil, "diagnostics" => [] of String},
    ].each do |params|
      client.handle_diagnostics_public(JSON.parse({
        "method" => "textDocument/publishDiagnostics",
        "params" => params,
      }.to_json))
    end

    raise "unversioned publications must expose nil version" unless versions == [nil, nil]
  end

  it "drops malformed versions and invalid URIs without publication" do
    client = DiagnosticsParserSpecClient.new
    calls = 0
    client.on_versioned_diagnostics = ->(uri : String, version : Int32?, diagnostics : Array(Adamantine::Lsp::Diagnostic), partial : Bool) { calls += 1 }

    [
      {"uri" => "file:///workspace/main.cr", "version" => 1.5, "diagnostics" => [] of String},
      {"uri" => "file:///workspace/main.cr", "version" => 2_147_483_648_i64, "diagnostics" => [] of String},
      {"uri" => "", "diagnostics" => [] of String},
      {"diagnostics" => [] of String},
      {"uri" => ("x" * 8193), "diagnostics" => [] of String},
    ].each do |params|
      client.handle_diagnostics_public(JSON.parse({
        "method" => "textDocument/publishDiagnostics",
        "params" => params,
      }.to_json))
    end

    raise "malformed publication should be dropped" unless calls == 0
  end

  it "skips malformed items, keeps siblings, and marks truncation" do
    client = DiagnosticsParserSpecClient.new
    seen = [] of Adamantine::Lsp::Diagnostic
    partial = false
    client.on_versioned_diagnostics = ->(uri : String, version : Int32?, diagnostics : Array(Adamantine::Lsp::Diagnostic), truncated : Bool) {
      seen = diagnostics
      partial = truncated
    }

    oversized_message = "🙂" * 4097
    oversized_source = "界" * 257
    message = JSON.parse({
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri"         => "file:///workspace/main.cr",
        "diagnostics" => [
          {"range" => {"start" => {"line" => -1, "character" => 0}, "end" => {"line" => 0, "character" => 0}}, "message" => "bad"},
          {"range" => {"start" => {"line" => 1, "character" => 3}, "end" => {"line" => 1, "character" => 3}}, "message" => "zero"},
          {"range" => {"start" => {"line" => 2, "character" => 0}, "end" => {"line" => 2, "character" => 1}}, "message" => oversized_message, "source" => oversized_source},
        ],
      },
    }.to_json)

    client.handle_diagnostics_public(message)
    raise "malformed sibling should be skipped" unless seen.size == 2
    raise "valid zero-width sibling should remain" unless seen[0].end_character == seen[0].character
    raise "message must be capped by codepoint count" unless seen[1].message.size == 4096
    raise "source must be capped by codepoint count" unless seen[1].source.try(&.size) == 256
    raise "skips/truncation must be explicit" unless partial
  end

  it "bounds inspected items rather than only valid output" do
    client = DiagnosticsParserSpecClient.new
    seen_count = -1
    partial = false
    client.on_versioned_diagnostics = ->(uri : String, version : Int32?, diagnostics : Array(Adamantine::Lsp::Diagnostic), truncated : Bool) {
      seen_count = diagnostics.size
      partial = truncated
    }

    malformed_items = Array.new(1000) do
      {"message" => "missing range"}
    end
    items = malformed_items + [{
      "range" => {
        "start" => {"line" => 0, "character" => 0},
        "end"   => {"line" => 0, "character" => 1},
      },
      "message" => "after inspection bound",
    }]
    client.handle_diagnostics_public(JSON.parse({
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri"         => "file:///workspace/main.cr",
        "diagnostics" => items,
      },
    }.to_json))

    raise "items after the inspection bound must not be parsed" unless seen_count == 0
    raise "item cap must be explicit" unless partial
  end
end
