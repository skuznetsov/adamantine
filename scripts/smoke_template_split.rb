require 'fileutils'
require 'io/console'
require 'json'
require 'pty'
require_relative 'lib/pty_screen'
require 'tmpdir'
require 'timeout'

# Bounded real-terminal smoke for editor-owned templates and two editor groups.
# All documents and state are temporary; no LSP or user configuration is used.
ROOT = Dir.mktmpdir('adamantine-template-split-')
LEFT = File.join(ROOT, 'left.cr')
RIGHT = File.join(ROOT, 'right.cr')
CONFIG = File.join(ROOT, 'config.json')
File.write(LEFT, "LEFT_SENTINEL\n")
File.write(RIGHT, '')
File.write(CONFIG, '{}')

OUTPUT = +''

def await(label, timeout: 6, on_timeout: nil)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      detail = on_timeout ? "\n#{on_timeout.call}" : ''
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

def rendered(output)
  output.scrub
    .gsub(/\e\][^\a]*(?:\a|\e\\)/, '')
    .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '')
    .gsub("\r", '')
end

def screen_includes?(state, fragment)
  state[:mutex].synchronize do
    raise "PTY screen parser failed: #{state[:screen_error]}" if state[:screen_error]
    state[:screen].include?(fragment)
  end
end

def screen_rows(state)
  state[:mutex].synchronize do
    raise "PTY screen parser failed: #{state[:screen_error]}" if state[:screen_error]
    state[:screen].rows
  end
end

def output_since(output, offset)
  (output.byteslice(offset..) || '').scrub
end

binary = File.realpath(ARGV.fetch(0) { abort 'usage: ruby scripts/smoke_template_split.rb /path/to/adamantine' })
env = {
  'TERM' => 'xterm-256color',
  'ADAMANTINE_SESSION' => '0',
  'ADAMANTINE_RECOVERY' => '0',
  'ADAMANTINE_STATE_HOME' => File.join(ROOT, 'state'),
  'XDG_STATE_HOME' => File.join(ROOT, 'state'),
}
started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

begin
  Timeout.timeout(30) do
    PTY.spawn(env, binary, ROOT, '--config', CONFIG) do |reader, writer, pid|
      reader.winsize = [18, 70] # Editor area is below the two-pane minimum.
      screen_state = {
        screen: PtyScreen.new(70, 18),
        mutex: Mutex.new,
        screen_error: nil,
      }
      drain = Thread.new do
        begin
          loop do
            bytes = reader.readpartial(65_536)
            OUTPUT << bytes
            screen_state[:mutex].synchronize do
              begin
                screen_state[:screen].feed(bytes)
              rescue StandardError => error
                screen_state[:screen_error] ||= error
              end
            end
          end
        rescue EOFError, Errno::EIO
        end
      end

      begin
        command(writer, "open #{LEFT}")
        await('left document opened') { rendered(OUTPUT).include?('LEFT_SENTINEL') }

        command(writer, 'splitright')
        await('narrow split guard') do
          # The status line clips the long inspector hint at this narrow width;
          # observe the visible guard and ensure it did not create a second group.
          screen_includes?(screen_state, 'Cannot split editor') &&
            !screen_includes?(screen_state, '[Pane 2]')
        end

        screen_state[:mutex].synchronize do
          reader.winsize = [18, 100]
          screen_state[:screen].resize(100, 18)
        end
        sleep 0.15 # Let SIGWINCH reach the application before requesting a split.
        command(writer, 'splitright')
        await('two group layout', on_timeout: -> { screen_rows(screen_state).join("\n") }) do
          screen_includes?(screen_state, '[Pane 2]')
        end

        command(writer, "open #{RIGHT}")
        await('right document opened in active group') do
          screen_includes?(screen_state, 'right.cr') &&
            screen_includes?(screen_state, '[Pane 2]')
        end

        picker_offset = OUTPUT.bytesize
        command(writer, 'template')
        await('built-in template picker') do
          text = rendered(output_since(OUTPUT, picker_offset))
          text.include?('Templates') && text.include?('Method')
        end
        key(writer, "\e[200~UNWANTED_PASTE\e[201~")
        key(writer, "\e[120u") # A normal printable key must also stay in the modal.
        sleep 0.15
        key(writer, "\e[27u") # Cancel the picker without accepting a template.
        sleep 0.15
        save_offset = OUTPUT.bytesize
        command(writer, 'w')
        await('modal input stayed isolated and save completed') do
          text = rendered(output_since(OUTPUT, save_offset))
          text.include?('Saved right.cr') && File.binread(RIGHT).empty?
        end
        raise 'modal input changed the other group' unless File.binread(LEFT) == "LEFT_SENTINEL\n"

        command(writer, 'template def')
        type(writer, 'hello')
        key(writer, "\e[9u")
        type(writer, 'name')
        key(writer, "\e[9u")
        type(writer, 'puts "right"')
        key(writer, "\e[27u")
        sleep 0.1
        command(writer, 'w')
        expected = "def hello(name)\n  puts \"right\"\nend"
        await('template saved in active right group') { File.binread(RIGHT) == expected }
        raise 'template changed left group document' unless File.binread(LEFT) == "LEFT_SENTINEL\n"
        raise 'modal input leaked into inserted template' if File.binread(RIGHT).include?('UNWANTED')

        command(writer, 'q!')
        await('editor exited') { Process.waitpid(pid, Process::WNOHANG) }
        drain.join(1)
      ensure
        File.write(File.join(ROOT, 'terminal.txt'), rendered(OUTPUT))
        begin
          Process.kill('TERM', pid)
          Process.waitpid(pid)
        rescue Errno::ESRCH, Errno::ECHILD
        end
        drain.join(1)
      end
    end
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  puts JSON.generate(result: 'PASS', narrow_split_guard: true, two_groups: true,
                     template_picker: true, modal_isolation: true,
                     template_in_right_group: true, disk_isolation: true,
                     elapsed_seconds: elapsed.round(2))
  FileUtils.remove_entry(ROOT)
rescue Exception => error
  warn "template/split smoke artifacts: #{ROOT}"
  raise error
end
