#!/usr/bin/env ruby
require "minitest/autorun"
require "rbconfig"
require_relative "lib/pty_screen"
require_relative "lib/crystal_debug_smoke"

class CrystalDebugSmokeTest < Minitest::Test
  EDITOR_SOURCE_PROBE = CrystalDebugSmoke::EDITOR_SOURCE_PROBE

  def test_explicit_tool_paths_are_required_and_resolved
    tools = %i[editor_bin compiler adapter debugserver].to_h { |key| [key, RbConfig.ruby] }
    assert_equal File.realpath(RbConfig.ruby), CrystalDebugSmoke.resolve_tool_paths!(tools)[:editor_bin]

    error = assert_raises(CrystalDebugSmoke::Error) do
      CrystalDebugSmoke.resolve_tool_paths!(tools.merge(adapter: "/definitely/missing/lldb-dap"))
    end
    assert_match(/--adapter is not an existing path/, error.message)
  end

  def test_current_values_and_location_reject_wrong_or_stale_screen_content
    screen = PtyScreen.new(100, 8)
    screen.feed("\e[2J\e[1;1HDEBUG VARS\e[2;1Hmain.cr:5 joined_native_values\e[3;1Hnative_scalar = 314159 (int)")
    state = screen_state(screen)
    initial = CrystalDebugSmoke.screen_snapshot!(state)

    assert CrystalDebugSmoke.require_current_rows!(initial,
      ["main.cr:5", "native_scalar = 314159 (int)"])
    assert_raises(CrystalDebugSmoke::Error) do
      CrystalDebugSmoke.require_current_row!(initial, "main.cr:6", label: "changed stack location")
    end
    assert_raises(CrystalDebugSmoke::Error) do
      CrystalDebugSmoke.require_current_row!(initial, "native_scalar = 314160", label: "changed scalar")
    end

    screen.feed("\e[2J\e[1;1HDEBUG VARS\e[2;1Hmain.cr:6 joined_native_values\e[3;1Hnative_scalar = 314160 (int)")
    current = CrystalDebugSmoke.screen_snapshot!(state)
    assert CrystalDebugSmoke.require_current_rows!(current,
      ["main.cr:6", "native_scalar = 314160 (int)"])
    refute current[:rows].any? { |row| row.include?("main.cr:5") || row.include?("native_scalar = 314159") }
  end

  def test_side_inspector_oracle_binds_locals_and_children_to_the_selected_pane
    %w[compact padded].each do |rail_padding|
      good = side_inspector_snapshot(
        header: "[VARIABLES]",
        panel_line: "native_scalar = 314159",
        editor_line: EDITOR_SOURCE_PROBE,
        rail_padding: rail_padding
      )
      assert CrystalDebugSmoke.require_inspector_rows!(
        good, "VARIABLES", ["native_scalar = 314159"], source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    wide_panel_content = side_inspector_snapshot(
      header: "[VARIABLES]", panel_line: "native_scalar = 314159 雪 marker",
      editor_line: EDITOR_SOURCE_PROBE
    )
    assert CrystalDebugSmoke.require_inspector_rows!(
      wide_panel_content, "VARIABLES", ["native_scalar = 314159 雪 marker"],
      source_fragment: EDITOR_SOURCE_PROBE
    )

    sparse_prompt = side_inspector_snapshot(
      header: "[VARIABLES]", panel_line: "Load scopes to inspect values",
      editor_line: EDITOR_SOURCE_PROBE
    )
    assert CrystalDebugSmoke.require_inspector_rows!(
      sparse_prompt, "VARIABLES", ["Load scopes"], source_fragment: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_inspector_rows!(
        sparse_prompt, "VARIABLES", ["Load scopes"], source_fragment: "native_breakpoint = native_scalar"
      )
    end

    source_only = side_inspector_snapshot(
      header: "[VARIABLES]", panel_line: "Locals", editor_line: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::Error) do
      CrystalDebugSmoke.require_inspector_rows!(
        source_only, "VARIABLES", ["native_scalar = 314159"], source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    not_side_by_side = side_inspector_snapshot(
      header: "[VARIABLES]", panel_line: "native_scalar = 314159", editor_line: "",
      separate_editor_line: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::Error) do
      CrystalDebugSmoke.require_inspector_rows!(
        not_side_by_side, "VARIABLES", ["native_scalar = 314159"], source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    wrong_debug_title = side_inspector_snapshot(
      header: "[VARIABLES]", panel_line: "native_scalar = 314159",
      editor_line: EDITOR_SOURCE_PROBE, panel_title: "FILES"
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_inspector_rows!(
        wrong_debug_title, "VARIABLES", ["native_scalar = 314159"], source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    missing_debug_panel = side_inspector_snapshot(
      header: "[VARIABLES]", panel_line: "native_scalar = 314159",
      editor_line: EDITOR_SOURCE_PROBE, panel_title: nil
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_inspector_rows!(
        missing_debug_panel, "VARIABLES", ["native_scalar = 314159"], source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    wrong_pane = side_inspector_snapshot(
      header: "[OUTPUT]", panel_line: "native_scalar = 314159", editor_line: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_inspector_rows!(
        wrong_pane, "VARIABLES", ["native_scalar = 314159"], source_fragment: EDITOR_SOURCE_PROBE
      )
    end
  end

  def test_variable_selection_offset_uses_exact_visible_tree_row_not_assumed_ordinal
    variable_rows = [
      "▾ Locals",
      "  native_scalar = 314159 (int)",
      "  native_string = \"Crystal gate\" (12 bytes)",
      "▸ __temp_802 = 0 (int)",
      "  __temp_803 = 1 (int)",
      "▸ native_array = [22, 44] (size=2)",
    ]
    snapshot = side_inspector_snapshot(
      header: "[VARIABLES] 1-6/6", panel_lines: variable_rows,
      editor_line: EDITOR_SOURCE_PROBE
    )

    assert_equal 1, CrystalDebugSmoke.variable_selection_offset!(
      snapshot, "native_scalar", source_fragment: EDITOR_SOURCE_PROBE
    )
    assert_equal 2, CrystalDebugSmoke.variable_selection_offset!(
      snapshot, "native_string", source_fragment: EDITOR_SOURCE_PROBE
    )
    assert_equal 5, CrystalDebugSmoke.variable_selection_offset!(
      snapshot, "native_array", source_fragment: EDITOR_SOURCE_PROBE
    )

    prefix_decoy = side_inspector_snapshot(
      header: "[VARIABLES] 1-3/3",
      panel_lines: ["▾ Locals", "  native_array_extra = [22, 44]", "  native_arrayish = [22, 44]"],
      editor_line: "native_array = [22, 44]"
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.variable_selection_offset!(
        prefix_decoy, "native_array", source_fragment: "native_array = [22, 44]"
      )
    end

    duplicate = side_inspector_snapshot(
      header: "[VARIABLES] 1-3/3",
      panel_lines: ["▾ Locals", "  native_array = [22, 44]", "  native_array = [22, 44]"],
      editor_line: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.variable_selection_offset!(
        duplicate, "native_array", source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    shifted_header = side_inspector_snapshot(
      header: "[VARIABLES] 2-4/4",
      panel_lines: ["▾ Locals", "  native_scalar = 314159", "  native_array = [22, 44]"],
      editor_line: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.variable_selection_offset!(
        shifted_header, "native_array", source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    shifted_body = side_inspector_snapshot(
      header: "[VARIABLES] 1-3/3",
      panel_lines: ["! adapter error", "▾ Locals", "  native_array = [22, 44]"],
      editor_line: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.variable_selection_offset!(
        shifted_body, "native_array", source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    oversized = side_inspector_snapshot(
      header: "[VARIABLES] 1-3/129",
      panel_lines: ["▾ Locals", "  native_scalar = 314159", "  native_array = [22, 44]"],
      editor_line: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.variable_selection_offset!(
        oversized, "native_array", source_fragment: EDITOR_SOURCE_PROBE
      )
    end
  end

  def test_stack_oracle_binds_method_and_exact_location_to_stack_slice
    matching = side_inspector_snapshot(
      header: "[STACK]", panel_line: "crystal_gate · main.cr:5",
      editor_line: EDITOR_SOURCE_PROBE
    )
    assert_equal "crystal_gate · main.cr:5", CrystalDebugSmoke.require_debug_frame_row!(
      matching, 5, source_fragment: EDITOR_SOURCE_PROBE
    ).strip

    editor_only_location = side_inspector_snapshot(
      header: "[STACK]", panel_line: "crystal_gate · main.cr:4",
      editor_line: "#{EDITOR_SOURCE_PROBE} main.cr:5"
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_debug_frame_row!(
        editor_only_location, 5, source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    longer_line = side_inspector_snapshot(
      header: "[STACK]", panel_line: "crystal_gate · main.cr:50",
      editor_line: EDITOR_SOURCE_PROBE
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_debug_frame_row!(
        longer_line, 5, source_fragment: EDITOR_SOURCE_PROBE
      )
    end
  end

  def test_inspector_oracle_uses_first_right_boundary_not_an_editor_split
    split_editor = side_inspector_snapshot(
      header: "[VARIABLES]", panel_line: "Locals",
      editor_line: EDITOR_SOURCE_PROBE, second_editor_line: "native_breakpoint = native_scalar",
      secondary_separator: true
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_inspector_rows!(
        split_editor, "VARIABLES", ["native_scalar = 314159"], source_fragment: EDITOR_SOURCE_PROBE
      )
    end

    footer_only = side_inspector_snapshot(
      header: "[VARIABLES]", panel_line: "Locals",
      editor_line: EDITOR_SOURCE_PROBE, footer_line: "native_scalar = 314159"
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_inspector_rows!(
        footer_only, "VARIABLES", ["native_scalar = 314159"], source_fragment: EDITOR_SOURCE_PROBE
      )
    end
  end

  def test_value_detail_oracle_reads_only_exact_body_inside_named_modal
    correct = value_detail_snapshot(
      name: "native_scalar", type: "Int32", body: "314159", background: "native_scalar = 314159"
    )
    assert CrystalDebugSmoke.require_value_detail!(correct, "native_scalar", "314159")

    string_detail = value_detail_snapshot(
      name: "native_string", type: "String *", body: '"Crystal gate" (12 bytes)', background: "native_string = \"Crystal gate\""
    )
    assert CrystalDebugSmoke.require_value_detail!(
      string_detail, "native_string", '"Crystal gate" (12 bytes)', expected_type: "String *"
    )

    array_detail = value_detail_snapshot(
      name: "native_array", type: "Array(Int32) *", body: "[22, 44] (size=2)", background: "native_array = [22, 44]"
    )
    assert CrystalDebugSmoke.require_value_detail!(
      array_detail, "native_array", "[22, 44] (size=2)", expected_type: "Array(Int32) *"
    )

    wrong_body = value_detail_snapshot(
      name: "native_scalar", type: "Int32", body: "271828", background: "native_scalar = 314159"
    )
    assert_raises(CrystalDebugSmoke::Error) do
      CrystalDebugSmoke.require_value_detail!(
        wrong_body, "native_scalar", "314159"
      )
    end

    other_variable = value_detail_snapshot(
      name: "native_scalar", type: "Int32", body: "271828", background: "native_string = 314159"
    )
    assert_raises(CrystalDebugSmoke::Error) do
      CrystalDebugSmoke.require_value_detail!(
        other_variable, "native_scalar", "314159"
      )
    end
  end

  def test_value_detail_oracle_accepts_only_exact_native_summaries_with_optional_pointer_prefix
    string_value = '"Crystal gate" (12 bytes)'
    string_pointer = '0x00000001000c3470 "Crystal gate" (12 bytes)'
    string_detail = value_detail_snapshot(
      name: "native_string", type: "String *", body: string_pointer,
      background: 'native_string = "Crystal gate"'
    )
    assert CrystalDebugSmoke.require_value_detail!(
      string_detail, "native_string", string_value, expected_type: "String *"
    )

    array_value = "[22, 44] (size=2)"
    array_detail = value_detail_snapshot(
      name: "native_array", type: "Array(Int32) *", body: "0x00000001000c3490 #{array_value}",
      background: "native_array = [22, 44]"
    )
    assert CrystalDebugSmoke.require_value_detail!(
      array_detail, "native_array", array_value, expected_type: "Array(Int32) *"
    )

    [
      ["forged address", "0xGG #{string_value}"],
      ["overlong address", "0x00000000000000000 #{string_value}"],
      ["wrong summary", '0x00000001000c3470 "Crystal gate" (13 bytes)'],
      ["trailing text", '0x00000001000c3470 "Crystal gate" (12 bytes) extra'],
    ].each do |label, body|
      detail = value_detail_snapshot(
        name: "native_string", type: "String *", body: body,
        background: 'native_string = "Crystal gate"'
      )
      assert_raises(CrystalDebugSmoke::OracleError, label) do
        CrystalDebugSmoke.require_value_detail!(
          detail, "native_string", string_value, expected_type: "String *"
        )
      end
    end

    wrong_type = value_detail_snapshot(
      name: "native_string", type: "Array(Int32) *", body: string_pointer,
      background: 'native_string = "Crystal gate"'
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_value_detail!(
        wrong_type, "native_string", string_value, expected_type: "String *"
      )
    end

    wrong_name = value_detail_snapshot(
      name: "other_string", type: "String *", body: string_pointer,
      background: 'native_string = "Crystal gate"'
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_value_detail!(
        wrong_name, "native_string", string_value, expected_type: "String *"
      )
    end

    source_only = value_detail_snapshot(
      name: "native_string", type: "String *", body: '0x00000001000c3470 "not gate" (8 bytes)',
      background: 'native_string = "Crystal gate"'
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_value_detail!(
        source_only, "native_string", string_value, expected_type: "String *"
      )
    end

    contradictory_body = value_detail_snapshot(
      name: "native_string", type: "String *", body: string_pointer,
      extra_body: '0x00000001000c3470 "Changed" (7 bytes)',
      background: 'native_string = "Crystal gate"'
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_value_detail!(
        contradictory_body, "native_string", string_value, expected_type: "String *"
      )
    end

    scalar_pointer = value_detail_snapshot(
      name: "native_scalar", type: "Int32", body: "0x00000001000c3470 314159",
      background: "native_scalar = 314159"
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_value_detail!(scalar_pointer, "native_scalar", "314159", expected_type: "Int32")
    end
  end

  def test_selected_detail_oracle_rejects_wrong_nonempty_type
    wrong_type = value_detail_snapshot(
      name: "native_string", type: "Array(Int32) *", body: '"Crystal gate" (12 bytes)',
      background: "native_string = \"Crystal gate\""
    )
    assert_raises(CrystalDebugSmoke::OracleError) do
      CrystalDebugSmoke.require_value_detail!(
        wrong_type, "native_string", '"Crystal gate" (12 bytes)', expected_type: "String *"
      )
    end
  end

  def test_screen_parser_failure_is_not_treated_as_empty_or_pass
    screen = PtyScreen.new(20, 3)
    screen_error = nil
    begin
      screen.feed("\e[?9999h")
    rescue PtyScreen::UnsupportedSequence => error
      screen_error = error.message
    end
    state = screen_state(screen, screen_error: screen_error)
    error = assert_raises(CrystalDebugSmoke::ScreenFailure) { CrystalDebugSmoke.screen_snapshot!(state) }
    assert_match(/failed closed/, error.message)
    refute CrystalDebugSmoke::ScreenFailure <= CrystalDebugSmoke::OracleError
  end

  def test_layout_separator_is_known_single_width_and_unknown_width_still_fails_closed
    screen = PtyScreen.new(8, 2)
    screen.feed("F│─┼D▸▾▼")
    assert_equal "F│─┼D▸▾▼", screen.rows.first

    replacement = PtyScreen.new(8, 2)
    "\uFFFD".encode(Encoding::UTF_8).bytes.each do |byte|
      replacement.feed([byte].pack("C"))
    end
    replacement.finish!
    assert_equal "�       ", replacement.rows.first

    malformed_utf8 = PtyScreen.new(8, 2)
    error = assert_raises(PtyScreen::UnsupportedSequence) { malformed_utf8.feed("\xEF\x00".b) }
    assert_match(/malformed UTF-8/, error.message)

    truncated_utf8 = PtyScreen.new(8, 2)
    truncated_utf8.feed("\xEF\xBF".b)
    error = assert_raises(PtyScreen::UnsupportedSequence) { truncated_utf8.finish! }
    assert_match(/truncated terminal output/, error.message)

    unsupported_width = PtyScreen.new(8, 2)
    error = assert_raises(PtyScreen::UnsupportedSequence) { unsupported_width.feed("\u200d") }
    assert_match(/unsupported Unicode width/, error.message)
  end

  def test_owned_process_tree_and_cleanup_detect_leftovers
    table = CrystalDebugSmoke.parse_process_table(<<~PS)
      100 1 100 /tmp/adamantine
      101 100 100 /opt/llvm/bin/lldb-dap --no-lldbinit
      102 101 100 /tmp/project/debuggee
      200 1 200 /tmp/unrelated
    PS
    owned = CrystalDebugSmoke.owned_processes(table, 100)
    assert_equal [100, 101, 102], owned.map { |process| process[:pid] }.sort
    assert_equal [101], CrystalDebugSmoke.processes_for_path(owned, "/opt/llvm/bin/lldb-dap").map { |process| process[:pid] }
    assert_equal [102], CrystalDebugSmoke.processes_for_path(owned, "/tmp/project/debuggee").map { |process| process[:pid] }
    assert_equal [102], CrystalDebugSmoke.remaining_processes(owned, table).select { |process| process[:pid] == 102 }.map { |process| process[:pid] }

    moved_group = table.merge(102 => table[102].merge(pgid: 999))
    assert_equal [102], CrystalDebugSmoke.remaining_processes(owned, moved_group).select { |process| process[:pid] == 102 }.map { |process| process[:pid] }

    captured_group = CrystalDebugSmoke.process_group_members(table, 100)
    reparented_and_moved = table.merge(102 => table[102].merge(ppid: 1, pgid: 999))
    assert_equal [102], CrystalDebugSmoke.remaining_processes(captured_group, reparented_and_moved)
      .select { |process| process[:pid] == 102 }.map { |process| process[:pid] }

    cleaned = table.reject { |pid, _process| pid == 101 || pid == 102 }
    assert_empty CrystalDebugSmoke.remaining_processes(owned.reject { |process| process[:pid] == 100 }, cleaned)
    assert_equal [200], CrystalDebugSmoke.process_group_members(table, 200).map { |process| process[:pid] }
  end

  def test_bounded_cleanup_kills_and_reaps_a_direct_child_that_ignores_term
    reader, writer = IO.pipe
    pid = Process.spawn(
      RbConfig.ruby, "-e", 'STDOUT.sync = true; Signal.trap("TERM") {}; puts "ready"; sleep 30',
      out: writer
    )
    writer.close
    assert_equal "ready", reader.gets.to_s.strip

    status = CrystalDebugSmoke.terminate_spawned_child!(pid, term_grace: 0.05, kill_grace: 2.0)
    refute_nil status
    assert status.signaled?
    assert_equal Signal.list["KILL"], status.termsig
  ensure
    reader.close rescue nil
    writer.close rescue nil
    if pid
      begin
        CrystalDebugSmoke.terminate_spawned_child!(pid, term_grace: 0.05, kill_grace: 1.0)
      rescue CrystalDebugSmoke::Error
      end
    end
  end

  private

  def screen_state(screen, screen_error: nil)
    {
      mutex: Mutex.new,
      screen: screen,
      screen_error: screen_error,
      drain_error: nil,
      total_bytes: 0,
    }
  end

  def side_inspector_snapshot(header:, panel_line: nil, panel_lines: nil, editor_line:, separate_editor_line: nil,
                              second_editor_line: nil, secondary_separator: false, panel_title: "DEBUG",
                              rail_padding: "compact", footer_line: nil)
    width = 120
    rows = Array.new(15) { Array.new(width, " ") }
    rail_start = 1
    place = lambda do |row_index, column, text|
      offset = 0
      text.each_char do |character|
        rows[row_index][column + offset] = character
        offset += PtyScreen::WIDE_CODEPOINTS.include?(character.codepoints.first) ? 2 : 1
      end
    end
    letter_column, separator_column, workspace_column, right_column, secondary_column =
      if rail_padding == "padded"
        [1, 3, 4, 42, 72]
      else
        [0, 1, 2, 40, 70]
      end
    place.call(0, 0, "Adamantine")
    "Files".chars.each_with_index { |letter, row| place.call(rail_start + row, letter_column, letter) }
    "Debug".chars.each_with_index { |letter, offset| place.call(rail_start + offset + 6, letter_column, letter) }
    place.call(rail_start, workspace_column, panel_title) if panel_title
    place.call(rail_start + 1, workspace_column + 1, header)
    place.call(rail_start + 1, right_column, "│")
    place.call(rail_start + 1, secondary_column, "│") if secondary_separator
    (panel_lines || [panel_line]).each_with_index do |line, offset|
      place.call(rail_start + 2 + offset, workspace_column + 1, line) if line
    end
    place.call(rail_start + 2, right_column, "│")
    place.call(rail_start + 2, secondary_column, "│") if secondary_separator
    place.call(rail_start + 2, right_column + 2, editor_line) unless editor_line.empty?
    if separate_editor_line
      place.call(rail_start + 3, right_column + 2, separate_editor_line)
    end
    place.call(rail_start + 2, secondary_column + 2, second_editor_line) if second_editor_line
    if secondary_separator
      rows[rail_start..].each { |row| row[secondary_column] = "│" }
    end
    rows[rail_start..].each do |row|
      row[separator_column] = "│"
      row[right_column] = "│"
    end
    rows[rail_start..].each { |row| row[secondary_column] = "│" } if secondary_separator
    if footer_line
      rows[14].fill(" ")
      place.call(14, 0, footer_line)
    end
    screen = PtyScreen.new(width, rows.size)
    rows.each_with_index do |row, row_index|
      row.each_with_index do |cell, column|
        next if cell == " "
        screen.feed("\e[#{row_index + 1};#{column + 1}H#{cell}")
      end
    end
    CrystalDebugSmoke.screen_snapshot!(screen_state(screen))
  end

  def value_detail_snapshot(name:, type:, body:, background:, extra_body: nil)
    width = 100
    height = 15
    rows = Array.new(height) { Array.new(width, " ") }
    place = lambda do |row_index, column, text|
      text.each_char.with_index { |character, offset| rows[row_index][column + offset] = character }
    end
    place.call(0, 1, background)
    left = 10
    right = 75
    place.call(2, left, "┌" + ("─" * (right - left - 1)) + "┐")
    place.call(2, left + 2, "Read-only variable detail")
    (3..12).each do |row_index|
      place.call(row_index, left, "│")
      place.call(row_index, right, "│")
    end
    place.call(4, left + 2, "Name: #{name}")
    place.call(5, left + 2, "Type: #{type}")
    place.call(6, left + 2, body)
    place.call(7, left + 2, extra_body) if extra_body
    place.call(11, left + 2, "Adapter summary · value lines 1-1/1")
    place.call(12, left + 2, "Esc/Enter close")
    place.call(13, left, "└" + ("─" * (right - left - 1)) + "┘")
    screen = PtyScreen.new(width, height)
    screen.feed(rows.each_with_index.map { |row, index| "\e[#{index + 1};1H#{row.join}" }.join)
    CrystalDebugSmoke.screen_snapshot!(screen_state(screen))
  end
end
