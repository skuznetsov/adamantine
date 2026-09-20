require 'pty'
require 'io/console'
require 'tmpdir'
require 'json'
require 'fileutils'

# Real-terminal gate for the aggregate open-files Problems modal.  Everything
# lives under a temporary project; the user's files and configuration are not
# touched.
root = Dir.mktmpdir('adamantine-problems-')
first = File.join(root, 'one', 'source.cr')
second = File.join(root, 'two', 'source.cr')
config = File.join(root, 'config.json')
events = File.join(root, 'events.jsonl')
FileUtils.mkdir_p(File.dirname(first))
FileUtils.mkdir_p(File.dirname(second))
first_text = "FIRST_FILE_BUFFER\n"
second_text = "SECOND_FILE_BUFFER\n"
File.write(first, first_text)
File.write(second, second_text)
File.write(config, '{}')

fixture = File.expand_path('../spec/fixtures/problems_probe_server.rb', __dir__)
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

def published_count(path)
  messages(path).count { |event| event['event'] == 'publishedDiagnostics' }
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
          '--lsp', '/usr/bin/ruby', '--lsp-arg', fixture, '--lsp-arg', events) do |reader, writer, pid|
  reader.winsize = [26, 120]
  drain = Thread.new do
    begin
      loop { output << reader.readpartial(65_536) }
    rescue EOFError, Errno::EIO
    end
  end

  begin
    await('connection') { !messages(events).empty? && messages(events).any? { |event| event['method'] == 'initialized' } }

    command(writer, "e #{first}")
    await('first open') { event_count(events, 'textDocument/didOpen') == 1 }
    await('first diagnostics') { published_count(events) == 1 }

    command(writer, "e #{second}")
    await('second open') { event_count(events, 'textDocument/didOpen') == 2 }
    await('second diagnostics') { published_count(events) == 2 }

    active_offset = output.bytesize
    command(writer, 'buf 2')
    await('second file is active before Problems') do
      terminal_text(output_since(output, active_offset)).include?(second_text.strip)
    end

    changes_before_modal = event_count(events, 'textDocument/didChange')
    first_before = File.binread(first)
    second_before = File.binread(second)
    modal_offset = output.bytesize
    key(writer, "\e[109;6u") # Ctrl+Shift+M
    await('aggregate Problems rows') do
      rendered = terminal_text(output_since(output, modal_offset))
      rendered.include?('Problems: Open Files') &&
        rendered.include?('one/source.cr') &&
        rendered.include?('two/source.cr')
    end

    # Problems owns paste/key input until an explicit selection or cancel.
    key(writer, "\e[200~UNWANTED_MODAL_INPUT\e[201~")
    sleep 0.2
    raise 'Problems paste emitted didChange' unless event_count(events, 'textDocument/didChange') == changes_before_modal
    raise 'Problems paste changed disk' unless File.binread(first) == first_before && File.binread(second) == second_before

    key(writer, "\e[13u") # Default first row is one/source.cr, currently inactive.
    sleep 0.25
    raise 'Problems selection emitted didChange' unless event_count(events, 'textDocument/didChange') == changes_before_modal
    raise 'Problems selection changed disk' unless File.binread(first) == first_before && File.binread(second) == second_before

    # A deliberate edit after Enter is the strongest deterministic PTY signal
    # that the inactive target became active. It is never saved, and remains
    # separate from the zero-change modal/selection assertions above.
    key(writer, "\e[88u")
    await('edit is routed to the selected inactive file') do
      event_count(events, 'textDocument/didChange') == changes_before_modal + 1
    end
    change = messages(events).reverse.find { |event| event['method'] == 'textDocument/didChange' }
    uri = change&.dig('params', 'textDocument', 'uri')
    raise "post-navigation edit targeted #{uri.inspect}" unless uri&.end_with?('/one/source.cr')
    raise 'post-navigation probe changed disk' unless File.binread(first) == first_before && File.binread(second) == second_before

    command(writer, 'q!')
    await('exit') { Process.waitpid(pid, Process::WNOHANG) }
    drain.join(1)
    puts JSON.generate(result: 'PASS', open_files_rows: true, relative_paths: true,
                       inactive_navigation: true, modal_input_isolated: true,
                       selection_no_did_change: true, navigation_uri_probe: true,
                       disk_unchanged: true, root: root)
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
