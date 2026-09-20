require "spec"
require "json"
require "file_utils"

require "../src/adamantine/lsp_client"

private class WorkspaceDiagnosticsParserClient < Adamantine::Lsp::Client
  def initialize
    super("", Path.new(Dir.current))
  end

  def parse_workspace_public(value : JSON::Any) : Adamantine::Lsp::WorkspaceDiagnosticResult
    parse_workspace_diagnostics_result(value)
  end
end

private def workspace_wire_diagnostic(message : String, line : Int32 = 0, character : Int32 = 0)
  {
    "range" => {
      "start" => {"line" => line, "character" => character},
      "end"   => {"line" => line, "character" => character},
    },
    "message" => message,
  }
end

private def write_workspace_diagnostics_server(path : Path, request_path : Path) : Nil
  File.write(path, <<-RUBY)
#!/usr/bin/env ruby
require "json"

def read_message
  headers = {}
  while (line = STDIN.gets)
    line = line.sub(/\r?\n$/, "")
    break if line.empty?
    key, value = line.split(":", 2)
    headers[key.downcase] = value.strip if key && value
  end
  return nil unless line
  length = headers["content-length"].to_i
  return nil if length <= 0
  JSON.parse(STDIN.read(length))
end

def write_message(message)
  payload = JSON.generate(message)
  STDOUT.write("Content-Length: " + payload.bytesize.to_s + "\r\n\r\n" + payload)
  STDOUT.flush
end

loop do
  message = read_message
  break unless message
  case message["method"]
  when "initialize"
    write_message({"jsonrpc" => "2.0", "id" => message["id"], "result" => {
      "capabilities" => {"diagnosticProvider" => {
        "identifier" => "compiler", "interFileDependencies" => true, "workspaceDiagnostics" => true
      }}
    }})
  when "workspace/diagnostic"
    File.write(#{request_path.to_s.to_json}, JSON.generate(message))
    write_message({"jsonrpc" => "2.0", "id" => message["id"], "result" => {"items" => [{
      "uri" => "file:///workspace/main.cr", "version" => nil, "kind" => "full", "resultId" => "r1",
      "items" => [{"range" => {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 0}}, "message" => "wire"}]
    }]}})
  when "shutdown"
    write_message({"jsonrpc" => "2.0", "id" => message["id"], "result" => nil})
  when "exit"
    break
  end
end
RUBY
  File.chmod(path, 0o755)
end

describe "LSP workspace diagnostics" do
  it "admits only the exact static workspace diagnostic capability" do
    client = WorkspaceDiagnosticsParserClient.new

    [
      nil,
      JSON.parse(%({"diagnosticProvider":false})),
      JSON.parse(%({"diagnosticProvider":true})),
      JSON.parse(%({"diagnosticProvider":{}})),
      JSON.parse(%({"diagnosticProvider":{"workspaceDiagnostics":false}})),
      JSON.parse(%({"diagnosticProvider":{"workspaceDiagnostics":"true"}})),
      JSON.parse(%({"diagnosticProvider":{"workspaceDiagnostics":true}})),
      JSON.parse(%({"diagnosticProvider":{"interFileDependencies":"false","workspaceDiagnostics":true}})),
    ].each do |capabilities|
      client.server_capabilities = capabilities
      client.workspace_diagnostics_supported?.should be_false
    end

    client.server_capabilities = JSON.parse(%({"diagnosticProvider":{"identifier":"compiler","interFileDependencies":false,"workspaceDiagnostics":true}}))
    client.workspace_diagnostics_supported?.should be_true
    client.workspace_diagnostic_identifier.should eq("compiler")
  end

  it "advertises bounded diagnostic-pull support without refresh or progress claims" do
    capabilities = Adamantine::Lsp::Client.client_capabilities
    diagnostic = capabilities["textDocument"]["diagnostic"]
    diagnostic["dynamicRegistration"].as_bool.should be_false
    diagnostic["relatedDocumentSupport"].as_bool.should be_false
    capabilities["workspace"]["diagnostics"]?.should be_nil
    capabilities["window"]?.should be_nil
  end

  it "parses full reports, keeps nullable versions, and applies repeated URI last-wins" do
    client = WorkspaceDiagnosticsParserClient.new
    result = client.parse_workspace_public(JSON.parse({
      "items" => [
        {
          "uri"      => "file:///workspace/one.cr",
          "version"  => nil,
          "kind"     => "full",
          "resultId" => "old",
          "items"    => [workspace_wire_diagnostic("old")],
        },
        {
          "uri"      => "file:///workspace/two.cr",
          "version"  => 17,
          "kind"     => "full",
          "resultId" => "two",
          "items"    => [workspace_wire_diagnostic("two")],
        },
        {
          "uri"      => "file:///workspace/one.cr",
          "version"  => nil,
          "kind"     => "full",
          "resultId" => "new",
          "items"    => [workspace_wire_diagnostic("new")],
        },
      ],
    }.to_json))

    result.partial.should be_false
    result.documents.map(&.uri).should eq([
      "file:///workspace/two.cr",
      "file:///workspace/one.cr",
    ])
    result.documents[0].version.should eq(17)
    result.documents[1].version.should be_nil
    result.documents[1].result_id.should eq("new")
    result.documents[1].diagnostics.map(&.message).should eq(["new"])
  end

  it "skips unknown unchanged and malformed siblings while making coverage partial" do
    client = WorkspaceDiagnosticsParserClient.new
    result = client.parse_workspace_public(JSON.parse({
      "items" => [
        {
          "uri"      => "file:///workspace/unchanged.cr",
          "version"  => nil,
          "kind"     => "unchanged",
          "resultId" => "opaque",
        },
        {
          "uri"     => "file:///workspace/malformed.cr",
          "version" => nil,
          "kind"    => "full",
          "items"   => "not-an-array",
        },
        {
          "uri"     => "file:///workspace/valid.cr",
          "version" => nil,
          "kind"    => "full",
          "items"   => [workspace_wire_diagnostic("valid")],
        },
      ],
    }.to_json))

    result.partial.should be_true
    result.documents.map(&.uri).should eq(["file:///workspace/valid.cr"])
  end

  it "bounds inspected document reports rather than only retained output" do
    client = WorkspaceDiagnosticsParserClient.new
    malformed = Array.new(Adamantine::Lsp::Client::MAX_WORKSPACE_DIAGNOSTIC_DOCUMENTS) do
      {"kind" => "full", "items" => [] of String}
    end
    items = malformed + [{
      "uri"     => "file:///workspace/after-bound.cr",
      "version" => nil,
      "kind"    => "full",
      "items"   => [workspace_wire_diagnostic("after bound")],
    }]

    result = client.parse_workspace_public(JSON.parse({"items" => items}.to_json))
    result.documents.should be_empty
    result.partial.should be_true
  end

  it "bounds diagnostics across all workspace reports" do
    client = WorkspaceDiagnosticsParserClient.new
    items = Array.new(5) do |document_index|
      {
        "uri"     => "file:///workspace/#{document_index}.cr",
        "version" => nil,
        "kind"    => "full",
        "items"   => Array.new(820) { |index| workspace_wire_diagnostic("#{document_index}-#{index}") },
      }
    end

    result = client.parse_workspace_public(JSON.parse({"items" => items}.to_json))

    result.documents.sum(&.diagnostics.size).should eq(Adamantine::Lsp::Client::MAX_WORKSPACE_DIAGNOSTIC_ITEMS)
    result.partial.should be_true
  end

  it "sends a cache-free final-report request without progress claims" do
    root = Path.new(Dir.tempdir, "adamantine-workspace-wire-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    server = root / "server.rb"
    request_path = root / "request.json"
    write_workspace_diagnostics_server(server, request_path)
    client = Adamantine::Lsp::Client.new(server.to_s, root)

    client.start.should be_true
    client.workspace_diagnostics_supported?.should be_true
    result = client.workspace_diagnostics
    result.documents.map(&.diagnostics.first.message).should eq(["wire"])

    request = JSON.parse(File.read(request_path))
    request["method"].as_s.should eq("workspace/diagnostic")
    params = request["params"]
    params["previousResultIds"].as_a.should be_empty
    params["identifier"].as_s.should eq("compiler")
    params["partialResultToken"]?.should be_nil
    params["workDoneToken"]?.should be_nil
  ensure
    client.try &.stop
    FileUtils.rm_rf(root) if root
  end
end
