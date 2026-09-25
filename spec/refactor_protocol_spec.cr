require "spec"
require "json"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/lsp_client"

private class RefactorProtocolClient < Adamantine::Lsp::Client
  def initialize
    super("", Path.new(Dir.current), [] of String)
  end

  def advertise(raw : String) : Nil
    self.server_capabilities = JSON.parse(raw)
  end
end

private def with_refactor_lsp(prefix : String = "adamantine-refactor-protocol", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def write_refactor_lsp(path : Path) : Nil
  File.write(path, <<-'RUBY')
#!/usr/bin/env ruby
require "json"

def read_message
  headers = {}
  loop do
    line = STDIN.gets
    return nil unless line
    line = line.sub(/\r?\n$/, "")
    break if line.empty?
    key, value = line.split(":", 2)
    headers[key.downcase] = value.strip if key && value
  end
  length = headers["content-length"].to_i
  return nil if length <= 0
  JSON.parse(STDIN.read(length))
end

def write_message(object)
  payload = JSON.generate(object)
  STDOUT.write("Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
  STDOUT.flush
end

log_path = ARGV.fetch(0)
response_mode = ARGV.fetch(1, "normal")
File.open(log_path, "w") {}
loop do
  message = read_message
  break unless message
  File.open(log_path, "a") { |file| file.puts(JSON.generate(message)) }
  case message["method"]
  when "initialize"
    write_message(
      "jsonrpc" => "2.0",
      "id" => message["id"],
      "result" => {
        "capabilities" => {
          "codeActionProvider" => true,
          "renameProvider" => true,
        },
      },
    )
  when "textDocument/codeAction"
    result = case response_mode
             when "null"
               nil
             when "object"
               {"not" => "an array"}
             else
               [{"title" => "Fix"}]
             end
    write_message(
      "jsonrpc" => "2.0",
      "id" => message["id"],
      "result" => result,
    )
  when "shutdown"
    write_message("jsonrpc" => "2.0", "id" => message["id"], "result" => nil)
  when "exit"
    break
  end
end
RUBY
  File.chmod(path.to_s, 0o755)
end

describe "LSP refactor protocol" do
  it "advertises only the supported code-action and workspace-edit capabilities" do
    capabilities = Adamantine::Lsp::Client.client_capabilities
    code_action = capabilities["textDocument"]["codeAction"]
    kinds = code_action["codeActionLiteralSupport"]["codeActionKind"]["valueSet"].as_a.map(&.as_s)
    kinds.should eq ["quickfix"]
    code_action["resolveSupport"]?.should be_nil
    code_action["commandSupport"]?.should be_nil

    rename = capabilities["textDocument"]["rename"]
    rename["prepareSupport"].as_bool.should be_false

    workspace_edit = capabilities["workspace"]["workspaceEdit"]
    workspace_edit["documentChanges"].as_bool.should be_true
    workspace_edit["resourceOperations"]?.should be_nil
    workspace_edit["changeAnnotationSupport"]?.should be_nil
  end

  it "accepts only strict boolean or object rename and quick-fix capabilities" do
    client = RefactorProtocolClient.new

    [
      %({"renameProvider":true,"codeActionProvider":{}}),
      %({"renameProvider":{},"codeActionProvider":true}),
    ].each do |raw|
      client.advertise(raw)
      client.rename_supported?.should be_true
      client.quick_fix_supported?.should be_true
    end

    [
      %({"renameProvider":false,"codeActionProvider":false}),
      %({"renameProvider":null,"codeActionProvider":null}),
      %({"renameProvider":"true","codeActionProvider":[]}),
      %([]),
      %("not an object"),
    ].each do |raw|
      client.advertise(raw)
      client.rename_supported?.should be_false
      client.quick_fix_supported?.should be_false
    end
  end

  it "sends a zero-width range for generic code actions and quick fixes" do
    with_refactor_lsp do |tmp_dir|
      command = tmp_dir / "fake_lsp"
      log = tmp_dir / "messages.jsonl"
      write_refactor_lsp(command)

      client = Adamantine::Lsp::Client.new(command.to_s, tmp_dir, [log.to_s])
      begin
        client.start.should be_true
        uri = "file:///current.cr"
        client.code_action(uri, 3, 5).size.should eq 1
        client.quick_fix(uri, 3, 5).size.should eq 1
      ensure
        client.stop
      end

      messages = File.read(log.to_s).lines.map { |line| JSON.parse(line) }
      requests = messages.select { |message| message["method"]?.try(&.as_s?) == "textDocument/codeAction" }
      requests.size.should eq 2

      generic = requests[0]["params"]
      generic["position"]?.should be_nil
      generic["range"]["start"]["line"].as_i.should eq 3
      generic["range"]["start"]["character"].as_i.should eq 5
      generic["range"]["end"].to_json.should eq generic["range"]["start"].to_json
      generic["context"]["diagnostics"].as_a.should be_empty
      generic["context"]["only"]?.should be_nil

      quickfix = requests[1]["params"]
      quickfix["range"]["start"].to_json.should eq quickfix["range"]["end"].to_json
      quickfix["context"]["diagnostics"].as_a.should be_empty
      quickfix["context"]["only"].as_a.map(&.as_s).should eq ["quickfix"]
      quickfix["context"]["triggerKind"].as_i.should eq 1
    end
  end

  it "treats a null quick-fix result as no actions and rejects other non-array results" do
    [{"null", true}, {"object", false}].each do |mode, empty|
      with_refactor_lsp do |tmp_dir|
        command = tmp_dir / "fake_lsp"
        log = tmp_dir / "messages.jsonl"
        write_refactor_lsp(command)

        client = Adamantine::Lsp::Client.new(command.to_s, tmp_dir, [log.to_s, mode])
        begin
          client.start.should be_true
          uri = "file:///current.cr"
          if empty
            client.quick_fix(uri, 0, 0).should be_empty
          else
            expect_raises(ArgumentError, /array or null/) { client.quick_fix(uri, 0, 0) }
          end
        ensure
          client.stop
        end
      end
    end
  end
end
