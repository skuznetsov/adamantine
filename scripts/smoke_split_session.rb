require 'digest'
require 'fileutils'
require 'io/console'
require 'json'
require 'pty'
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

def wait_for(label, timeout: 8)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    raise "timeout: #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
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

def rendered(output)
  output.scrub.gsub(/\e\][^\a]*(?:\a|\e\\)/, '')
        .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '')
        .gsub("\r", '')
end

def run_editor(binary, project, config, env, columns)
  PTY.open do |reader, slave|
    slave.winsize = [22, columns]
    pid = Process.spawn(env, binary, project, '--config', config,
                        in: slave, out: slave, err: slave)
    slave.close
    output = +''
    drain = Thread.new do
      begin
        loop { output << reader.readpartial(65_536) }
      rescue EOFError, Errno::EIO
      end
    end
    begin
      wait_for('first render') { rendered(output).include?('Adamantine') }
      yield reader, output
      command(reader, 'q!')
      wait_for('editor exit') { Process.waitpid(pid, Process::WNOHANG) }
      drain.join(1)
      output
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
    run_editor(binary, project, config, env, 100) do |writer, output|
      command(writer, "open #{left}")
      wait_for('left opened') { rendered(output).include?('LEFT_RESTART_SENTINEL') }
      command(writer, 'splitright')
      wait_for('split opened') { rendered(output).include?('Group 2 *') }
      command(writer, "open #{right}")
      wait_for('right opened') { rendered(output).include?('RIGHT_RESTART_SENTINEL') }
    end

    saved = JSON.parse(File.read(session_path))
    raise 'split state not saved' unless saved['version'] == 2 && saved['split_open'] == true && saved['tab_groups'] == [0, 1]

    run_editor(binary, project, config, env, 100) do |_writer, output|
      wait_for('wide split restored') do
        text = rendered(output)
        text.include?('Group 1') && text.include?('Group 2 *') &&
          text.include?('left.cr') && text.include?('right.cr')
      end
    end

    run_editor(binary, project, config, env, 48) do |_writer, output|
      wait_for('narrow tabs restored') do
        text = rendered(output)
        text.include?('left.cr') && text.include?('right.cr')
      end
      raise 'narrow startup rendered a split' if rendered(output).include?('Group 2')
    end

    degraded = JSON.parse(File.read(session_path))
    raise 'narrow fallback not persisted' unless degraded['split_open'] == false && degraded['tab_groups'] == [0, 0]
  end
  puts JSON.generate(result: 'PASS', wide_restart: true, narrow_fallback: true, tabs_retained: true)
  FileUtils.remove_entry(root)
rescue Exception
  warn "split-session smoke artifacts: #{root}"
  raise
end
