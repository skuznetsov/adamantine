require "spec"
require "../src/adamantine/debug_value_detail"

describe Adamantine::Debugging::DebugValueDetail do
  it "keeps opaque adapter summary as the default and clips valid UTF-8 without scanning beyond its bound" do
    detail = Adamantine::Debugging::DebugValueDetail.new("é🙂tail\u001b[31m")
    summary = detail.render
    raise "summary is the default detail mode" unless summary.format == Adamantine::Debugging::DebugValueFormat::Summary
    raise "opaque adapter text should be preserved aside from terminal-control sanitization" unless summary.text == "é🙂tail␛[31m"
    raise "the result must not claim native interpretation" if summary.label.downcase.includes?("native")

    clipped = Adamantine::Debugging::DebugValueDetail.new("é🙂tail", max_bytes: 5).render
    raise "display bound must hold in bytes" if clipped.text.bytesize > 5
    raise "UTF-8 must remain valid after clipping" unless clipped.text.valid_encoding?
    raise "clipping must be explicit" unless clipped.truncated?
  end

  it "offers Hex only from an adapter-supported result and Raw only when supplied explicitly" do
    unsupported = Adamantine::Debugging::DebugValueDetail.new("271828")
    hex_unavailable = unsupported.render(Adamantine::Debugging::DebugValueFormat::Hex)
    raw_unavailable = unsupported.render(Adamantine::Debugging::DebugValueFormat::Raw)
    raise "Hex must not be guessed from a summary" unless hex_unavailable.availability == Adamantine::Debugging::DebugValueAvailability::Unavailable
    raise "Raw must not be synthesized from a summary" unless raw_unavailable.availability == Adamantine::Debugging::DebugValueAvailability::Unavailable

    adapter_hex = Adamantine::Debugging::DebugValueDetail.new("42", supports_hex: true, hex_value: "0x2a")
    raise "Hex requires an adapter-provided Hex representation" unless adapter_hex.render(Adamantine::Debugging::DebugValueFormat::Hex).text == "0x2a"
    adapter_raw = Adamantine::Debugging::DebugValueDetail.new("summary", raw_value: "raw-bytes-from-adapter")
    raise "Raw mode may display only a separately supplied adapter field" unless adapter_raw.render(Adamantine::Debugging::DebugValueFormat::Raw).text == "raw-bytes-from-adapter"
  end

  it "labels JSON parsing as local display interpretation and refuses over-budget or malformed JSON" do
    source = "{\"name\":\"Ada\",\"value\":[1,2]}"
    parsed = Adamantine::Debugging::DebugValueDetail.new(source).render(Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "local parse should be available for bounded valid JSON" unless parsed.availability == Adamantine::Debugging::DebugValueAvailability::Available
    raise "JSON rendering must disclose display interpretation" unless parsed.label.downcase.includes?("interpretation")
    raise "JSON detail must not evaluate against the target" if parsed.label.downcase.includes?("evaluate")

    malformed = Adamantine::Debugging::DebugValueDetail.new("{not json}").render(Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "malformed JSON remains unavailable" unless malformed.availability == Adamantine::Debugging::DebugValueAvailability::Unavailable
    overdeep = "[" * 100 + "0" + "]" * 100
    bounded = Adamantine::Debugging::DebugValueDetail.new(overdeep, max_bytes: 4096, max_json_depth: 16)
      .render(Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "deep JSON is rejected before recursive parsing" unless bounded.availability == Adamantine::Debugging::DebugValueAvailability::Unavailable
  end

  it "marks selected-detail truncation and never retains more than its configured display budget" do
    detail = Adamantine::Debugging::DebugValueDetail.new("x" * 1024 * 1024, max_bytes: 64 * 1024)
    view = detail.render
    raise "detail must be visibly truncated" unless view.truncated?
    raise "detail must remain within the selected-detail byte cap" if view.text.bytesize > 64 * 1024
    raise "truncation reason must be available" unless view.reason
  end

  it "keeps parsed JSON and invalid-UTF8 fallbacks within the caller's byte cap" do
    parsed = Adamantine::Debugging::DebugValueDetail.new("[1,2,3]", max_bytes: 7)
      .render(Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "JSON interpretation exceeded the selected detail cap" if parsed.text.bytesize > 7

    invalid = String.new(Bytes[0xff])
    clipped = Adamantine::Debugging::DebugValueDetail.new(invalid, max_bytes: 1).render
    raise "invalid UTF-8 fallback exceeded the selected detail cap" if clipped.text.bytesize > 1
    raise "invalid adapter bytes must be marked truncated" unless clipped.truncated?
  end

  it "makes C1 terminal controls visible instead of retaining executable control bytes" do
    detail = Adamantine::Debugging::DebugValueDetail.new("before\u0085after")
    rendered = detail.render
    raise "C1 control bytes must not survive display sanitization" if rendered.text.includes?("\u0085")
    raise "sanitized text should remain valid UTF-8" unless rendered.text.valid_encoding?
  end

  it "parses original bounded JSON before terminal-safe display escaping" do
    source = "{\n \"x\":1\n}"
    rendered = Adamantine::Debugging::DebugValueDetail.new(source)
      .render(Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "valid multiline bounded JSON should be interpretable" unless rendered.availability == Adamantine::Debugging::DebugValueAvailability::Available
    raise "local JSON output should be valid serialized JSON" unless JSON.parse(rendered.text)
  end

  it "requires complete original JSON provenance instead of parsing a sanitized prefix" do
    prefix = Adamantine::Debugging::DebugValueDetail.new("[0]          ", json_source_complete: false)
      .render(Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "a clipped but syntactically valid prefix is not complete source evidence" if prefix.available?

    original = "{\"x\":\"a\0b\"}"
    sanitized = "{\"x\":\"a b\"}"
    mutated = Adamantine::Debugging::DebugValueDetail.new(sanitized,
      json_source: original, json_source_complete: true)
      .render(Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "terminal-safe display replacement must not become JSON source" if mutated.available?
  end
end
