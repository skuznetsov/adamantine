require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/lsp_client"

def with_temp_workspace(prefix : String = "editor-lsp-start-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::Lsp::Client do
  describe "#start" do
    it "completes initialize when the reader is started before handshake" do
      with_temp_workspace do |tmp|
        fake_lsp = tmp / "fake_lsp"
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
  method = msg["method"]
  id = msg["id"]
  if method == "initialize"
    write_msg({
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => {
        "capabilities" => {
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
  elsif method == "shutdown"
    write_msg({"jsonrpc" => "2.0", "id" => id, "result" => nil})
  elsif method == "exit"
    break
  end
end
RUBY
        File.chmod(fake_lsp.to_s, 0o755)

        client = CrystalEditor::Lsp::Client.new(fake_lsp.to_s, tmp)
        started = false
        begin
          started = client.start
          raise "start should succeed" unless started
          raise "initialize should record capabilities" if client.server_capabilities.nil?
          raise "semantic tokens should be supported" unless client.semantic_tokens_supported?
          raise "legend should come from server" unless client.semantic_token_legend.includes?("keyword")
        ensure
          client.stop
        end
      end
    end
  end
end
