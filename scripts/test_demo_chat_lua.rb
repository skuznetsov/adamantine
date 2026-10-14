#!/usr/bin/env ruby

require "minitest/autorun"
require_relative "demo_chat_lua"

class DemoChatLuaActiveTabTest < Minitest::Test
  # The initial Log header is positioned at row 26 in the production app's
  # 112x32 PTY. Chat is normal weight and Log is bold.
  LOG_HEADER = (
    "\e[26;1H\e[0m Chat  \e[1m Log \e[0m Ctx:None "
  ).freeze

  # Header-only extraction from a measured production Log -> Chat differential
  # redraw. The app used CUP to row 26, emitted Chat's bold blue cells, then
  # jumped to column 8 and emitted normal-weight Log cells. Per-cell SGR resets
  # are retained because they are the behavior that invalidates stream scans.
  CHAT_HEADER_REDRAW = (
    "\e[26;1H" \
    "\e[0m\e[1m\e[30m\e[48;2;0;122;204m " \
    "\e[0m\e[1m\e[30m\e[48;2;0;122;204mC" \
    "\e[0m\e[1m\e[30m\e[48;2;0;122;204mh" \
    "\e[0m\e[1m\e[30m\e[48;2;0;122;204ma" \
    "\e[0m\e[1m\e[30m\e[48;2;0;122;204mt" \
    "\e[0m\e[1m\e[30m\e[48;2;0;122;204m " \
    "\e[26;8H" \
    "\e[0m\e[38;2;120;120;120m\e[48;2;10;10;10m " \
    "\e[0m\e[38;2;120;120;120m\e[48;2;10;10;10mL" \
    "\e[0m\e[38;2;120;120;120m\e[48;2;10;10;10mo" \
    "\e[0m\e[38;2;120;120;120m\e[48;2;10;10;10mg" \
    "\e[0m\e[38;2;120;120;120m\e[48;2;10;10;10m "
  ).b.freeze

  def test_differential_chat_redraw_updates_current_grid_tab
    probe = AdamantineChatLuaDemo::ActiveTabProbe.new(112, 32)
    probe.feed(LOG_HEADER)
    assert_equal :log, probe.active_tab
    probe.feed("\e[>4m")
    assert_equal :log, probe.active_tab

    probe.feed(CHAT_HEADER_REDRAW)

    assert_equal :chat, probe.active_tab
  end

  def test_differential_redraw_survives_byte_split_feeds
    probe = AdamantineChatLuaDemo::ActiveTabProbe.new(112, 32)
    probe.feed(LOG_HEADER)
    assert_equal :log, probe.active_tab

    CHAT_HEADER_REDRAW.each_byte { |byte| probe.feed([byte].pack("C")) }

    assert_equal :chat, probe.active_tab
  end

  def test_erased_header_does_not_reuse_stale_tab_styles
    probe = AdamantineChatLuaDemo::ActiveTabProbe.new(112, 32)
    probe.feed(LOG_HEADER)
    assert_equal :log, probe.active_tab

    probe.feed("\e[26;1H\e[2K")
    assert_nil probe.active_tab

    probe.feed("\e[26;1H\e[0m Chat   Log  Ctx:None ")
    assert_nil probe.active_tab
  end

  def test_duplicate_header_shaped_transcript_text_fails_closed
    probe = AdamantineChatLuaDemo::ActiveTabProbe.new(112, 32)
    probe.feed(LOG_HEADER)
    assert_equal :log, probe.active_tab

    probe.feed("\e[27;1H\e[0m Chat   Log  Ctx:quoted text")

    assert_nil probe.active_tab
  end
end

class DemoChatLuaBaselineTest < Minitest::Test
  REAL_RED_BASELINE_OUTPUT = <<~OUTPUT.freeze
    FF........

    Failures:

      1) LunaLuaDemo::Pagination returns no more than the requested count for an interior page
           Failure/Error: LunaLuaDemo::Pagination.page(items, 1, 2).should eq(%w[green blue])

             Expected: ["green", "blue"]
                  got: ["green", "blue", "amber"]

           # spec/pagination_spec.cr:8

      2) LunaLuaDemo::Pagination returns one item for an interior one-item page
           Failure/Error: LunaLuaDemo::Pagination.page(items, 2, 1).should eq(["blue"])

             Expected: ["blue"]
                  got: ["blue", "amber"]

           # spec/pagination_spec.cr:14

    Finished in 293 microseconds
    10 examples, 2 failures, 0 errors, 0 pending

    Failed examples:

      crystal spec spec/pagination_spec.cr:5 # LunaLuaDemo::Pagination returns no more than the requested count for an interior page
      crystal spec spec/pagination_spec.cr:11 # LunaLuaDemo::Pagination returns one item for an interior one-item page
  OUTPUT

  class FailedStatus
    def success?
      false
    end
  end

  def validate(output)
    driver = AdamantineChatLuaDemo::Driver.allocate
    driver.send(:validate_red_baseline!, status: FailedStatus.new, output: output)
  end

  def test_accepts_captured_real_ten_example_two_failure_baseline
    assert_nil validate(REAL_RED_BASELINE_OUTPUT)
  end

  def test_rejects_baseline_with_wrong_failure_value
    mutant = REAL_RED_BASELINE_OUTPUT.sub(
      'got: ["green", "blue", "amber"]',
      'got: ["green", "blue"]'
    )

    error = assert_raises(AdamantineChatLuaDemo::Failure) { validate(mutant) }
    assert_equal "baseline was not exactly the two intended pagination failures (10 examples, 2 failures, 0 errors, 0 pending); provider was not contacted", error.message
  end
end

class DemoChatLuaEnvironmentTest < Minitest::Test
  def test_app_child_pins_ambiguous_width_to_the_status_glyph_contract
    driver = AdamantineChatLuaDemo::Driver.allocate
    {
      home: "/private/demo/home",
      state_home: "/private/demo/state",
      tmp: "/private/demo/tmp",
      config: "/private/demo/chat-config.json",
      editor_bin: "/private/demo/adamantine",
      library_path: "/private/demo/liblua54.dylib",
    }.each do |name, value|
      driver.instance_variable_set("@#{name}", value)
    end

    environment = driver.send(:app_environment)

    assert_equal "0", environment.fetch("TUI_AMBIGUOUS_WIDE")
  end
end

class DemoChatLuaReviewTextTest < Minitest::Test
  def test_source_receipt_accepts_opaque_revision_and_rejects_missing_revision
    driver = AdamantineChatLuaDemo::Driver.allocate
    prefix = "Model may read and send bounded excerpts from exact buffer src/pagination.cr, revision "
    assert driver.send(:source_receipt_visible?,
      "#{prefix}cc6b874573358a8592a1b18c48859624")
    assert driver.send(:source_receipt_visible?, "#{prefix}#{'x' * 128} ")
    refute driver.send(:source_receipt_visible?, "#{prefix}#{'x' * 129} ")
    refute driver.send(:source_receipt_visible?,
      prefix.rstrip)
    refute driver.send(:source_receipt_visible?, "#{prefix}   ")
  end

  def test_prompt_label_alone_does_not_complete_review_and_wrapped_prompt_does
    driver = AdamantineChatLuaDemo::Driver.allocate
    refute driver.send(:review_prompt_visible?, "Current prompt:")

    rows = Array.new(32) { " " * 160 }
    rows[4] = (" " * 32) + "┌Review Chat send".ljust(96) + (" " * 32)
    body_row = lambda do |text|
      (" " * 34) + text.ljust(92) + (" " * 34)
    end
    prompt = "Current prompt: #{AdamantineChatLuaDemo::Driver::PROMPT}"
    prompt.chars.each_slice(92).map(&:join).each_with_index do |line, index|
      rows[5 + index] = body_row.call(line)
    end

    review = driver.send(:review_panel_text, rows)
    assert driver.send(:review_prompt_visible?, review)
  end

  def test_joins_only_full_width_modal_continuations
    driver = AdamantineChatLuaDemo::Driver.allocate
    rows = Array.new(32) { " " * 160 }
    rows[4] = (" " * 32) + "┌Review Chat send".ljust(96) + (" " * 32)
    body_row = lambda do |text|
      (" " * 34) + text.ljust(92) + (" " * 34)
    end
    rows[5] = body_row.call("One proposal attempt: at most 32 edits / 8 KiB tool request; manual review only; never auto-")
    rows[6] = body_row.call("applied/saved")
    rows[7] = body_row.call("Limits: 64 KiB source, 8 MiB tracked Lua heap, 5 s, 16 KiB output; Chat shares 16 calls / 51")
    rows[8] = body_row.call("2 KiB result budget")
    rows[9] = body_row.call("Separate controls 51 2 remain distinct")

    review = driver.send(:review_panel_text, rows)
    normalized = driver.send(:normalize_review_text, review)

    assert_includes normalized, "never auto-applied/saved"
    assert_includes normalized, "Chat shares 16 calls / 512 KiB result budget"
    assert_includes normalized, "Separate controls 51 2 remain distinct"
    refute_includes normalized, "Separate controls 512 remain distinct"
  end
end

class DemoChatLuaTerminalEvidenceTest < Minitest::Test
  LOG_HEADER = "\e[26;1H\e[0m Chat  \e[1m Log \e[0m Ctx:None ".freeze
  CHAT_NAME = "Inspect selected pagination source".freeze
  SCRIPT_DIGEST = "954748cc4c3e".freeze

  def test_normalizes_only_known_single_cell_ui_glyphs_across_byte_splits
    normalizer = AdamantineChatLuaDemo::SuccessMarkerNormalizer.new
    output = +"".b
    "before✓←→after".b.each_byte do |byte|
      output << normalizer.feed([byte].pack("C"))
    end
    output << normalizer.finish

    assert_equal "before+<>after".b, output

    unknown = "☃".b
    assert_equal unknown, AdamantineChatLuaDemo::SuccessMarkerNormalizer.new.feed(unknown)
    assert_raises(PtyScreen::UnsupportedSequence) { PtyScreen.new(8, 1).feed(unknown) }
  end

  def test_recognizes_exact_lua_status_rows_inside_the_live_log_and_crops_its_scrollbar
    probe = log_probe
    rows = probe.rows
    driver = driver_for(probe)
    visible = driver.send(:status_log_rows, rows)

    started = visible.find { |row| driver.send(:chat_lua_started_row?, row) }
    complete = visible.find { |row| driver.send(:chat_lua_completion_row?, row) }
    assert_equal :log, probe.active_tab
    assert started, "the started row should not include the Log widget's scrollbar cell"
    assert complete, "the completion row should retain its normalized success marker"
    refute driver.send(:chat_lua_completion_row?, "17:30:24   Chat Lua complete: #{CHAT_NAME}"),
      "a reconstructed row with no success glyph must fail closed"

    probe.feed(DemoChatLuaActiveTabTest::CHAT_HEADER_REDRAW)
    probe.feed("\e[27;1HChat Lua complete: #{CHAT_NAME}")
    assert_equal :chat, probe.active_tab
    assert_empty driver.send(:status_log_rows, probe.rows), "Chat transcript content is not host Log evidence"
  end

  def test_status_rows_are_bound_to_the_same_styled_log_header
    probe = AdamantineChatLuaDemo::ActiveTabProbe.new(160, 32)
    normalizer = AdamantineChatLuaDemo::SuccessMarkerNormalizer.new
    started = "17:30:24 I Chat Lua started: #{CHAT_NAME} [#{SCRIPT_DIGEST}]"
    complete = "17:30:24 ✓ Chat Lua complete: #{CHAT_NAME}"
    footer = "1Commands       2Tree           3Editor         4Refresh"
    raw = "\e[10;1H Chat Log Ctx:quoted"
    raw << "\e[11;1H#{complete}"
    raw << LOG_HEADER
    raw << "\e[27;1H" << (started.ljust(159) + "│")
    raw << "\e[28;1H" << (complete.ljust(159) + "█")
    raw << "\e[32;1H" << footer
    raw.each_byte { |byte| probe.feed(normalizer.feed([byte].pack("C"))) }
    tail = normalizer.finish
    probe.feed(tail) unless tail.empty?

    driver = driver_for(probe)
    visible = driver.send(:status_log_rows, probe.rows)
    accepted = visible.select { |row| driver.send(:chat_lua_completion_row?, row) }

    assert_equal :log, probe.active_tab
    assert_equal 1, accepted.length,
      "only the status row below the unique styled Log header may authenticate completion"
    assert_includes accepted.first, "#{AdamantineChatLuaDemo::Driver::COMPLETION_MARKER}"
  end

  private

  def log_probe
    probe = AdamantineChatLuaDemo::ActiveTabProbe.new(160, 32)
    normalizer = AdamantineChatLuaDemo::SuccessMarkerNormalizer.new
    started = "17:30:24 I Chat Lua started: #{CHAT_NAME} [#{SCRIPT_DIGEST}]"
    complete = "17:30:24 ✓ Chat Lua complete: #{CHAT_NAME}"
    footer = "1Commands       2Tree           3Editor         4Refresh"
    raw = "\e[10;1H←→ Page | Shift-←→ 1cp"
    raw << LOG_HEADER
    raw << "\e[27;1H" << (started.ljust(159) + "│")
    raw << "\e[28;1H" << (complete.ljust(159) + "█")
    raw << "\e[32;1H" << footer
    raw.each_byte { |byte| probe.feed(normalizer.feed([byte].pack("C"))) }
    tail = normalizer.finish
    probe.feed(tail) unless tail.empty?
    probe
  end

  def driver_for(probe)
    driver = AdamantineChatLuaDemo::Driver.allocate
    driver.instance_variable_set(:@state, {screen: probe})
    driver.instance_variable_set(:@script_digest, SCRIPT_DIGEST)
    driver
  end
end

class DemoChatLuaPreviewStabilityTest < Minitest::Test
  def test_waits_for_four_identical_complete_preview_grids_after_a_partial_redraw
    partial = preview_rows("+ fixed line 1t")
    complete = preview_rows("+ fixed line 1 [EOL:LF]")
    driver = scripted_driver([partial, complete, complete, partial, complete, complete, complete, complete])

    result = driver.send(:collect_stable_preview_text)

    assert_equal complete.join("\n"), result
    assert_equal 8, driver.instance_variable_get(:@snapshot_calls)
  end

  def test_fails_closed_when_preview_grid_never_settles
    snapshots = 60.times.map { |index| preview_rows("+ redraw #{index}") }
    driver = scripted_driver(snapshots)

    error = assert_raises(AdamantineChatLuaDemo::Failure) do
      driver.send(:collect_stable_preview_text)
    end

    assert_match(/did not settle/, error.message)
    assert_equal 60, driver.instance_variable_get(:@snapshot_calls)
  end

  private

  def preview_rows(change)
    ["Chat proposed edits Selected 1/1 Group 1/1 Apply Esc Reject src/pagination.cr", change]
  end

  def scripted_driver(snapshots)
    driver = AdamantineChatLuaDemo::Driver.allocate
    driver.instance_variable_set(:@snapshots, snapshots)
    driver.instance_variable_set(:@snapshot_calls, 0)
    deadline = Object.new
    deadline.define_singleton_method(:check!) { |_label| true }
    driver.instance_variable_set(:@deadline, deadline)
    driver.define_singleton_method(:screen_snapshot) do
      @snapshot_calls += 1
      {rows: @snapshots.shift || []}
    end
    driver.define_singleton_method(:sleep) { |_seconds| }
    driver
  end
end

class DemoChatLuaReviewScrollTest < Minitest::Test
  def test_waits_for_complete_send_review_panel_to_settle_before_scrolling
    opening = review_rows("", title: "")
    partial = review_rows("Current prompt: partially painted")
    complete = review_rows("Current prompt: fully painted")
    driver = scripted_driver([opening, partial, complete, complete, complete, complete])

    result = driver.send(:wait_for_stable_review_panel)

    assert_includes result, "Current prompt: fully painted"
    assert_equal 6, driver.instance_variable_get(:@snapshot_calls)
  end

  def test_retries_one_down_only_when_the_first_produces_no_stable_body_change
    driver = AdamantineChatLuaDemo::Driver.allocate
    presses = []
    outcomes = [nil, "next panel"]
    driver.define_singleton_method(:press) { |key| presses << key }
    driver.define_singleton_method(:wait_for_review_body_change) do |_previous, seconds:|
      raise "unexpected wait bound" unless seconds == 0.8
      outcomes.shift
    end

    assert_equal "next panel", driver.send(:scroll_review_body, "current panel")
    assert_equal [AdamantineChatLuaDemo::Driver::DOWN] * 2, presses
  end

  def test_bounds_a_still_unresponsive_review_to_two_down_attempts
    driver = AdamantineChatLuaDemo::Driver.allocate
    presses = []
    driver.define_singleton_method(:press) { |key| presses << key }
    driver.define_singleton_method(:wait_for_review_body_change) { |_previous, seconds:| nil }

    assert_nil driver.send(:scroll_review_body, "current panel")
    assert_equal [AdamantineChatLuaDemo::Driver::DOWN] * 2, presses
  end

  private

  def review_rows(body, title: "Review Chat send")
    rows = Array.new(32) { " " * 160 }
    rows[4] = (" " * 32 + title).ljust(160)
    rows[5] = (" " * 34 + body).ljust(160)
    rows
  end

  def scripted_driver(snapshots)
    driver = AdamantineChatLuaDemo::Driver.allocate
    driver.instance_variable_set(:@snapshots, snapshots)
    driver.instance_variable_set(:@snapshot_calls, 0)
    deadline = Object.new
    deadline.define_singleton_method(:check!) { |_label| true }
    driver.instance_variable_set(:@deadline, deadline)
    driver.define_singleton_method(:screen_snapshot) do
      @snapshot_calls += 1
      {rows: @snapshots.shift || []}
    end
    driver.define_singleton_method(:sleep) { |_seconds| }
    driver
  end
end
