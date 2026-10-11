require "open3"
require_relative "pty_screen"

module CrystalDebugSmoke
  TOOL_KEYS = %i[editor_bin compiler adapter debugserver].freeze
  EDITOR_SOURCE_PROBE = "native_scalar = 314159".freeze
  MAX_VARIABLE_NAVIGATION_ROWS = 128
  VARIABLE_TREE_ROW = /\A(?<indent> {0,8})(?<marker>[▾▸ ]) (?<text>.*)\z/

  class Error < StandardError; end
  class OracleError < Error; end
  class ScreenFailure < Error; end

  def self.resolve_tool_paths!(paths)
    TOOL_KEYS.each_with_object({}) do |key, resolved|
      value = paths[key]
      raise Error, "--#{key.to_s.tr('_', '-')} is required" if value.nil? || value.empty?

      begin
        path = File.realpath(value)
      rescue SystemCallError => error
        raise Error, "--#{key.to_s.tr('_', '-')} is not an existing path: #{error.message}"
      end
      raise Error, "--#{key.to_s.tr('_', '-')} is not an executable file: #{path}" unless File.file?(path) && File.executable?(path)

      resolved[key] = path
    end
  end

  def self.screen_snapshot!(state)
    state[:mutex].synchronize do
      if state[:screen_error]
        raise ScreenFailure, "PTY screen parser failed closed: #{state[:screen_error]}"
      end
      if state[:drain_error]
        raise ScreenFailure, "PTY output drain failed: #{state[:drain_error]}"
      end

      {
        revision: state[:screen].revision,
        alternate_screen: state[:screen].alternate_screen?,
        kitty_keyboard: state[:screen].kitty_keyboard_enabled?,
        rows: state[:screen].rows,
        total_bytes: state[:total_bytes],
      }
    end
  end

  def self.current_row(snapshot, fragment)
    snapshot[:rows].reverse.find { |row| row.include?(fragment) }
  end

  def self.require_current_row!(snapshot, fragment, label: fragment)
    current_row(snapshot, fragment) || raise(Error, "current PTY screen is missing #{label.inspect}")
  end

  def self.require_current_rows!(snapshot, fragments, label: "current screen values")
    missing = fragments.reject { |fragment| snapshot[:rows].any? { |row| row.include?(fragment) } }
    raise Error, "#{label} missing from current PTY screen: #{missing.join(', ')}" unless missing.empty?
    true
  end

  def self.terminal_cells(row)
    cells = []
    row.scan(/\X/).each do |grapheme|
      cells << grapheme
      cells << "" if PtyScreen::WIDE_CODEPOINTS.include?(grapheme.codepoints.first)
    end
    cells
  end

  def self.activity_rail_geometry(grid)
    [[0, 1, 2, false], [1, 3, 4, true]].each do |letter_column, separator_column, workspace_column, padded|
      grid.each_index do |rail_start|
        labels_present = [[rail_start, "Files"], [rail_start + 6, "Debug"]].all? do |start, label|
          label.chars.each_with_index.all? do |letter, offset|
            cells = grid[start + offset]
            next false unless cells && cells[letter_column] == letter && cells[separator_column] == "│"
            !padded || (cells[0] == " " && cells[2] == " ")
          end
        end
        next unless labels_present

        return {
          letter_column: letter_column,
          separator_column: separator_column,
          workspace_column: workspace_column,
          padded: padded,
          rail_start_row: rail_start,
        }
      end
    end
    nil
  end

  def self.require_inspector_rows!(snapshot, pane, fragments, source_fragment:)
    rows = snapshot[:rows]
    grid = rows.map { |row| terminal_cells(row) }
    rail = activity_rail_geometry(grid)
    unless rail
      raise OracleError, "current screen is missing a recognized compact or padded activity rail"
    end
    separator = rail[:separator_column]
    workspace = rail[:workspace_column]
    header = "[#{pane}]"
    header_indices = []
    grid.each_with_index do |row, index|
      next if index.zero?
      next unless row[workspace + 1, header.length].to_a.join == header && row[separator] == "│"

      title_row = grid[index - 1]
      next unless title_row[workspace, 5].to_a.join == "DEBUG" && title_row[separator] == "│"

      header_indices << index
    end
    unless header_indices.size == 1
      raise OracleError, "current screen has no unique #{pane} header owned by the Debug side inspector"
    end
    header_index = header_indices.first
    header_cells = grid[header_index]

    right = (workspace + 1 + header.length...header_cells.length).find do |column|
      header_cells[column] == "│"
    end
    unless right && right >= workspace + 30
      raise OracleError, "current #{pane} header does not bound a side inspector beside the editor"
    end

    panel_rows = []
    grid.each_with_index do |row, index|
      next unless index > header_index
      break unless row[separator] == "│" && row[right] == "│"
      panel_rows << {index: index, row: rows[index],
                     content: row[workspace...right].to_a.join,
                     editor: row[(right + 1)..-1].to_a.join}
    end
    missing = fragments.reject do |fragment|
      panel_rows.any? { |entry| entry[:content].include?(fragment) }
    end
    raise OracleError, "current #{pane} inspector rows are missing: #{missing.join(', ')}" unless missing.empty?

    side_by_side = panel_rows.any? do |entry|
      !entry[:content].strip.empty? && entry[:editor].include?(source_fragment)
    end
    unless side_by_side
      raise OracleError, "current #{pane} inspector content is not beside known editor source on the same screen row"
    end
    panel_rows
  end

  # Maps an exact Variables tree assignment to the number of Down presses from
  # the Locals root. Call only after sending Home; the visible page marker
  # certifies that the current screen is the first page, even when Home was a
  # no-op because the selection already sat at row zero.
  def self.variable_selection_offset!(snapshot, name, source_fragment:)
    panel_rows = require_inspector_rows!(snapshot, "VARIABLES", [], source_fragment: source_fragment)
    screen_rows = snapshot[:rows]
    grid = screen_rows.map { |row| terminal_cells(row) }
    rail = activity_rail_geometry(grid)
    raise OracleError, "current screen is missing an activity rail for Variables row mapping" unless rail
    workspace = rail[:workspace_column]
    separator = rail[:separator_column]
    header_indices = grid.each_with_index.each_with_object([]) do |(row, index), found|
      next if index.zero?
      next unless row[workspace + 1, "[VARIABLES]".length].to_a.join == "[VARIABLES]" && row[separator] == "│"

      title_row = grid[index - 1]
      found << index if title_row[workspace, 5].to_a.join == "DEBUG" && title_row[separator] == "│"
    end
    unless header_indices.size == 1
      raise OracleError, "current screen has no unique Debug-owned Variables header for row mapping"
    end

    header = grid[header_indices.first]
    right = (workspace + 1 + "[VARIABLES]".length...header.length).find do |column|
      header[column] == "│"
    end
    raise OracleError, "current Variables header has no bounded side-inspector range" unless right

    variables_start = workspace + 1
    label_end = ((variables_start + "[VARIABLES".length)...right).find do |column|
      header[column] == "]"
    end
    raise OracleError, "current Variables header label is malformed" unless label_end
    range_text = header[(label_end + 1)...right].to_a.join.strip
    range_match = range_text.match(/\A(\d+)-(\d+)\/(\d+)\z/)
    unless range_match
      raise OracleError, "current Variables header has no exact visible-row range"
    end
    first = range_match[1].to_i
    last = range_match[2].to_i
    total = range_match[3].to_i
    unless first == 1 && last >= first && total >= last && total <= MAX_VARIABLE_NAVIGATION_ROWS
      raise OracleError, "current Variables rows are not a bounded first-page snapshot"
    end

    tree_rows = []
    panel_rows.each do |entry|
      content = entry[:content]
      next if content.strip.empty?

      match = VARIABLE_TREE_ROW.match(content)
      unless match
        raise OracleError, "current Variables body contains a non-tree row; refusing shifted navigation"
      end
      tree_rows << {marker: match[:marker], text: match[:text].rstrip, content: content}
    end
    unless tree_rows.size == last - first + 1 && !tree_rows.empty? && tree_rows.size <= MAX_VARIABLE_NAVIGATION_ROWS
      raise OracleError, "current Variables body does not match its bounded visible-row range"
    end

    root = tree_rows.first
    unless root[:text] == "Locals" && root[:marker] == "▾"
      raise OracleError, "current Variables page does not begin with the expanded Locals root"
    end

    assignment = /\A#{Regexp.escape(name)} = /
    matches = []
    tree_rows.each_with_index do |entry, index|
      matches << index if entry[:text].match?(assignment)
    end
    unless matches.size == 1
      raise OracleError, "current Variables page has no unique exact assignment row for #{name.inspect}"
    end
    matches.first
  end

  def self.require_debug_frame_row!(snapshot, source_line, source_fragment:)
    panel_rows = require_inspector_rows!(snapshot, "STACK", [], source_fragment: source_fragment)
    location = /\bmain\.cr:#{Regexp.escape(source_line.to_s)}\b/
    frame = panel_rows.find do |entry|
      entry[:content].include?("crystal_gate") && entry[:content].match?(location)
    end
    frame && frame[:content] || raise(OracleError, "current Stack inspector has no crystal_gate frame at main.cr:#{source_line}")
  end

  def self.require_value_detail!(snapshot, name, expected_value, expected_type: nil)
    rows = snapshot[:rows]
    candidates = []
    rows.each_with_index do |row, index|
      text_column = row.index("Name: #{name}")
      next unless text_column && text_column >= 2

      left = text_column - 2
      next unless row[left] == "│"
      right = row.index("│", text_column + "Name: #{name}".length)
      next unless right
      next unless row[left + 1...right].to_s.strip == "Name: #{name}"

      title_index = (0...index).to_a.reverse.find do |candidate|
        top = rows[candidate]
        top[left] == "┌" && top[right] == "┐" && top[left + 1...right].to_s.include?("Read-only variable detail")
      end
      next unless title_index

      bottom_index = ((index + 2)...rows.size).find do |candidate|
        bottom = rows[candidate]
        bottom[left] == "└" && bottom[right] == "┘"
      end
      next unless bottom_index

      type_text = rows[index + 1] && rows[index + 1][left + 1...right].to_s.strip
      next unless type_text && type_text.start_with?("Type: ") && !type_text.delete_prefix("Type: ").strip.empty?
      type_name = type_text.delete_prefix("Type: ").strip

      body_rows = ((index + 2)...(bottom_index - 2)).map do |body_index|
        rows[body_index][left + 1...right].to_s.strip
      end.reject(&:empty?)
      candidates << {type: type_name, body: body_rows}
    end

    unless candidates.size == 1
      raise OracleError, "current screen has no unique framed Value Detail modal for #{name.inspect}"
    end
    detail = candidates.first
    if expected_type && detail[:type] != expected_type
      raise OracleError, "#{name} exact type #{expected_type.inspect} is absent from its current Value Detail (saw #{detail[:type].inspect})"
    end
    body_rows = detail[:body]
    unless body_rows.size == 1 && value_detail_summary_matches?(body_rows.first, expected_value, expected_type)
      raise OracleError, "#{name} Value Detail body is not exactly one expected native summary row"
    end
    true
  end

  def self.value_detail_summary_matches?(line, expected_value, expected_type)
    return true if line == expected_value
    return false unless expected_type == "String *" || expected_type == "Array(Int32) *"

    # LLDB-DAP may render these pointer-backed Crystal values as an address
    # followed by the same native summary. Keep the adapter address opaque,
    # but require a bounded hexadecimal pointer and an exact golden suffix.
    line.match?(/\A0x[0-9a-fA-F]{1,16} #{Regexp.escape(expected_value)}\z/)
  end

  def self.parse_process_table(text)
    text.each_line.each_with_object({}) do |line, table|
      match = line.rstrip.match(/\A\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)\z/)
      next unless match

      pid = match[1].to_i
      table[pid] = {
        pid: pid,
        ppid: match[2].to_i,
        pgid: match[3].to_i,
        command: match[4],
      }
    end
  end

  def self.process_table!
    output, error, status = Open3.capture3("ps", "-ww", "-axo", "pid=,ppid=,pgid=,command=")
    raise Error, "could not inspect owned process cleanup: #{error.strip}" unless status.success?
    parse_process_table(output)
  end

  def self.descendant_pids(table, root_pid)
    descendants = []
    frontier = [root_pid]
    until frontier.empty?
      parent = frontier.shift
      children = table.values.select { |process| process[:ppid] == parent }
      children.each do |process|
        next if descendants.include?(process[:pid])
        descendants << process[:pid]
        frontier << process[:pid]
      end
    end
    descendants
  end

  def self.owned_processes(table, editor_pid)
    ([editor_pid] + descendant_pids(table, editor_pid)).uniq.map { |pid| table[pid] }.compact
  end

  def self.processes_for_path(processes, path)
    processes.select { |process| process[:command].include?(path) }
  end

  def self.process_still_matches?(table, captured)
    current = table[captured[:pid]]
    current && current[:command] == captured[:command]
  end

  def self.remaining_processes(captured, table)
    captured.select { |process| process_still_matches?(table, process) }
  end

  def self.process_group_members(table, pgid)
    table.values.select { |process| process[:pgid] == pgid }
  end

  def self.spawned_child_status(pid, timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      begin
        waited = Process.waitpid2(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        return {reaped: true, status: nil}
      end
      return {reaped: true, status: waited[1]} if waited
      return {reaped: false, status: nil} if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.025
    end
  end

  def self.terminate_spawned_child!(pid, term_grace: 1.0, kill_grace: 1.0)
    waited = spawned_child_status(pid, 0)
    return waited[:status] if waited[:reaped]

    begin
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
    end
    waited = spawned_child_status(pid, term_grace)
    return waited[:status] if waited[:reaped]

    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
    end
    waited = spawned_child_status(pid, kill_grace)
    return waited[:status] if waited[:reaped]

    raise Error, "directly spawned child #{pid} did not exit after bounded TERM/KILL cleanup"
  end

end
