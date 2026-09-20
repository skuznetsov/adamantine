require 'pty'
require 'io/console'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'uri'

# Real-terminal gate for server-reported workspace Problems. Everything lives
# under a temporary project; the user's files and configuration are untouched.
root = Dir.mktmpdir('adamantine-workspace-problems-')
active = File.join(root, 'active.cr')
target = File.join(root, 'target.cr')
config = File.join(root, 'config.json')
events = File.join(root, 'events.jsonl')
active_text = "ACTIVE_BUFFER\n"
target_text = "🙂x\n"
File.write(active, active_text)
File.write(target, target_text)
File.write(config, '{}')

fixture = File.expand_path('../spec/fixtures/workspace_problems_probe_server.rb', __dir__)
target_uri = "file://#{URI::DEFAULT_PARSER.escape(File.expand_path(target))}"
binary = ARGV.fetch(0)
output = +''

def await(label, timeout: 10)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    raise "timeout: #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.02
  end
end

def messages(path)
  return [] unless File.exist?(path)

  File.readlines(path).map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end.compact
end

def event_count(path, method)
  messages(path).count { |event| event['method'] == method }
end

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def type(writer, text)
  text.each_codepoint { |codepoint| key(writer, "\e[#{codepoint}u") }
end

def command(writer, text)
  key(writer, "\e[112;6u")
  sleep 0.15
  type(writer, ":#{text}")
  key(writer, "\e[13u")
end

def terminal_text(output)
  output
    .scrub
    .gsub(/\e\][^\a]*(?:\a|\e\\)/, '')
    .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '')
    .gsub("\r", '')
end

def output_since(output, offset)
  (output.byteslice(offset..) || '').scrub
end

env = {
  'TERM' => 'xterm-256color',
  'ADAMANTINE_SESSION' => '0',
  'ADAMANTINE_RECOVERY' => '0',
  'ADAMANTINE_STATE_HOME' => File.join(root, 'state'),
  'XDG_STATE_HOME' => File.join(root, 'state'),
}

PTY.spawn(env, binary, root, '--config', config,
          '--lsp', '/usr/bin/ruby', '--lsp-arg', fixture,
          '--lsp-arg', events, '--lsp-arg', target_uri) do |reader, writer, pid|
  reader.winsize = [26, 120]
  drain = Thread.new do
    begin
      loop { output << reader.readpartial(65_536) }
    rescue EOFError, Errno::EIO
    end
  end

  begin
    await('connection') do
      messages(events).any? { |event| event['method'] == 'initialized' }
    end

    command(writer, "e #{active}")
    await('active open') { event_count(events, 'textDocument/didOpen') == 1 }

    active_before = File.binread(active)
    target_before = File.binread(target)
    modal_offset = output.bytesize
    key(writer, "\e[109;6u") # Ctrl+Shift+M
    await('workspace Problems row') do
      rendered = terminal_text(output_since(output, modal_offset))
      rendered.include?('Problems: Server Workspace') &&
        rendered.include?('target.cr') &&
        rendered.include?('unopened-workspace-diagnostic')
    end
    await('workspace request') { event_count(events, 'workspace/diagnostic') == 1 }
    raise 'workspace target opened before Enter' unless event_count(events, 'textDocument/didOpen') == 1

    changes_before_modal = event_count(events, 'textDocument/didChange')
    key(writer, "\e[200~UNWANTED_MODAL_INPUT\e[201~")
    sleep 0.2
    raise 'Problems paste emitted didChange' unless event_count(events, 'textDocument/didChange') == changes_before_modal
    raise 'Problems paste changed disk' unless File.binread(active) == active_before && File.binread(target) == target_before

    key(writer, "\e[13u")
    await('workspace target opens on Enter') { event_count(events, 'textDocument/didOpen') == 2 }
    raise 'Problems selection emitted didChange' unless event_count(events, 'textDocument/didChange') == changes_before_modal

    # Insert after the emoji. A full-sync didChange of "🙂Xx\n" proves that
    # LSP UTF-16 column 2 was converted to editor codepoint column 1.
    key(writer, "\e[88u")
    await('post-navigation edit') { event_count(events, 'textDocument/didChange') == changes_before_modal + 1 }
    change = messages(events).reverse.find { |event| event['method'] == 'textDocument/didChange' }
    uri = change&.dig('params', 'textDocument', 'uri')
    text = change&.dig('params', 'contentChanges', 0, 'text')
    raise "post-navigation edit targeted #{uri.inspect}" unless uri == target_uri
    raise "UTF-16 cursor resolved to unexpected text #{text.inspect}" unless text == "🙂Xx\n"
    raise 'post-navigation probe changed disk' unless File.binread(active) == active_before && File.binread(target) == target_before

    command(writer, 'q!')
    await('exit') { Process.waitpid(pid, Process::WNOHANG) }
    drain.join(1)
    puts JSON.generate(result: 'PASS', server_workspace_row: true,
                       unopened_until_enter: true, modal_input_isolated: true,
                       utf16_navigation: true, disk_unchanged: true, root: root)
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
