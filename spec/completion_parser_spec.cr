require "spec"
require "json"
require "crystal_tui"
require "../src/adamantine/lsp_client"

private class CompletionParserTestClient < Adamantine::Lsp::Client
  def initialize
    super("", Path.new(Dir.current), [] of String)
  end

  def parse_public(raw : JSON::Any?) : Array(Adamantine::Lsp::CompletionItem)
    parse_completion_items(raw)
  end
end

private def parse_completion(json : Hash(String, JSON::Any)) : Adamantine::Lsp::CompletionItem
  item = CompletionParserTestClient.new.parse_public(JSON::Any.new(json)).first?
  raise "expected one completion item" unless item
  item
end

describe "bounded LSP completion parsing" do
  it "keeps a standard textEdit and gives it precedence over insertText" do
    item = parse_completion({
      "items" => JSON::Any.new([JSON::Any.new({
        "label"            => JSON::Any.new("call"),
        "insertText"       => JSON::Any.new("fallback"),
        "insertTextFormat" => JSON::Any.new(1),
        "textEdit"         => JSON::Any.new({
          "range" => JSON::Any.new({
            "start" => JSON::Any.new({"line" => JSON::Any.new(2), "character" => JSON::Any.new(3)}),
            "end"   => JSON::Any.new({"line" => JSON::Any.new(2), "character" => JSON::Any.new(8)}),
          }),
          "newText" => JSON::Any.new("replacement"),
        }),
      })]),
    })

    edit = item.text_edit
    raise "standard textEdit should be exposed" unless edit
    raise "wrong textEdit replacement" unless edit.not_nil!.new_text == "replacement"
    raise "wrong textEdit start" unless edit.not_nil!.range == Adamantine::Lsp::Range.new(2, 3, 2, 8)
    raise "wrong insertTextFormat" unless item.insert_text_format == 1
    raise "valid textEdit should not be rejected" unless item.rejection_reason.nil?
  end

  it "retains plain insertText and falls back to the label" do
    plain = parse_completion({"items" => JSON::Any.new([JSON::Any.new({
      "label"      => JSON::Any.new("plain"),
      "insertText" => JSON::Any.new("plain()"),
    })])})
    raise "wrong plain insertion" unless plain.insert_text == "plain()"
    raise "plain text must default to format 1" unless plain.insert_text_format == 1

    label = parse_completion({"items" => JSON::Any.new([JSON::Any.new({
      "label" => JSON::Any.new("label-fallback"),
    })])})
    raise "label fallback missing" unless label.insert_text == "label-fallback"
  end

  {
    "snippet"           => {"insertTextFormat" => JSON::Any.new(2), "reason" => "snippet_completion_unsupported"},
    "InsertReplaceEdit" => {"textEdit" => JSON::Any.new({
      "insert" => JSON::Any.new({
        "line"      => JSON::Any.new(0),
        "character" => JSON::Any.new(0),
      }),
      "replace" => JSON::Any.new({
        "line"      => JSON::Any.new(0),
        "character" => JSON::Any.new(1),
      }),
      "newText" => JSON::Any.new("x"),
    }), "reason" => "insert_replace_edit_unsupported"},
    "additionalTextEdits"        => {"additionalTextEdits" => JSON::Any.new([] of JSON::Any), "reason" => "additional_text_edits_unsupported"},
    "command"                    => {"command" => JSON::Any.new({"title" => JSON::Any.new("run"), "command" => JSON::Any.new("run")}), "reason" => "command_unsupported"},
    "non-default insertTextMode" => {"insertTextMode" => JSON::Any.new(2), "reason" => "non_default_insert_text_mode"},
  }.each do |label, fields|
    it "rejects #{label} explicitly" do
      payload = {"label" => JSON::Any.new("candidate")}
      fields.each do |key, value|
        next if key == "reason"
        payload[key] = value.as(JSON::Any)
      end
      item = parse_completion({"items" => JSON::Any.new([JSON::Any.new(payload)])})
      raise "missing rejection for #{label}" unless item.rejection_reason == fields["reason"].as(String)
      raise "rejected item must retain its identity" unless item.label == "candidate"
    end
  end

  it "rejects InsertReplaceEdit without partially applying its newText" do
    item = parse_completion({"items" => JSON::Any.new([JSON::Any.new({
      "label"    => JSON::Any.new("candidate"),
      "textEdit" => JSON::Any.new({
        "insert"  => JSON::Any.new({"line" => JSON::Any.new(0), "character" => JSON::Any.new(0)}),
        "replace" => JSON::Any.new({"line" => JSON::Any.new(0), "character" => JSON::Any.new(0)}),
        "newText" => JSON::Any.new("must-not-be-used"),
      }),
    })])})
    raise "InsertReplaceEdit should not produce a standard edit" unless item.text_edit.nil?
    raise "InsertReplaceEdit should not produce fallback insertion" unless item.insert_text.nil?
  end

  it "keeps malformed items visible with an explicit reason" do
    item = parse_completion({"items" => JSON::Any.new([JSON::Any.new({
      "label"    => JSON::Any.new("bad-range"),
      "textEdit" => JSON::Any.new({
        "range" => JSON::Any.new({
          "start" => JSON::Any.new({"line" => JSON::Any.new(Int64::MAX), "character" => JSON::Any.new(0)}),
          "end"   => JSON::Any.new({"line" => JSON::Any.new(0), "character" => JSON::Any.new(0)}),
        }),
        "newText" => JSON::Any.new("x"),
      }),
    })])})
    raise "malformed range must be rejected" unless item.rejection_reason == "malformed_completion_item"
    raise "malformed range must not become a text edit" unless item.text_edit.nil?
    raise "malformed range must not become fallback insertion" unless item.insert_text.nil?
  end

  it "caps textEdit.newText before malformed-range fallback" do
    oversized = "x" * (Adamantine::Lsp::Client::MAX_COMPLETION_INSERTION_BYTES + 1)
    item = parse_completion({"items" => JSON::Any.new([JSON::Any.new({
      "label"    => JSON::Any.new("candidate"),
      "textEdit" => JSON::Any.new({"newText" => JSON::Any.new(oversized)}),
    })])})
    raise "oversized textEdit must report the insertion cap" unless item.rejection_reason == "insertion_too_large"
    raise "oversized malformed textEdit must not expose fallback insertion" unless item.insert_text.nil?
    raise "oversized malformed textEdit must not expose an edit" unless item.text_edit.nil?
  end

  it "rejects non-integer and out-of-range numeric fields without raising" do
    malformed_fields = [
      {"kind" => JSON::Any.new(true)},
      {"insertTextFormat" => JSON::Any.new(1.5)},
      {"insertTextMode" => JSON::Any.new(Int64::MAX)},
    ]

    malformed_fields.each do |field|
      payload = {"label" => JSON::Any.new("candidate")}
      field.each { |key, value| payload[key] = value }
      item = parse_completion({"items" => JSON::Any.new([JSON::Any.new(payload)])})
      raise "numeric field #{field.keys.first} should be rejected" unless item.rejection_reason == "malformed_completion_item"
    end
  end

  it "rejects unsupported CompletionList.itemDefaults without losing items" do
    item = parse_completion({
      "itemDefaults" => JSON::Any.new({"editRange" => JSON::Any.new({} of String => JSON::Any)}),
      "items"        => JSON::Any.new([JSON::Any.new({"label" => JSON::Any.new("defaulted")})]),
    })
    raise "itemDefaults rejection missing" unless item.rejection_reason == "completion_list_item_defaults_unsupported"
    raise "itemDefaults item should remain visible" unless item.label == "defaulted"
  end

  it "caps raw items, labels, and insertion text before mapping" do
    raw_items = Array(JSON::Any).new(101) { |index| JSON::Any.new({"label" => JSON::Any.new("item-#{index}")}) }
    items = CompletionParserTestClient.new.parse_public(JSON::Any.new({"items" => JSON::Any.new(raw_items)}))
    raise "raw completion cap not enforced" unless items.size == Adamantine::Lsp::Client::MAX_COMPLETION_ITEMS

    long_label = "x" * 513
    label_item = parse_completion({"items" => JSON::Any.new([JSON::Any.new({"label" => JSON::Any.new(long_label)})])})
    raise "oversized label should be rejected" unless label_item.rejection_reason == "label_too_long"
    raise "oversized label should not be copied in full" unless label_item.label.size <= Adamantine::Lsp::Client::MAX_COMPLETION_LABEL_CODEPOINTS

    oversized = "x" * (Adamantine::Lsp::Client::MAX_COMPLETION_INSERTION_BYTES + 1)
    insertion_item = parse_completion({"items" => JSON::Any.new([JSON::Any.new({
      "label"      => JSON::Any.new("large"),
      "insertText" => JSON::Any.new(oversized),
    })])})
    raise "oversized insertion should be rejected" unless insertion_item.rejection_reason == "insertion_too_large"
    raise "oversized insertion should not be copied" unless insertion_item.insert_text.nil?
  end

  it "bounds detail and filter display strings by codepoint count" do
    detail = "🙂" * (Adamantine::Lsp::Client::MAX_COMPLETION_DETAIL_CODEPOINTS + 1)
    filter_text = "λ" * (Adamantine::Lsp::Client::MAX_COMPLETION_FILTER_CODEPOINTS + 1)
    item = parse_completion({"items" => JSON::Any.new([JSON::Any.new({
      "label"      => JSON::Any.new("candidate"),
      "detail"     => JSON::Any.new(detail),
      "filterText" => JSON::Any.new(filter_text),
    })])})
    raise "detail display string exceeded codepoint cap" unless item.detail.not_nil!.each_char.size <= Adamantine::Lsp::Client::MAX_COMPLETION_DETAIL_CODEPOINTS
    raise "filter display string exceeded codepoint cap" unless item.filter_text.not_nil!.each_char.size <= Adamantine::Lsp::Client::MAX_COMPLETION_FILTER_CODEPOINTS
    raise "display-only caps should not reject executable label fallback" unless item.rejection_reason.nil?
  end
end
