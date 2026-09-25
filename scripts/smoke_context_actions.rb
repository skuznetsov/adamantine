require 'pty'
require 'io/console'
require 'tmpdir'
require 'json'

root = Dir.mktmpdir('adamantine-context-actions-')
source = File.join(root, 'source.cr')
config = File.join(root, 'config.json')
events = File.join(root, 'events.jsonl')
original = "puts( 1 )\n"
File.write(source, original)
File.write(config, '{}')
fixture = File.expand_path('../spec/fixtures/formatting_probe_server.rb', __dir__)
output = +''

def await(label)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until yield
    raise "timeout: #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.02
  end
end

def messages(path, method)
  return [] unless File.exist?(path)
  File.readlines(path).map { |line| JSON.parse(line) rescue nil }.compact
      .select { |event| event['method'] == method }
end

def key(writer, text)
  writer.write(text)
  writer.flush
end

def type(writer, text)
  text.each_codepoint { |cp| key(writer, "\e[#{cp}u") }
end

def rendered_since(output, offset)
  (output.byteslice(offset..) || '').scrub
      .gsub(/\e\][^\a]*(?:\a|\e\\)/, '')
      .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '')
end

env = {'TERM' => 'xterm-256color', 'ADAMANTINE_SESSION' => '0',
       'ADAMANTINE_RECOVERY' => '0', 'ADAMANTINE_STATE_HOME' => File.join(root, 'state')}
PTY.spawn(env, ARGV.fetch(0), root, '--config', config,
          '--lsp', '/usr/bin/ruby', '--lsp-arg', fixture, '--lsp-arg', events) do |reader, writer, pid|
  reader.winsize = [16, 120] # Deliberately shorter than the whole action list.
  drain = Thread.new do
    begin
      loop { output << reader.readpartial(65_536) }
    rescue EOFError, Errno::EIO
    end
  end
  begin
    await('connection') { !messages(events, 'initialized').empty? }
    key(writer, "\eOP")
    sleep 0.15
    type(writer, ":open #{source}")
    key(writer, "\e[13u")
    await('open source') { messages(events, 'textDocument/didOpen').size == 1 }

    offset = output.bytesize
    key(writer, "\e[13;2u") # Shift+Enter: Quick Actions.
    sleep 0.2
    key(writer, "\e[F") # End: Review external changes (unavailable).
    await('disabled selected row explains missing external conflict') do
      text = rendered_since(output, offset)
      text.include?('Review external changes') && text.match?(/No external (changes|conflict)/)
    end
    key(writer, "\e[109;6u") # Problems must not replace an open menu.
    key(writer, "\e[13u\e[200~UNWANTED\e[201~\e[90u")
    sleep 0.25
    raise 'disabled menu leaked editing' unless messages(events, 'textDocument/didChange').empty?
    raise 'disabled menu wrote disk' unless File.read(source) == original

    offset = output.bytesize
    key(writer, "\e[49u") # Stable first action: Find in file.
    await('enabled numbered action opens Find') do
      rendered_since(output, offset).include?('Enter next')
    end
    key(writer, "\e[27u")
    sleep 0.2

    # Format from the shared menu must request an inline proposal, not save.
    offset = output.bytesize
    key(writer, "\e[13;2u")
    sleep 0.15
    key(writer, "\e[F\e[A\e[A\e[A\e[13u")
    await('shared Format dispatch') { messages(events, 'textDocument/formatting').size == 1 }
    await('inline proposal is visible before cancel') do
      text = rendered_since(output, offset)
      text.include?('selected 1/1') && text.include?('Apply') && text.include?('Reject') && text.include?('puts(1)')
    end
    key(writer, "\e[27u")
    sleep 0.15
    raise 'format preview mutated text' unless messages(events, 'textDocument/didChange').empty?

    key(writer, "\e[13;2u")
    sleep 0.15
    key(writer, "\e[27u")
    sleep 0.15
    key(writer, "\e[88u")
    await('editing resumes after explicit cancel') { !messages(events, 'textDocument/didChange').empty? }
    edited = messages(events, 'textDocument/didChange').last.dig('params', 'contentChanges', 0, 'text')
    raise 'text includes leaked input' if edited.include?('UNWANTED') || edited.include?('Z')
    raise 'no edit after cancel' unless edited != original
    raise 'workflow saved without consent' unless File.read(source) == original

    key(writer, "\eOP")
    sleep 0.15
    type(writer, ':q!')
    key(writer, "\e[13u")
    await('exit') { Process.waitpid(pid, Process::WNOHANG) }
    puts JSON.generate(result: 'PASS', disabled_reason: true, modal_isolation: true,
                       selected_row_scroll: true, numbered_find: true,
                       format_preview_cancel: true, disk_unchanged: true, root: root)
  ensure
    File.write(File.join(root, 'terminal.txt'), output)
    warn root
    begin
      Process.kill('TERM', pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end
    drain.join(1)
  end
end
