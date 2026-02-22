require "spec"

require "../src/editor/uri_codec"

describe CrystalEditor::UriCodec do
  it "encodes and decodes spaces" do
    path = Path.new("/tmp/a path with spaces.rb")
    uri = CrystalEditor::UriCodec.path_to_uri(path)
    recovered = CrystalEditor::UriCodec.uri_to_path(uri)
    raise "round trip failed" unless recovered == path.expand
  end

  it "encodes and decodes fragment-like symbols" do
    path = Path.new("/tmp/file #1?.cr")
    uri = CrystalEditor::UriCodec.path_to_uri(path)
    recovered = CrystalEditor::UriCodec.uri_to_path(uri)
    raise "round trip failed" unless recovered == path.expand
  end

  it "encodes unicode path safely" do
    path = Path.new("/tmp/dir с пробелами/файл.md")
    uri = CrystalEditor::UriCodec.path_to_uri(path)
    raise "expected percent-encoded file uri" unless uri.includes?("file://")
    recovered = CrystalEditor::UriCodec.uri_to_path(uri)
    raise "unicode round trip failed" unless recovered == path.expand
  end

  it "returns nil for non-file uri" do
    raise "expected nil" unless CrystalEditor::UriCodec.uri_to_path("http://example.com").nil?
  end

  it "returns non-empty path for encoded percent segments" do
    malformed = "file://%"
    path = CrystalEditor::UriCodec.uri_to_path(malformed)
    raise "expected path for permissive percent input" unless path == Path.new("%")
  end

  it "keeps query symbols when encoding path" do
    path = Path.new("/tmp/a?b#c[d]")
    uri = CrystalEditor::UriCodec.path_to_uri(path)
    raise "query-like data must be encoded" unless uri.includes?("%3F") || uri.includes?("%23") || uri.includes?("%5B")
  end
end
