require 'pty'
require 'io/console'
require 'tmpdir'
require 'json'
require 'digest'

root = Dir.mktmpdir('adamantine-format-git-')
source = File.join(root, 'source.cr')
config = File.join(root, 'config.json')
events = File.join(root, 'events.jsonl')
File.write(source, "puts( 1 )\n")
File.write(config, '{}')
system('git', 'init', '--quiet', root) || raise('git init failed')
system('git', '-C', root, 'add', '--', 'source.cr') || raise('git add failed')
system('git', '-C', root, '-c', 'user.name=Smoke', '-c', 'user.email=smoke@example.invalid', 'commit', '--quiet', '-m', 'Smoke history record') || raise('git commit failed')
before = Digest::SHA256.file(source).hexdigest
fixture = File.expand_path('../spec/fixtures/formatting_probe_server.rb', __dir__)
binary = ARGV.fetch(0, '/private/tmp/adamantine-format-editor')
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
def terminal_text(output)
  output.gsub(/\e\[[0-9;?<>]*[A-Za-z]/, '')
end
def command(writer, text)
  writer.write("\e[112;6u")
  sleep 0.15
  text.each_codepoint { |codepoint| writer.write("\e[#{codepoint}u") }
  writer.write("\e[13u")
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
    await('connection') { messages(events).any? { |e| e['method'] == 'initialized' } }
    sleep 0.3
    command(writer, "open #{source}")
    await('didOpen') { messages(events).any? { |e| e['method'] == 'textDocument/didOpen' } }
    command(writer, 'format')
    await('format response') { messages(events).any? { |e| e['method'] == 'textDocument/formatting' } }
    await('inline format controls') { terminal_text(output).include?('Accept all') && terminal_text(output).include?('Reject') }
    await('inline formatted text') { terminal_text(output).include?('puts(1)') }
    writer.write("\e[27u")
    sleep 0.2
    raise 'cancel mutated document' if messages(events).any? { |e| e['method'] == 'textDocument/didChange' }
    command(writer, 'format')
    await('second format') { messages(events).count { |e| e['method'] == 'textDocument/formatting' } == 2 }
    sleep 0.3
    writer.write("\e[13u")
    await('apply') { messages(events).any? { |e| e['method'] == 'textDocument/didChange' && e.dig('params', 'contentChanges', 0, 'text') == "puts(1)\n" } }
    command(writer, 'undo')
    await('undo') { messages(events).any? { |e| e['method'] == 'textDocument/didChange' && e.dig('params', 'contentChanges', 0, 'text') == "puts( 1 )\n" } }
    command(writer, 'git')
    await('git rendered') { terminal_text(output).include?('disk state') }
    sleep 0.4
    writer.write("\e[108u")
    await('history rendered') { terminal_text(output).include?('Smoke history record') }
    writer.write("\e[13u")
    await('commit diff rendered') { terminal_text(output).include?('+++ b/source.cr') }
    writer.write("\e[27u")
    sleep 0.1
    writer.write("\e[27u")
    sleep 0.2
    command(writer, 'q!')
    await('exit') { Process.waitpid(pid, Process::WNOHANG) }
    drain.join(1)
    raise 'source saved unexpectedly' unless before == Digest::SHA256.file(source).hexdigest
    puts JSON.generate(result: 'PASS', inline_proposal_visible: true, preview_cancel: true, apply_undo: true, git_modal_history_diff: true, disk_unchanged: true, root: root)
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
