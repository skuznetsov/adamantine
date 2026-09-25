require 'pty'
require 'io/console'
require 'tmpdir'
require 'json'

# Real input/dispatch oracle, isolated from user files and configuration.
root = Dir.mktmpdir('adamantine-palette-')
source = File.join(root, 'source.cr')
middle_edit_source = File.join(root, 'middle-edit.cr')
config = File.join(root, 'config.json')
events = File.join(root, 'events.jsonl')
original = "puts( 1 )\n"
File.write(source, original)
File.write(middle_edit_source, "puts :middle\n")
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

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def type(writer, text)
  text.each_codepoint { |codepoint| key(writer, "\e[#{codepoint}u") }
end

def palette(writer, query = '')
  key(writer, "\eOP") # Actual F1, not a call to the internal controller.
  sleep 0.15
  type(writer, query)
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
  reader.winsize = [26, 120]
  drain = Thread.new do
    begin
      loop { output << reader.readpartial(65_536) }
    rescue EOFError, Errno::EIO
    end
  end
  begin
    await('connection') { !messages(events, 'initialized').empty? }
    palette(writer, 'open file path')
    key(writer, "\e[13u")
    sleep 0.2
    raise 'argument action ran before receiving a path' unless messages(events, 'textDocument/didOpen').empty?
    key(writer, "\e[13u") # Empty prepared argument must stay editable.
    sleep 0.15
    type(writer, source)
    key(writer, "\e[13u")
    await('discovered Open File accepts its argument') { messages(events, 'textDocument/didOpen').size == 1 }

    # Legacy Tab completion must prepare arguments without leaking Enter/text.
    palette(writer, ':op')
    key(writer, "\e[9u\e[13u")
    sleep 0.15
    type(writer, source)
    key(writer, "\e[13u")
    sleep 0.2
    raise 'raw completion leaked text into the editor' unless messages(events, 'textDocument/didChange').empty?

    offset = output.bytesize
    palette(writer, 'open settings')
    key(writer, "\e[13u")
    await('phrase opens Settings, not a file named settings') do
      rendered_since(output, offset).include?('Enter to apply')
    end
    key(writer, "\e[27u")
    sleep 0.2

    palette(writer, 'formatting')
    key(writer, "\e[13u")
    await('description search dispatches Format') { messages(events, 'textDocument/formatting').size == 1 }
    sleep 0.2
    key(writer, "\e[27u")
    sleep 0.2
    raise 'preview changed source' unless messages(events, 'textDocument/didChange').empty? && File.read(source) == original

    # No-result Enter and paste may not escape the palette into the buffer.
    palette(writer, 'zzzz_no_such_action')
    key(writer, "\e[13u\e[200~UNWANTED\e[201~")
    sleep 0.2
    raise 'no-result action leaked editing' unless messages(events, 'textDocument/didChange').empty?
    key(writer, "\e[27u")
    sleep 0.2
    key(writer, "\e[88u")
    await('editing resumes after palette cancel') { !messages(events, 'textDocument/didChange').empty? }
    edited = messages(events, 'textDocument/didChange').last.dig('params', 'contentChanges', 0, 'text')
    raise 'test edit is missing' unless edited != original && !edited.include?('UNWANTED')

    # Empty query defaults to Help; Down selects Save. Disk bytes are the oracle.
    palette(writer)
    key(writer, "\e[B\e[13u")
    await('Down/Enter dispatches selected Save action') { File.read(source) == edited }
    raise 'search phrase opened an unintended file' unless messages(events, 'textDocument/didOpen').size == 1

    # A real terminal left-arrow edit repairs :opn to :open. The prepared
    # argument then arrives as bracketed paste and must stay inside the modal.
    palette(writer, ':opn')
    key(writer, "\e[D")
    type(writer, 'e')
    key(writer, "\e[9u")
    key(writer, "\e[200~#{middle_edit_source}\e[201~")
    key(writer, "\e[13u")
    await('middle edit and bracketed paste open the requested file') do
      messages(events, 'textDocument/didOpen').size == 2
    end
    raise 'modal middle edit or paste changed the first document on disk' unless File.read(source) == edited

    palette(writer, ':q!') # Explicit command mode only, for fixture cleanup.
    key(writer, "\e[13u")
    await('exit') { Process.waitpid(pid, Process::WNOHANG) }
    puts JSON.generate(result: 'PASS', argument_preparation: true, editable_input: true,
                       bracketed_paste: true, phrase_search: true,
                       description_dispatch: true, no_result_isolation: true,
                       selection_save: true, root: root)
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
