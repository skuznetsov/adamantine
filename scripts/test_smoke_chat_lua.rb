#!/usr/bin/env ruby

require "minitest/autorun"
require_relative "smoke_chat_lua"

class SmokeChatLuaReviewCaptureTest < Minitest::Test
  SOURCE_LINE_4 = 'local proposal = editor.call("editor.propose_edits", {'.freeze

  def test_cursor_only_output_can_advance_pty_revision_without_changing_rows
    screen = PtyScreen.new(WIDTH, HEIGHT)
    screen.feed("\e[2J\e[1;1HReview Chat send")
    prior_rows = screen.rows
    prior_revision = screen.revision

    screen.feed("\e[1;1H")

    assert_equal prior_rows, screen.rows
    assert_operator screen.revision, :>, prior_revision
  end

  def test_selection_range_en_dash_is_rendered_as_a_single_cell
    screen = PtyScreen.new(WIDTH, HEIGHT)

    screen.feed("Selection scope: selection: 1:7–1:13")

    assert_includes screen.rows.first, "1:7–1:13"
  end

  class DelayedReviewScreen
    def initialize(modal: true, complete: true)
      @screen = PtyScreen.new(WIDTH, HEIGHT)
      @reads = 0
      @pending_partial_at = nil
      @pending_redraw_at = nil
      @redraw_scheduled = false
      @rows = review_rows(initial_review_lines, modal: modal, complete: complete)
    end

    def revision
      @screen.revision
    end

    def rows
      @screen.rows
    end

    def observe
      @reads += 1
      if @pending_partial_at && @reads >= @pending_partial_at
        @rows = review_rows(partial_review_lines, modal: true, complete: true)
        @pending_partial_at = nil
      end
      if @pending_redraw_at && @reads >= @pending_redraw_at
        @rows = review_rows(scrolled_review_lines, modal: true, complete: true)
        @pending_redraw_at = nil
      end
      @screen.feed(render_review(@rows))
    end

    def key_down
      # Cursor positioning advances PtyScreen#revision without changing any
      # visible cells, just as a partial/control-only PTY redraw can.
      @screen.feed("\e[1;1H")
      return if @redraw_scheduled

      @redraw_scheduled = true
      @pending_partial_at = @reads + 7
      @pending_redraw_at = @reads + 14
    end

    private

    def initial_review_lines
      lines = Array.new(16) { |index| "Review metadata row #{index + 1}" }
      lines.concat([
        "Script source (frozen locally; not sent to provider):",
        'local source_only = "CHAT_LUA_STICKY_SOURCE_ONLY"',
        "local selected = editor.context.selected_buffer",
        "assert(selected)",
        SOURCE_LINE_4,
        "  buffer_id=selected.buffer_id, revision=selected.revision,",
      ])
      lines
    end

    def scrolled_review_lines
      initial_review_lines.drop(1)
    end

    def partial_review_lines
      lines = initial_review_lines.dup
      lines[0] = lines[1]
      lines
    end

    def review_rows(body, modal:, complete:)
      rows = Array.new(HEIGHT) { " " * WIDTH }
      rows[1] = "STALE_OUTSIDE_MODAL_SOURCE_SENTINEL #{SOURCE_LINE_4}"
      return rows unless modal

      title = "┌Review Chat send"
      panel_left = 8
      panel_width = 96
      rows[4] = (" " * panel_left) + title + ("─" * (panel_width - title.length - 1)) + "┐"
      body.first(20).each_with_index do |line, index|
        rows[5 + index] = panel_line(line, panel_left, panel_width)
      end
      rows[26] = panel_line("Y send | Enter/Esc cancel | Up/Down scroll", panel_left, panel_width)
      rows[27] = (" " * panel_left) + "└" + ("─" * (panel_width - 2)) + "┘" if complete
      rows
    end

    def panel_line(text, left, width)
      (" " * left) + "│" + text.ljust(width - 2)[0, width - 2] + "│"
    end

    def render_review(rows)
      output = +"\e[2J"
      rows.each_with_index do |row, index|
        output << "\e[#{index + 1};1H" << row
      end
      output
    end
  end

  class DownWriter
    attr_reader :writes

    def initialize(screen)
      @screen = screen
      @writes = 0
    end

    def write(sequence)
      raise "unexpected review input #{sequence.inspect}" unless sequence == CURSOR_DOWN

      @writes += 1
      @screen.key_down
      sequence.bytesize
    end

    def flush
      self
    end
  end

  def test_waits_for_review_body_redraw_and_captures_only_the_current_modal
    screen = DelayedReviewScreen.new
    state = {mutex: Mutex.new, screen: screen, screen_error: nil}
    driver = review_driver(screen)

    captured = driver.send(:collect_review_screens, DownWriter.new(screen), state)

    assert_includes captured, SOURCE_LINE_4,
      "collector stopped on a revision-only PTY update before the review body redraw"
    refute_includes captured, "STALE_OUTSIDE_MODAL_SOURCE_SENTINEL",
      "text outside the current Send review modal must not satisfy its evidence checks"
  end

  def test_rejects_absent_or_incompletely_drawn_modal_before_scrolling
    [DelayedReviewScreen.new(modal: false), DelayedReviewScreen.new(complete: false)].each do |screen|
      writer = DownWriter.new(screen)
      driver = review_driver(screen)

      error = assert_raises(RuntimeError) do
        driver.send(:collect_review_screens, writer, {mutex: Mutex.new, screen: screen, screen_error: nil})
      end

      assert_equal "Send review did not produce a stable modal frame", error.message
      assert_equal 0, writer.writes, "must not scroll or approve an unframed modal"
    end
  end

  def test_missing_source_line_still_fails_before_send_approval
    source = <<~LUA
      local source_only = "CHAT_LUA_STICKY_SOURCE_ONLY"
      local selected = editor.context.selected_buffer
      assert(selected)
      #{SOURCE_LINE_4}
    LUA
    visible = <<~REVIEW
      SHA-256: #{Digest::SHA256.hexdigest(source)}
      Current prompt: CHAT_LUA_STICKY_TURN
      Script source (frozen locally; not sent to provider):
      local source_only = "CHAT_LUA_STICKY_SOURCE_ONLY"
      local selected = editor.context.selected_buffer
      assert(selected)
    REVIEW
    fixture = {
      metadata: {"CHAT_LUA_STICKY_TURN" => {digest: Digest::SHA256.hexdigest(source), name: "sticky fixture", capabilities: []}},
      sources: {"sticky" => source},
    }
    driver = Object.new
    driver.define_singleton_method(:collect_review_screens) { |_writer, _state| visible }
    writer = Object.new

    error = assert_raises(RuntimeError) do
      driver.send(:accept_send, writer, nil, fixture, "CHAT_LUA_STICKY_TURN", "sticky")
    end

    assert_includes error.message, "Send review omitted Lua source line 4"
    assert_includes error.message, SOURCE_LINE_4
  end

  def test_stale_review_for_same_script_cannot_satisfy_current_prompt_identity
    source = "local selected = editor.context.selected_buffer\n"
    stale_review = <<~REVIEW
      SHA-256: #{Digest::SHA256.hexdigest(source)}
      Current prompt: CHAT_LUA_PREVIOUS_TURN
      Script source (frozen locally; not sent to provider):
      local selected = editor.context.selected_buffer
    REVIEW
    fixture = {
      metadata: {"CHAT_LUA_CURRENT_TURN" => {digest: Digest::SHA256.hexdigest(source), name: "same script", capabilities: []}},
      sources: {"same-script" => source},
    }
    driver = Object.new
    driver.define_singleton_method(:collect_review_screens) { |_writer, _state| stale_review }

    error = assert_raises(RuntimeError) do
      driver.send(:accept_send, Object.new, nil, fixture, "CHAT_LUA_CURRENT_TURN", "same-script")
    end

    assert_equal 'Send review omitted the current prompt "CHAT_LUA_CURRENT_TURN"', error.message
  end

  private

  def review_driver(screen)
    driver = Object.new
    fake_time = [0.0]
    driver.define_singleton_method(:current_screen) do |_state|
      screen.observe
      {revision: screen.revision, rows: screen.rows}
    end
    driver.define_singleton_method(:key) { |writer, input| writer.write(input); writer.flush }
    driver.define_singleton_method(:monotonic) { fake_time[0] += 0.01 }
    driver.define_singleton_method(:sleep) { |seconds| fake_time[0] += seconds }
    driver
  end
end
