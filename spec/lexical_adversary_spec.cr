require "spec"
require "../src/adamantine/lexical_highlighter"

private def adversary_lexical_source(text : String) : Adamantine::BufferSearch::Source
  Adamantine::BufferSearch::Source.new(Tui::PieceTreeBuffer.new(text))
end

private def finish_requested_lexical(lexer : Adamantine::LexicalHighlighter, limit : Int32 = 1000) : Nil
  limit.times do
    return unless lexer.advance(64)
  end
  raise "lexical scan failed to settle within bounded fixture work"
end

describe "Lexical cache adversary" do
  it "does not color arithmetic signs as part of decimal operands" do
    lexer = Adamantine::LexicalHighlighter.new(adversary_lexical_source("1+2 - 3e-4"))
    lexer.request(0)
    finish_requested_lexical(lexer)
    lexer.name_at(0, 0).should eq("number")
    lexer.name_at(0, 1).should be_nil
    lexer.name_at(0, 2).should eq("number")
    lexer.name_at(0, 8).should eq("number")
  end

  it "retains correct restart offsets on LF, CRLF and lone CR" do
    ["\n", "\r\n", "\r"].each do |eol|
      original = "def alpha#{eol}value = 42#{eol}end"
      lexer = Adamantine::LexicalHighlighter.new(adversary_lexical_source(original))
      lexer.request(2)
      finish_requested_lexical(lexer)
      lexer.invalidate(adversary_lexical_source("def alpha#{eol}# changed#{eol}end"), 1)
      lexer.request(2)
      finish_requested_lexical(lexer)
      lexer.name_at(0, 0).should eq("keyword")
      lexer.name_at(1, 2).should eq("comment")
      lexer.name_at(2, 0).should eq("keyword")
    end
  end

  it "stops at the requested row even with a tiny cache and thousands of short lines" do
    lexer = Adamantine::LexicalHighlighter.new(
      adversary_lexical_source("end\n" * 1000), max_cached_lines: 2
    )
    lexer.request(0).should be_true
    lexer.advance(4096).should be_false
    lexer.name_at(0, 0).should eq("keyword")
    lexer.request(0).should be_false
  end

  it "never exceeds the global span cap even on a single busy line" do
    lexer = Adamantine::LexicalHighlighter.new(
      adversary_lexical_source("a 1 " * 100 + "\nend"), max_cached_spans: 8
    )
    lexer.request(0)
    finish_requested_lexical(lexer)
    lexer.cached_span_count.should be <= 8
    lexer.request(0).should be_false
  end

  it "does not continuously request intentionally plain oversized rows" do
    lexer = Adamantine::LexicalHighlighter.new(
      adversary_lexical_source("x" * 200 + "\nend"), max_line_codepoints: 32
    )
    lexer.request(0)
    finish_requested_lexical(lexer)
    lexer.name_at(0, 0).should be_nil
    lexer.request(0).should be_false
    lexer.request(1)
    finish_requested_lexical(lexer)
    lexer.name_at(1, 0).should eq("keyword")
  end

  it "does not rescan forever when callers request a line beyond EOF" do
    lexer = Adamantine::LexicalHighlighter.new(adversary_lexical_source("end"))
    lexer.request(999)
    finish_requested_lexical(lexer)
    lexer.request(999).should be_false
  end
end
