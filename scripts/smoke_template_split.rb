require 'fileutils'
require 'io/console'
require 'json'
require 'pty'
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

def await(label, timeout: 6)
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
  output.scrub
    .gsub(/\e\][^\a]*(?:\a|\e\\)/, '')
    .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '')
    .gsub("\r", '')
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
      drain = Thread.new do
        begin
          loop { OUTPUT << reader.readpartial(65_536) }
        rescue EOFError, Errno::EIO
        end
      end

      begin
        command(writer, "open #{LEFT}")
        await('left document opened') { rendered(OUTPUT).include?('LEFT_SENTINEL') }

        narrow_offset = OUTPUT.bytesize
        command(writer, 'splitright')
        await('narrow split guard') do
          rendered(output_since(OUTPUT, narrow_offset)).include?('Cannot split editor') &&
            rendered(output_since(OUTPUT, narrow_offset)).include?('widen the window')
        end

        reader.winsize = [18, 100]
        sleep 0.15 # Let SIGWINCH reach the application before requesting a split.
        split_offset = OUTPUT.bytesize
        command(writer, 'splitright')
        await('two group layout') do
          text = rendered(output_since(OUTPUT, split_offset))
          text.include?('Group 1') && text.include?('Group 2 *')
        end

        right_open_offset = OUTPUT.bytesize
        command(writer, "open #{RIGHT}")
        await('right document opened in active group') do
          text = rendered(output_since(OUTPUT, right_open_offset))
          text.include?('right.cr') && text.include?('Group 2 *')
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
