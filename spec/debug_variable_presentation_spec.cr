require "spec"
require "crystal_tui"

require "../src/adamantine/debug_variable_presenter"

describe Adamantine::Debugging::DebugVariablePresenter do
  it "renders actual scope roots as groups with explicit partial paging" do
    root = Adamantine::Debugging::DebugVariableNode.new(
      "locals", nil, "Locals", "", nil, 70, 3, nil, 0,
      Adamantine::Debugging::DebugVariableLoadState::Partial, ["first"] of String
    )

    row = Adamantine::Debugging::DebugVariablePresenter.row(root, 0, true, 64)

    row.should contain("Locals")
    row.should contain("Partial")
    row.should contain("m: more")
    row.should_not contain("Locals =")
  end

  it "reserves typed value and status cells against very long names and types" do
    long_name = Adamantine::Debugging::DebugVariableNode.new(
      "long-name", "locals", "x" * 512, "42", "Int32", 0, nil, nil, 1,
      Adamantine::Debugging::DebugVariableLoadState::Partial, [] of String
    )
    long_type = Adamantine::Debugging::DebugVariableNode.new(
      "long-type", "locals", "x", "a" * 256, "Type" * 64, 0, nil, nil, 1,
      Adamantine::Debugging::DebugVariableLoadState::Partial, [] of String
    )

    name_row = Adamantine::Debugging::DebugVariablePresenter.row(long_name, 32, false, 48)
    type_row = Adamantine::Debugging::DebugVariablePresenter.row(long_type, 1, false, 48)

    name_row.should contain("42")
    name_row.should contain("Int32")
    name_row.should contain("m: more")
    name_row.should contain("…")
    type_row.should contain("a")
    type_row.should contain("m: more")
    type_row.should contain("…")
    Tui::Unicode.display_width(name_row).should be <= 48
    Tui::Unicode.display_width(type_row).should be <= 48
  end

  it "keeps a real summary and the paging affordance at narrow widths before optional type text" do
    [20, 24, 32].each do |width|
      node = Adamantine::Debugging::DebugVariableNode.new(
        "narrow", "locals", "n" * 512, "42", "LongTypeName" * 16, 0, nil, nil, 1,
        Adamantine::Debugging::DebugVariableLoadState::Partial, [] of String
      )
      row = Adamantine::Debugging::DebugVariablePresenter.row(node, 20, false, width)

      row.should contain("42")
      row.should contain("m: more")
      Tui::Unicode.display_width(row).should be <= width
    end
  end

  it "distinguishes an empty opaque summary from the adapter summary `\"\"` without inventing a value" do
    empty = Adamantine::Debugging::DebugVariableNode.new(
      "empty", "locals", "empty_value", "", "String", 0, nil, nil, 1,
      Adamantine::Debugging::DebugVariableLoadState::Loaded, [] of String
    )
    quoted_empty = Adamantine::Debugging::DebugVariableNode.new(
      "quoted-empty", "locals", "quoted_value", "\"\"", "String", 0, nil, nil, 1,
      Adamantine::Debugging::DebugVariableLoadState::Loaded, [] of String
    )

    empty_row = Adamantine::Debugging::DebugVariablePresenter.row(empty, 0, false, 64)
    quoted_row = Adamantine::Debugging::DebugVariablePresenter.row(quoted_empty, 0, false, 64)

    empty_row.should contain("empty summary")
    empty_row.should_not contain("empty_value = \"\"")
    quoted_row.should contain("quoted_value = \"\"")
    quoted_row.should_not contain("empty summary")
  end

  it "keeps truncation visible at one-, two-, and three-cell widths" do
    Adamantine::Debugging::DebugVariablePresenter.truncate("x", 1).should eq("x")

    [1, 2, 3].each do |width|
      row = Adamantine::Debugging::DebugVariablePresenter.truncate("👩‍💻value", width)
      Tui::Unicode.display_width(row).should be <= width
      row.should contain("…")
    end

    combining = Adamantine::Debugging::DebugVariablePresenter.truncate("e\u0301xyz", 2)
    combining.should eq("e\u0301…")
  end

  it "marks an unrenderable wide glyph once without producing blank continuation rows" do
    lines, limited = Adamantine::Debugging::DebugVariablePresenter.wrap("漢漢", 1)

    limited.should be_true
    lines.should eq(["…"])
  end

  it "wraps opaque multiline Unicode values without splitting graphemes and exposes control bytes" do
    lines, limited = Adamantine::Debugging::DebugVariablePresenter.wrap("👩‍💻e\u0301\n\u0000x", 3)

    limited.should be_false
    lines.first.should eq("👩‍💻e\u0301")
    lines.join.includes?("\\u0000x").should be_true
    lines.each { |line| Tui::Unicode.display_width(line).should be <= 3 }
  end

  it "escapes invisible directional marks so opaque values cannot reorder their neighbors" do
    value = "ab\u200Fcd|ab\u061Ccd"
    lines, limited = Adamantine::Debugging::DebugVariablePresenter.wrap(value, 32)

    limited.should be_false
    lines.should eq(["ab\\u200fcd|ab\\u061ccd"])
  end

  it "bounds detail wrapping and marks omitted display lines" do
    lines, limited = Adamantine::Debugging::DebugVariablePresenter.wrap("abcdefgh", 2, 2)

    limited.should be_true
    lines.size.should eq(2)
    lines.last.should eq("…")
  end
end
