require "spec"

require "../src/adamantine/uri_codec"

describe Adamantine::UriCodec do
  it "encodes and decodes spaces" do
    path = Path.new("/tmp/a path with spaces.rb")
    uri = Adamantine::UriCodec.path_to_uri(path)
    recovered = Adamantine::UriCodec.uri_to_path(uri)
    raise "round trip failed" unless recovered == path.expand
  end

  it "encodes and decodes fragment-like symbols" do
    path = Path.new("/tmp/file #1?.cr")
    uri = Adamantine::UriCodec.path_to_uri(path)
    recovered = Adamantine::UriCodec.uri_to_path(uri)
    raise "round trip failed" unless recovered == path.expand
  end

  it "encodes unicode path safely" do
    path = Path.new("/tmp/dir с пробелами/файл.md")
    uri = Adamantine::UriCodec.path_to_uri(path)
    raise "expected percent-encoded file uri" unless uri.includes?("file://")
    recovered = Adamantine::UriCodec.uri_to_path(uri)
    raise "unicode round trip failed" unless recovered == path.expand
  end

  it "returns nil for non-file uri" do
    raise "expected nil" unless Adamantine::UriCodec.uri_to_path("http://example.com").nil?
  end

  it "returns non-empty path for encoded percent segments" do
    malformed = "file://%"
    path = Adamantine::UriCodec.uri_to_path(malformed)
    raise "expected path for permissive percent input" unless path == Path.new("%")
  end

  it "keeps query symbols when encoding path" do
    path = Path.new("/tmp/a?b#c[d]")
    uri = Adamantine::UriCodec.path_to_uri(path)
    raise "query-like data must be encoded" unless uri.includes?("%3F") || uri.includes?("%23") || uri.includes?("%5B")
  end
end
