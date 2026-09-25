require "spec"
require "../src/adamantine/snippet_parser"

private def parse_snippet(source : String) : Adamantine::Snippet::ParseResult
  outcome = Adamantine::Snippet::Parser.parse(source)
  raise "expected snippet parse success, got #{outcome.error}" unless result = outcome.result
  result
end

private def expect_snippet_error(source : String, expected : Adamantine::Snippet::ParseError) : Nil
  outcome = Adamantine::Snippet::Parser.parse(source)
  outcome.result.should be_nil
  outcome.error.should eq(expected)
end

describe "bounded completion snippet parser" do
  it "unescapes literal dollar, closing brace, and backslash without creating stops" do
    source = "say \\$1 \\} \\\\"
    parsed = parse_snippet(source)

    parsed.text.should eq("say $1 } \\")
    parsed.tabstops.map(&.index).should eq([0])
    stop = parsed.tabstops.last
    stop.start_offset.should eq(parsed.text.each_char.size)
    stop.end_offset.should eq(parsed.text.each_char.size)
    parsed.explicit_final_stop?.should be_false
  end

  it "parses all supported numbered forms with Unicode codepoint offsets and tab order" do
    parsed = parse_snippet("λ${2:βeta}-$1-$0")

    parsed.text.should eq("λβeta--")
    parsed.tabstops.map(&.index).should eq([1, 2, 0])
    parsed.tabstops[0].start_offset.should eq(6)
    parsed.tabstops[0].end_offset.should eq(6)
    parsed.tabstops[1].start_offset.should eq(1)
    parsed.tabstops[1].end_offset.should eq(5)
    parsed.tabstops[2].start_offset.should eq(7)
    parsed.tabstops[2].end_offset.should eq(7)
    parsed.explicit_final_stop?.should be_true
  end

  it "keeps a zero-width placeholder for both bare and braced empty forms" do
    parsed = parse_snippet("$2/${1}/$0")

    parsed.text.should eq("//")
    parsed.tabstops.map(&.index).should eq([1, 2, 0])
    parsed.tabstops[0].start_offset.should eq(1)
    parsed.tabstops[0].end_offset.should eq(1)
    parsed.tabstops[1].start_offset.should eq(0)
    parsed.tabstops[1].end_offset.should eq(0)
  end

  it "keeps escaped delimiter and dollar characters literal inside a default" do
    parsed = parse_snippet("${1:left\\} price \\$5}")

    parsed.text.should eq("left} price $5")
    parsed.tabstops[0].index.should eq(1)
    parsed.tabstops[0].start_offset.should eq(0)
    parsed.tabstops[0].end_offset.should eq(parsed.text.each_char.size)
  end

  it "visits the explicit final stop last even when it appears earlier in the text" do
    parsed = parse_snippet("finish:$0 middle:$2 last:$1")

    parsed.tabstops.map(&.index).should eq([1, 2, 0])
    parsed.tabstops[2].start_offset.should eq("finish:".each_char.size)
    parsed.tabstops[2].start_offset.should be < parsed.text.each_char.size
  end

  it "rejects repeated indices instead of pretending to support linked mirrors" do
    expect_snippet_error("${1:name}-$1", Adamantine::Snippet::ParseError::RepeatedIndex)
    expect_snippet_error("$0${0}", Adamantine::Snippet::ParseError::RepeatedIndex)
  end

  it "rejects malformed placeholders and unsupported variables, nesting, choices, and transforms" do
    expect_snippet_error("$", Adamantine::Snippet::ParseError::Malformed)
    expect_snippet_error("${1", Adamantine::Snippet::ParseError::Malformed)
    expect_snippet_error("${1:unfinished", Adamantine::Snippet::ParseError::Malformed)
    expect_snippet_error("${}", Adamantine::Snippet::ParseError::Malformed)
    expect_snippet_error("\\q", Adamantine::Snippet::ParseError::InvalidEscape)
    expect_snippet_error("$TM_FILENAME", Adamantine::Snippet::ParseError::UnsupportedSyntax)
    expect_snippet_error("${1:${2}}", Adamantine::Snippet::ParseError::UnsupportedSyntax)
    expect_snippet_error("${1|one,two|}", Adamantine::Snippet::ParseError::UnsupportedSyntax)
    expect_snippet_error("${1/(.*)/$1/}", Adamantine::Snippet::ParseError::UnsupportedSyntax)
  end

  it "rejects oversized source, excessive tabstops, and excessive numeric indices" do
    within_limit = parse_snippet("x" * Adamantine::Snippet::Parser::MAX_SOURCE_BYTES)
    within_limit.text.bytesize.should eq(Adamantine::Snippet::Parser::MAX_SOURCE_BYTES)

    too_large = "x" * (Adamantine::Snippet::Parser::MAX_SOURCE_BYTES + 1)
    expect_snippet_error(too_large, Adamantine::Snippet::ParseError::SourceTooLarge)

    at_limit = String.build do |io|
      (1...Adamantine::Snippet::Parser::MAX_TABSTOPS).each { |index| io << "$" << index }
      io << "$0"
    end
    parse_snippet(at_limit).tabstops.size.should eq(Adamantine::Snippet::Parser::MAX_TABSTOPS)

    too_many = String.build do |io|
      (1..(Adamantine::Snippet::Parser::MAX_TABSTOPS + 1)).each { |index| io << "$" << index }
    end
    expect_snippet_error(too_many, Adamantine::Snippet::ParseError::TooManyTabstops)
    parse_snippet("$999").tabstops[0].index.should eq(999)
    expect_snippet_error("$1000", Adamantine::Snippet::ParseError::IndexTooLarge)
  end
end
