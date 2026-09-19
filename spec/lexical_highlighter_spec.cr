require "spec"
require "../src/adamantine/lexical_highlighter"

private def lexical_source(text : String) : Adamantine::BufferSearch::Source
  Adamantine::BufferSearch::Source.new(Tui::PieceTreeBuffer.new(text))
end

private def scan_lexical(text : String, *, max_codepoints : Int32 = 4096, max_line_codepoints : Int32 = 2048) : Adamantine::LexicalHighlighter
  highlighter = Adamantine::LexicalHighlighter.new(
    lexical_source(text),
    max_cached_lines: 32,
    max_cached_spans: 256,
    max_line_codepoints: max_line_codepoints
  )
  highlighter.advance(max_codepoints)
  highlighter
end

describe Adamantine::LexicalHighlighter do
  it "highlights Crystal keywords, names, numbers, comments, and quoted strings" do
    highlighter = scan_lexical("class Demo\n  value = 42\n  # note\n  \"text\"\nend\n")

    highlighter.name_at(0, 0).should eq("keyword")
    highlighter.name_at(0, 6).should eq("type")
    highlighter.name_at(1, 2).should eq("variable")
    highlighter.name_at(1, 10).should eq("number")
    highlighter.name_at(2, 2).should eq("comment")
    highlighter.name_at(3, 2).should eq("string")
  end

  it "carries ordinary quoted string state across lines and invalidates from the edit line" do
    highlighter = scan_lexical("x = \"open\ncontinued\"\nvalue = 1\n")
    highlighter.name_at(0, 4).should eq("string")
    highlighter.name_at(1, 0).should eq("string")
    highlighter.name_at(1, 9).should eq("string")
    highlighter.name_at(2, 8).should eq("number")

    changed = lexical_source("x = \"closed\"\ncontinued = 2\n")
    highlighter.invalidate(changed, 0)
    highlighter.request(1)
    highlighter.advance
    highlighter.name_at(1, 0).should eq("variable")
    highlighter.name_at(1, 12).should eq("number")
  end

  it "keeps CRLF line boundaries and reports codepoint columns for Unicode" do
    highlighter = scan_lexical("é = \"界\"\r\n# коммент\r\nvalue = 7\r\n")

    highlighter.name_at(0, 0).should eq("variable")
    highlighter.name_at(0, 4).should eq("string")
    highlighter.name_at(1, 0).should eq("comment")
    highlighter.name_at(2, 8).should eq("number")
  end

  it "keeps giant lines bounded and fails closed instead of retaining a line overlay" do
    huge = "x" * 100_000
    highlighter = scan_lexical("#{huge}\nvalue = 3\n", max_codepoints: 512, max_line_codepoints: 128)

    highlighter.last_progress.codepoints_scanned.should be <= 512
    highlighter.cached_span_count.should be <= 256
    highlighter.name_at(0, 10).should be_nil
    highlighter.request(1)
    while highlighter.advance(512)
    end
    highlighter.name_at(1, 8).should eq("number")
  end

  it "bounds retained lines and spans while advancing in bounded chunks" do
    source = (0...100).map { |index| "value#{index} = #{index}\n" }.join
    highlighter = Adamantine::LexicalHighlighter.new(
      lexical_source(source),
      max_cached_lines: 4,
      max_cached_spans: 8,
      max_line_codepoints: 128
    )

    while highlighter.advance(32)
    end

    highlighter.cached_line_count.should be <= 4
    highlighter.cached_span_count.should be <= 8
    highlighter.complete?.should be_true
  end

  it "rejects stale work and leaves unsupported constructs plain" do
    highlighter = scan_lexical("value = %q(unsupported)\nnext = 9\n")
    highlighter.name_at(0, 0).should be_nil
    highlighter.name_at(1, 0).should be_nil

    old_version = highlighter.version
    highlighter.invalidate(lexical_source("value = 1\n"), 0)
    highlighter.advance(1024, expected_version: old_version).should be_false
    highlighter.request(0)
    highlighter.advance(1024)
    highlighter.name_at(0, 8).should eq("number")
  end
end
