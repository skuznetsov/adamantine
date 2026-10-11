require 'digest'
require 'fileutils'
require 'io/console'
require 'json'
require 'pty'
require_relative 'lib/pty_screen'
require 'tmpdir'
require 'timeout'

# Real-PTY restart check for the bounded split-session metadata. All paths are
# private temporary fixtures; no user config, LSP, or recovery state is read.
root = File.realpath(Dir.mktmpdir('adamantine-split-session-'))
project = File.join(root, 'project')
state = File.join(root, 'state')
config = File.join(root, 'config.json')
left = File.join(project, 'left.cr')
right = File.join(project, 'right.cr')
FileUtils.mkdir_p(project)
File.write(left, "LEFT_RESTART_SENTINEL\n")
File.write(right, "RIGHT_RESTART_SENTINEL\n")
File.write(config, '{}')

binary = File.realpath(ARGV.fetch(0) { abort 'usage: ruby scripts/smoke_split_session.rb /path/to/adamantine' })
session_path = File.join(state, 'sessions', "#{Digest::SHA256.hexdigest(File.realpath(project))}.json")
env = {
  'TERM' => 'xterm-256color',
  'ADAMANTINE_SESSION' => '1',
  'ADAMANTINE_RECOVERY' => '0',
  'ADAMANTINE_STATE_HOME' => state,
  'XDG_STATE_HOME' => state,
}

def wait_for(label, timeout: 8, on_timeout: nil)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      detail = on_timeout ? "\n#{on_timeout.call}" : ""
      raise "timeout: #{label}#{detail}"
    end
    sleep 0.02
  end
end

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def type(writer, text)
  text.each_codepoint { |codepoint| key(writer, "\e[#{codepoint}u") }
end

def command(writer, text)
  key(writer, "\e[112;6u") # Ctrl+Shift+P opens the command palette.
  sleep 0.1
  type(writer, ":#{text}")
  key(writer, "\e[13u")
end

def current_screen_rows(state)
  state[:mutex].synchronize do
    if state[:screen_error]
      raise "PTY screen parser failed: #{state[:screen_error]}"
    end
    if state[:drain_error]
      raise "PTY output drain failed: #{state[:drain_error]}"
    end
    state[:screen].rows
  end
end

def current_screen_includes?(state, fragment)
  current_screen_rows(state).any? { |row| row.include?(fragment) }
end

def split_pair_visible?(state, left_sentinel, right_sentinel)
  current_screen_rows(state).any? do |row|
    left_column = row.index(left_sentinel)
    right_column = row.index(right_sentinel)
    next false unless left_column && right_column && left_column < right_column

    row[(left_column + left_sentinel.length)...right_column].include?("│")
  end
end

def editor_bottom_junction_count(state)
  rows = current_screen_rows(state)
  dividers = rows.select do |row|
    row.count("─") >= (row.length * 0.70).to_i && row.include?("┴")
  end
  raise "current screen has no unique shared editor/status divider" unless dividers.size == 1

  dividers.first.count("┴")
end

def run_editor(binary, project, config, env, columns)
  PTY.open do |reader, slave|
    slave.winsize = [22, columns]
    pid = Process.spawn(env, binary, project, '--config', config,
                        in: slave, out: slave, err: slave)
    slave.close
    state = {
      screen: PtyScreen.new(columns, 22),
      mutex: Mutex.new,
      screen_error: nil,
      drain_error: nil,
    }
    drain = Thread.new do
      begin
        loop do
          bytes = reader.readpartial(65_536)
          state[:mutex].synchronize do
            unless state[:screen_error]
              begin
                state[:screen].feed(bytes)
              rescue StandardError => error
                state[:screen_error] = error
              end
            end
          end
        end
      rescue EOFError, Errno::EIO
      rescue StandardError => error
        state[:mutex].synchronize { state[:drain_error] ||= error }
      end
    end
    begin
      wait_for('first render') { current_screen_includes?(state, 'Adamantine') }
      yield reader, state
      command(reader, 'q!')
      wait_for('editor exit') { Process.waitpid(pid, Process::WNOHANG) }
      drain.join(1)
      state
    ensure
      begin
        Process.kill('TERM', pid)
        Process.waitpid(pid)
      rescue Errno::ESRCH, Errno::ECHILD
      end
      drain.join(1)
    end
  end
end

begin
  Timeout.timeout(40) do
    run_editor(binary, project, config, env, 100) do |writer, state|
      command(writer, "open #{left}")
      wait_for('left opened') { current_screen_includes?(state, 'LEFT_RESTART_SENTINEL') }
      command(writer, 'splitright')
      command(writer, "open #{right}")
      wait_for('split opened with both editor groups', on_timeout: -> {
        rows = current_screen_rows(state)
        dividers = rows.select { |row| row.include?("┴") || row.include?("┼") }
        [
          "pair_visible=#{split_pair_visible?(state, 'LEFT_RESTART_SENTINEL', 'RIGHT_RESTART_SENTINEL')}",
          "junction_rows=#{dividers.map { |row| [row.length, row.count('─'), row.count('┴'), row.count('┼')] }.inspect}",
          rows.join("\n"),
        ].join("\n")
      }) do
        split_pair_visible?(state, 'LEFT_RESTART_SENTINEL', 'RIGHT_RESTART_SENTINEL') &&
          editor_bottom_junction_count(state) >= 3
      end
    end

    saved = JSON.parse(File.read(session_path))
    saved_tabs = saved.fetch('tabs').map { |tab| File.basename(tab.fetch('path')) }.sort
    raise 'split state not saved' unless
      saved['version'] == 2 && saved['split_open'] == true && saved['tab_groups'] == [0, 1] &&
      saved['selected_tabs'] == [0, 1] && saved['active_group'] == 1 &&
      saved_tabs == %w[left.cr right.cr]

    run_editor(binary, project, config, env, 100) do |_writer, state|
      wait_for('wide split restored in distinct editor groups') do
        split_pair_visible?(state, 'LEFT_RESTART_SENTINEL', 'RIGHT_RESTART_SENTINEL') &&
          editor_bottom_junction_count(state) >= 3
      end
    end

    run_editor(binary, project, config, env, 48) do |_writer, state|
      wait_for('narrow tabs restored') do
        current_screen_includes?(state, 'left.cr') && current_screen_includes?(state, 'right.cr') &&
          current_screen_includes?(state, 'RIGHT_RESTART_SE')
      end
      raise 'narrow startup rendered an editor split' unless editor_bottom_junction_count(state) == 2
    end

    degraded = JSON.parse(File.read(session_path))
    degraded_tabs = degraded.fetch('tabs').map { |tab| File.basename(tab.fetch('path')) }.sort
    raise 'narrow fallback not persisted' unless
      degraded['split_open'] == false && degraded['tab_groups'] == [0, 0] &&
      degraded_tabs == %w[left.cr right.cr]
  end
  puts JSON.generate(result: 'PASS', wide_restart: true, narrow_fallback: true, tabs_retained: true)
  FileUtils.remove_entry(root)
rescue Exception
  warn "split-session smoke artifacts: #{root}"
  raise
end
