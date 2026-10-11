require "spec"
require "crystal_tui"
require "../src/adamantine/chat_frontend"
require "../src/adamantine/chat_composer"
require "../src/adamantine/chat_panel"

describe Adamantine::Chat::Composer do
  it "preserves multiline bracketed paste while normalizing CRLF" do
    composer = Adamantine::Chat::Composer.new

    composer.paste("def greet\r\n\tputs \"hi\"\r\nend")

    composer.text.should eq("def greet\n\tputs \"hi\"\nend")
  end

  it "rejects invalid UTF-8 without changing the draft" do
    composer = Adamantine::Chat::Composer.new
    composer.insert_text("safe")

    composer.paste(String.new(Bytes[0xff]))

    composer.text.should eq("safe")
    composer.status.should eq(Adamantine::Chat::DRAFT_UTF8_STATUS)
  end

  it "rejects an oversized paste atomically" do
    composer = Adamantine::Chat::Composer.new

    composer.paste("x" * (Adamantine::Chat::MAX_DRAFT_BYTES + 1))

    composer.text.should be_empty
    composer.status.should eq("Draft exceeds 16 KiB.")
  end

  it "removes terminal control characters but keeps tabs and newlines" do
    composer = Adamantine::Chat::Composer.new

    composer.paste("a\u001b[31m\tb\n")

    composer.text.should eq("a[31m\tb\n")
  end

  it "advances a mutation revision across edit and undo ABA" do
    composer = Adamantine::Chat::Composer.new
    composer.insert_text("draft")
    initial = composer.mutation_revision

    composer.insert_text("x")
    composer.undo.should be_true

    composer.text.should eq("draft")
    composer.mutation_revision.should be > initial
  end

  it "keeps the draft tail visible when the focused composer viewport shrinks" do
    frontend = Adamantine::Chat::Frontend.new
    panel = Adamantine::Chat::Panel.new(frontend, Tui::Log.new("status"))
    panel.rect = Tui::Rect.new(0, 0, 112, 14)
    panel.select_chat
    panel.composer.paste([
      "WIDTH_BEGIN if true WIDTH_END",
      "if true",
      "puts \"λ CHAT_PASTE 雪\"",
      "end",
      "SHIFT_ENTER_MARKER",
      "ALT_ENTER_MARKER λ雪😀é",
    ].join("\n"))

    large = Tui::Buffer.new(112, 14)
    panel.render(large, Tui::Rect.new(0, 0, 112, 14))
    panel.composer.cursor_line.should eq(5)
    5.times { panel.composer.on_event(Tui::KeyEvent.new(Tui::Key::Up)) }
    5.times { panel.composer.on_event(Tui::KeyEvent.new(Tui::Key::Down)) }
    panel.composer.cursor_line.should eq(5)
    panel.composer.scroll_y.should eq(0)

    panel.composer.select_range(4, 0, 5, panel.composer.cursor_col, cursor_at_end: true)
    original_text = panel.composer.text.dup
    original_revision = panel.composer.mutation_revision
    original_cursor = {panel.composer.cursor_line, panel.composer.cursor_col}
    original_selection = panel.composer.copy

    panel.rect = Tui::Rect.new(0, 0, 64, 7)
    small = Tui::Buffer.new(64, 7)
    panel.render(small, Tui::Rect.new(0, 0, 64, 7))

    panel.composer.scroll_y.should eq(1)
    panel.composer.text.should eq(original_text)
    panel.composer.mutation_revision.should eq(original_revision)
    {panel.composer.cursor_line, panel.composer.cursor_col}.should eq(original_cursor)
    panel.composer.copy.should eq(original_selection)
    rows = (0...7).map do |y|
      String.build do |row|
        64.times do |x|
          cell = small.get(x, y)
          row << cell.glyph unless cell.continuation?
        end
      end
    end
    rows.join("\n").should contain("ALT_ENTER_MARKER")
    rows.join("\n").should contain("SHIFT_ENTER_MARKER")
    rows.join("\n").should contain("λ")
    rows.join("\n").should contain("雪")
    rows.join("\n").should contain("😀")
    rows.join("\n").should contain("é")
  end
end

describe Adamantine::Chat::Panel do
  it "restores hidden auto-scroll after log entries arrive with zero-height geometry" do
    log = Tui::Log.new("status")
    log.show_timestamp = false
    log.show_level = false
    log.info("Tip: seeded visible entry")
    panel = Adamantine::Chat::Panel.new(Adamantine::Chat::Frontend.new, log)
    panel.rect = Tui::Rect.new(0, 0, 48, 8)
    panel.select_chat(focus: false)

    log.warning("provider unavailable while Log is hidden")
    log.scroll_offset.should eq(log.entries.size)

    panel.select_log(focus: false)
    panel.render(Tui::Buffer.new(48, 8), Tui::Rect.new(0, 0, 48, 8))

    log.scroll_offset.should eq(Math.max(0, log.entries.size - log.visible_count))
    log.scroll_offset.should be < log.entries.size
    rendered = Tui::Buffer.new(48, 8)
    panel.render(rendered, Tui::Rect.new(0, 0, 48, 8))
    rows = (0...8).map do |y|
      String.build do |row|
        48.times do |x|
          cell = rendered.get(x, y)
          row << cell.glyph unless cell.continuation?
        end
      end
    end
    rows.join("\n").should contain("Tip: seeded visible entry")
  end

  it "preserves manual log position when returning from Chat" do
    log = Tui::Log.new("status")
    log.rect = Tui::Rect.new(0, 1, 48, 4)
    8.times { |index| log.info("entry #{index}") }
    log.auto_scroll = false
    log.scroll_offset = 2
    panel = Adamantine::Chat::Panel.new(Adamantine::Chat::Frontend.new, log)
    panel.rect = Tui::Rect.new(0, 0, 48, 8)
    panel.select_chat(focus: false)

    log.info("new entry while manually scrolled")
    panel.select_log(focus: false)

    log.scroll_offset.should eq(2)
    log.auto_scroll.should be_false
  end
end
