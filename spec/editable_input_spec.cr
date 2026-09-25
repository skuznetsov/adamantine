require "spec"

require "../src/adamantine/editable_input"

describe Adamantine::EditableInput do
  it "moves and deletes on extended grapheme boundaries" do
    input = Adamantine::EditableInput.new("e\u0301x")

    input.move_home
    input.move_right
    input.cursor.should eq(2)

    input.delete_backward.should be_true
    input.value.should eq("x")
    input.cursor.should eq(0)
  end

  it "treats a ZWJ emoji as one editable unit" do
    family = "👨‍👩‍👧‍👦"
    input = Adamantine::EditableInput.new("#{family}!")

    input.move_home
    input.move_right
    input.cursor.should eq(family.size)

    input.delete_backward.should be_true
    input.value.should eq("!")
  end

  it "extends, replaces, and clears a selection" do
    input = Adamantine::EditableInput.new("alpha")

    input.move_home
    input.move_right(extend_selection: true)
    input.selected_text.should eq("a")
    input.selection_range.should eq({0, 1})

    input.insert("Z").should be_true
    input.value.should eq("Zlpha")
    input.cursor.should eq(1)
    input.selection_range.should be_nil
  end

  it "collapses a selection in the direction of an unshifted arrow" do
    input = Adamantine::EditableInput.new("abcd")
    input.move_home
    3.times { input.move_right(extend_selection: true) }

    input.move_left
    input.cursor.should eq(0)
    input.selection_range.should be_nil

    input.select_all
    input.move_right
    input.cursor.should eq(4)
    input.selection_range.should be_nil
  end

  it "rejects an over-limit replacement atomically" do
    input = Adamantine::EditableInput.new("abcd", max_codepoints: 4)
    input.move_home
    input.move_right(extend_selection: true)
    revision = input.revision

    input.insert("XY").should be_false
    input.value.should eq("abcd")
    input.selection_range.should eq({0, 1})
    input.revision.should eq(revision)
  end

  it "normalizes pasted control characters into one line" do
    input = Adamantine::EditableInput.new

    input.insert_paste("one\r\ntwo\tthree\u0000four").should be_true
    input.value.should eq("one two threefour")
    input.cursor.should eq(input.value.size)
  end

  it "preserves combining, variation-selector, and ZWJ graphemes in paste" do
    text = "e\u0301 ❤️ 👨‍👩‍👧‍👦"
    input = Adamantine::EditableInput.new

    input.insert_paste(text).should be_true
    input.value.should eq(text)
    input.move_left
    input.cursor.should eq("e\u0301 ❤️ ".size)
    input.selected_text.should be_nil
    input.move_right
    input.delete_backward.should be_true
    input.value.should eq("e\u0301 ❤️ ")
  end

  it "keeps the cursor on a boundary when inserted text joins the following grapheme" do
    input = Adamantine::EditableInput.new("👩")
    input.move_home

    input.insert("👨‍").should be_true
    input.value.should eq("👨‍👩")
    input.cursor.should eq(input.value.size)
    input.move_left(extend_selection: true)
    input.selection_range.should eq({0, input.value.size})
  end

  it "accepts a paste that normalizes to an empty no-op" do
    input = Adamantine::EditableInput.new("safe")
    revision = input.revision

    input.insert_paste("\u0000\u007f").should be_true
    input.value.should eq("safe")
    input.revision.should eq(revision)
  end

  it "snaps externally assigned cursors to a grapheme boundary" do
    input = Adamantine::EditableInput.new("e\u0301x")

    input.cursor = 1
    input.cursor.should eq(0)
    input.cursor = 2
    input.cursor.should eq(2)
  end

  it "moves and deletes by words without crossing grapheme boundaries" do
    input = Adamantine::EditableInput.new("one e\u0301clair")

    input.move_word_left
    input.cursor.should eq(4)
    input.delete_word_backward.should be_true
    input.value.should eq("e\u0301clair")
    input.cursor.should eq(0)

    input.move_word_right(extend_selection: true)
    input.selected_text.should eq("e\u0301clair")
  end
end
