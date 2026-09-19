# Real-terminal contract check for the bounded refactoring workflow.
require 'pty'
require 'io/console'
require 'tmpdir'
require 'json'
require 'digest'

root = Dir.mktmpdir('adamantine-refactor-')
source = File.join(root, 'source.cr')
config = File.join(root, 'config.json')
events = File.join(root, 'events.jsonl')
File.write(source, "old = old\n")
File.write(config, '{}')
before = Digest::SHA256.file(source).hexdigest
fixture = File.expand_path('../spec/fixtures/refactor_probe_server.rb', __dir__)
binary = ARGV.fetch(0, '/private/tmp/adamantine-refactor-editor')
env = {'TERM' => 'xterm-256color', 'ADAMANTINE_SESSION' => '0', 'ADAMANTINE_RECOVERY' => '0'}
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

def command(writer, text)
  writer.write("\e[112;6u")
  sleep 0.15
  text.each_codepoint { |codepoint| writer.write("\e[#{codepoint}u") }
  writer.write("\e[13u")
end

def changes(path)
  messages(path).select { |event| event['method'] == 'textDocument/didChange' }
end

PTY.spawn(env, binary, root, '--config', config,
          '--lsp', '/usr/bin/ruby', '--lsp-arg', fixture, '--lsp-arg', events) do |reader, writer, pid|
  reader.winsize = [30, 120]
  drain = Thread.new do
    begin
      loop { output << reader.readpartial(65536) }
    rescue EOFError, Errno::EIO
    end
  end
  begin
    await('connection') { messages(events).any? { |event| event['method'] == 'initialized' } }
    sleep 0.3
    command(writer, "open #{source}")
    await('didOpen') { messages(events).any? { |event| event['method'] == 'textDocument/didOpen' } }
    command(writer, 'rename fresh')
    await('rename response') { messages(events).any? { |event| event['method'] == 'textDocument/rename' } }
    sleep 0.3
    writer.write("\e[27u")
    sleep 0.2
    raise 'rename cancel changed document' unless changes(events).empty?
    command(writer, 'rename fresh')
    await('second rename') { messages(events).count { |event| event['method'] == 'textDocument/rename' } == 2 }
    sleep 0.3
    writer.write("\e[13u")
    await('rename apply') { changes(events).last&.dig('params', 'contentChanges', 0, 'text') == "fresh = fresh\n" }
    command(writer, 'undo')
    await('rename undo') { changes(events).last&.dig('params', 'contentChanges', 0, 'text') == "old = old\n" }
    count = changes(events).length
    command(writer, 'rename foreign')
    await('foreign rename') { messages(events).count { |event| event['method'] == 'textDocument/rename' } == 3 }
    sleep 0.4
    raise 'foreign rename partly applied' unless changes(events).length == count
    writer.write("\e[27u")
    command(writer, 'quickfix')
    await('quickfix response') { messages(events).any? { |event| event['method'] == 'textDocument/codeAction' } }
    sleep 0.3
    writer.write("\e[13u")
    sleep 0.3
    raise 'picker selection applied without preview' unless changes(events).length == count
    writer.write("\e[9u")
    sleep 0.2
    raise 'Tab applied preview' unless changes(events).length == count
    writer.write("\e[27u")
    sleep 0.2
    raise 'quickfix cancel changed document' unless changes(events).length == count
    command(writer, 'quickfix')
    await('second quickfix') { messages(events).count { |event| event['method'] == 'textDocument/codeAction' } == 2 }
    sleep 0.3
    writer.write("\e[13u")
    sleep 0.3
    writer.write("\e[13u")
    await('quickfix apply') { changes(events).last&.dig('params', 'contentChanges', 0, 'text') == "safe = safe\n" }
    command(writer, 'undo')
    await('quickfix undo') { changes(events).last&.dig('params', 'contentChanges', 0, 'text') == "old = old\n" }
    command(writer, 'q!')
    await('exit') { Process.waitpid(pid, Process::WNOHANG) }
    drain.join(1)
    raise 'source saved unexpectedly' unless before == Digest::SHA256.file(source).hexdigest
    raise 'server command executed' if messages(events).any? { |event| event['method'] == 'workspace/executeCommand' }
    puts JSON.generate(result: 'PASS', rename_cancel_apply_undo: true, mixed_file_rejected: true,
                       quickfix_picker_preview_cancel_apply_undo: true, tab_does_not_apply: true,
                       disk_unchanged: true, root: root)
  ensure
    File.write(File.join(root, 'terminal.txt'), output.gsub(/\e\[[0-9;?<>]*[A-Za-z]/, ''))
    warn root
    begin
      Process.kill('TERM', pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end
    drain.join(1)
  end
end
