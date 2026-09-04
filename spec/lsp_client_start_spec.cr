require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/lsp_client"
require "../src/adamantine/uri_codec"

def with_temp_workspace(prefix : String = "editor-lsp-start-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::Lsp::Client do
  describe "#start" do
    it "completes initialize when the reader is started before handshake" do
      with_temp_workspace do |tmp|
        fake_lsp = tmp / "fake_lsp"
        events = tmp / "events.log"
        changes = tmp / "changes.log"
        root = tmp / "root with spaces"
        root_uri = tmp / "root-uri.txt"
        Dir.mkdir_p(root)
        File.write(fake_lsp.to_s, <<-RUBY)
#!/usr/bin/env ruby
require "json"

def read_msg
  headers = {}
  loop do
    line = STDIN.gets
    return nil unless line
    line = line.sub(/\\r?\\n$/, "")
    break if line.empty?
    key, value = line.split(":", 2)
    headers[key.downcase] = value.strip if key && value
  end
  length = headers["content-length"].to_i
  return nil if length <= 0
  JSON.parse(STDIN.read(length))
end

def write_msg(obj)
  payload = JSON.generate(obj)
  STDOUT.write("Content-Length: \#{payload.bytesize}\\r\\n\\r\\n\#{payload}")
  STDOUT.flush
end

loop do
  msg = read_msg
  break unless msg
  File.open(ARGV[0], "a") { |file| file.puts(msg["method"] || "<response>") }
  method = msg["method"]
  id = msg["id"]
  if method == "initialize"
    File.write(ARGV[1], msg.dig("params", "rootUri").to_s)
    write_msg({
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => {
        "capabilities" => {
          "textDocumentSync" => 2,
          "semanticTokensProvider" => {
            "legend" => {
              "tokenTypes" => ["keyword", "string", "comment"],
              "tokenModifiers" => []
            },
            "full" => true
          }
        }
      }
    })
  elsif method == "textDocument/didChange"
    File.open(ARGV[2], "a") { |file| file.puts(JSON.generate(msg["params"])) }
  elsif method == "shutdown"
    write_msg({"jsonrpc" => "2.0", "id" => id, "result" => nil})
  elsif method == "exit"
    break
  end
end
RUBY
        File.chmod(fake_lsp.to_s, 0o755)

        client = Adamantine::Lsp::Client.new(fake_lsp.to_s, root, [events.to_s, root_uri.to_s, changes.to_s])
        started = false
        begin
          started = client.start
          raise "start should succeed" unless started
          raise "initialize should record capabilities" if client.server_capabilities.nil?
          raise "semantic tokens should be supported" unless client.semantic_tokens_supported?
          raise "legend should come from server" unless client.semantic_token_legend.includes?("keyword")
          raise "incremental synchronization should be detected" unless client.incremental_text_sync?
          client.text_change(
            "file:///tmp/example.cr",
            2,
            Adamantine::Lsp::Range.new(3, 4, 3, 6),
            "🚀"
          )
        ensure
          client.stop
        end

        raise "rootUri must use UriCodec" unless File.read(root_uri.to_s) == Adamantine::UriCodec.path_to_uri(root)
        methods = File.read(events.to_s).lines.map(&.strip)
        raise "stop must perform LSP shutdown before exit" unless methods == ["initialize", "initialized", "textDocument/didChange", "shutdown", "exit"]
        change = JSON.parse(File.read(changes.to_s).strip)
        raise "wrong didChange version" unless change["textDocument"]["version"].as_i == 2
        content = change["contentChanges"].as_a.first
        raise "wrong replacement text" unless content["text"].as_s == "🚀"
        range = content["range"]
        raise "wrong start range" unless range["start"]["line"].as_i == 3 && range["start"]["character"].as_i == 4
        raise "wrong end range" unless range["end"]["line"].as_i == 3 && range["end"]["character"].as_i == 6
      end
    end
  end
end
