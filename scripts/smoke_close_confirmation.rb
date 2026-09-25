require 'pty'
require 'io/console'
require 'tmpdir'
require 'json'

# Real terminal gate: run against a built editor, never the user's files.
root = Dir.mktmpdir('adamantine-close-')
first = File.join(root, 'first.cr')
second = File.join(root, 'second.cr')
config = File.join(root, 'config.json')
events = File.join(root, 'events.jsonl')
File.write(first, "first\n")
File.write(second, "second\n")
File.write(config, '{}')
fixture = File.expand_path('../spec/fixtures/formatting_probe_server.rb', __dir__)
binary = ARGV.fetch(0)
output = +''

def await(label)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until yield
    raise "timeout: #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.02
  end
end

def messages(path)
  return [] unless File.exist?(path)
  File.readlines(path).map { |line| JSON.parse(line) rescue nil }.compact
end

def terminal_text(output)
  output.gsub(/\e\[[0-9;?<>]*[A-Za-z]/, '')
end

def command(writer, text)
  writer.write("\e[112;6u")
  sleep 0.15
  ":#{text}".each_codepoint { |codepoint| writer.write("\e[#{codepoint}u") }
  writer.write("\e[13u")
end

env = {'TERM' => 'xterm-256color', 'ADAMANTINE_SESSION' => '0', 'ADAMANTINE_RECOVERY' => '0'}
PTY.spawn(env, binary, root, '--config', config,
          '--lsp', '/usr/bin/ruby', '--lsp-arg', fixture, '--lsp-arg', events) do |reader, writer, pid|
  reader.winsize = [32, 140]
  drain = Thread.new do
    begin
      loop { output << reader.readpartial(65536) }
    rescue EOFError, Errno::EIO
    end
  end
  begin
    await('connection') { messages(events).any? { |e| e['method'] == 'initialized' } }
    command(writer, "open #{first}")
    await('first open') { messages(events).count { |e| e['method'] == 'textDocument/didOpen' } == 1 }
    writer.write("\e[88u")
    await('first edit') { messages(events).any? { |e| e['method'] == 'textDocument/didChange' } }
    offset = output.size
    command(writer, 'close')
    await('file-scoped choices') do
      text = terminal_text(output[offset..])
      text.include?('Save') && text.include?('Discard') && text.include?('Cancel') && text.include?('first.cr')
    end
    changes = messages(events).count { |e| e['method'] == 'textDocument/didChange' }
    writer.write("\e[200~UNWANTED\e[201~")
    writer.write("\e[115;5u") # Ctrl+S must not save behind the modal.
    sleep 0.2
    writer.write("\e[13u") # Default action is Cancel.
    sleep 0.2
    raise 'modal leaked input' unless messages(events).count { |e| e['method'] == 'textDocument/didChange' } == changes
    raise 'cancel closed tab' if messages(events).any? { |e| e['method'] == 'textDocument/didClose' }
    raise 'modal saved source' unless File.read(first) == "first\n"

    command(writer, "open #{second}")
    await('second open') { messages(events).count { |e| e['method'] == 'textDocument/didOpen' } == 2 }
    writer.write("\e[89u")
    await('second edit') { messages(events).count { |e| e['method'] == 'textDocument/didChange' } > changes }
    offset = output.size
    command(writer, 'quit')
    await('first quit decision') { terminal_text(output[offset..]).include?('Discard') }
    writer.write("\e[Z\e[13u") # Cancel -> Discard, then confirm first file.
    sleep 0.25
    writer.write("\e[27u") # Cancel the remaining file.
    sleep 0.2
    raise 'partial quit closed tabs' if messages(events).any? { |e| e['method'] == 'textDocument/didClose' }
    raise 'partial quit wrote disk' unless File.read(first) == "first\n" && File.read(second) == "second\n"

    # Both buffers must still be alive. Save/close active second, then discard first.
    offset = output.size
    command(writer, 'close')
    await('second close decision') { terminal_text(output[offset..]).include?('Discard') }
    writer.write("\e[9u\e[13u") # Cancel -> Save.
    await('second saved and closed') do
      File.read(second) == "Ysecond\n" && messages(events).count { |e| e['method'] == 'textDocument/didClose' } == 1
    end
    offset = output.size
    command(writer, 'close')
    await('first close decision') { terminal_text(output[offset..]).include?('Discard') }
    writer.write("\e[Z\e[13u")
    await('first discarded') { messages(events).count { |e| e['method'] == 'textDocument/didClose' } == 2 }
    raise 'discard wrote source' unless File.read(first) == "first\n"
    command(writer, 'quit')
    await('clean exit') { Process.waitpid(pid, Process::WNOHANG) }
    drain.join(1)
    puts JSON.generate(result: 'PASS', cancel_default: true, modal_isolation: true,
                       partial_quit_cancel: true, save_close: true, discard_close: true, root: root)
  ensure
    File.write(File.join(root, 'terminal.txt'), terminal_text(output))
    warn root
    begin
      Process.kill('TERM', pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end
    drain.join(1)
  end
end
