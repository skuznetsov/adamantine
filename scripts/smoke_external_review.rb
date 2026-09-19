require 'pty'
require 'io/console'
require 'tmpdir'
require 'json'

# Real terminal gate: run against a built editor, never the user's files.
root = Dir.mktmpdir('adamantine-external-review-')
source = File.join(root, 'source.cr')
config = File.join(root, 'config.json')
events = File.join(root, 'events.jsonl')
state = File.join(root, 'state')

editor_text = (0...24).map { |index| "editor-line-#{index}\n" }.join
disk_one = (0...24).map { |index| "disk-one-line-#{index}\n" }.join
disk_two = (0...24).map { |index| "disk-two-line-#{index}\n" }.join
disk_three = (0...24).map { |index| "disk-three-line-#{index}\n" }.join
disk_four = (0...24).map { |index| "disk-four-line-#{index}\n" }.join

File.write(source, editor_text)
File.write(config, '{}')
fixture = File.expand_path('../spec/fixtures/formatting_probe_server.rb', __dir__)
binary = ARGV.fetch(0)
output = +''

def await(label, timeout: 12)
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

def latest_change_text(path)
  messages(path).reverse_each do |event|
    next unless event['method'] == 'textDocument/didChange'
    text = event.dig('params', 'contentChanges', 0, 'text')
    return text if text.is_a?(String)
  end
  nil
end

def terminal_text(output)
  # Strip CSI/OSC terminal controls while retaining rendered punctuation and
  # line breaks. The extra carriage-return cleanup makes full-screen redraws
  # searchable without pretending they are a linear transcript.
  output
    .gsub(/\e\][^\a]*(?:\a|\e\\)/, '')
    .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '')
    .gsub("\r", '')
end

def output_since(output, offset)
  # `bytesize` snapshots are byte offsets. Ruby's String#[] interprets an
  # integer offset in characters for UTF-8 output, which can skip fresh PTY
  # data after a non-ASCII status/redraw sequence. Keep the snapshot and the
  # slice in the same coordinate system, then repair a split codepoint.
  (output.byteslice(offset..) || '').scrub
end

def command(writer, text)
  writer.write("\e[112;6u")
  sleep 0.15
  text.each_codepoint { |codepoint| writer.write("\e[#{codepoint}u") }
  writer.write("\e[13u")
  writer.flush
end

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def review_editor_visible?(text, editor_marker)
  text.include?('- Editor') && text.include?('+ Disk') && text.include?(editor_marker)
end

def review_disk_visible?(text, disk_marker)
  text.include?('+ Disk') && text.include?(disk_marker)
end

env = {
  'TERM' => 'xterm-256color',
  'ADAMANTINE_STATE_HOME' => state,
  'XDG_STATE_HOME' => state,
  'ADAMANTINE_SESSION' => '0',
  'ADAMANTINE_RECOVERY' => '0',
}

PTY.spawn(env, binary, root, '--config', config,
          '--lsp', '/usr/bin/ruby', '--lsp-arg', fixture, '--lsp-arg', events) do |reader, writer, pid|
  reader.winsize = [18, 140]
  drain = Thread.new do
    begin
      loop { output << reader.readpartial(65_536) }
    rescue EOFError, Errno::EIO
    end
  end

  begin
    await('connection') { messages(events).any? { |event| event['method'] == 'initialized' } }

    command(writer, "open #{source}")
    await('source open') { event_count(events, 'textDocument/didOpen') == 1 }

    # An existing popup must survive a background disk observation. The
    # editor should expose only a discoverable external/review notice until an
    # explicit review request, while the popup keeps ownership of input.
    popup_offset = output.bytesize
    command(writer, 'settings')
    await('settings popup') { terminal_text(output_since(output, popup_offset)).include?('Settings') }
    File.write(source, disk_one)
    await('external notice beside popup') do
      rendered = terminal_text(output_since(output, popup_offset))
      lowered = rendered.downcase
      rendered.include?('Settings') && lowered.include?('external') && lowered.include?('review')
    end
    rendered = terminal_text(output_since(output, popup_offset))
    raise 'external event replaced an existing popup' unless rendered.include?('Settings')

    changes_before_edit = event_count(events, 'textDocument/didChange')
    key(writer, "\e[27u") # Escape closes Settings, not the active editor.
    sleep 0.2
    key(writer, "\e[88u") # X: keep typing while the disk conflict is unresolved.
    await('edit while conflict is unresolved') do
      event_count(events, 'textDocument/didChange') > changes_before_edit
    end
    unresolved_text = latest_change_text(events).to_s
    raise 'external observation reloaded the editor' if unresolved_text.include?('disk-one-line-0')
    raise 'unresolved edit did not reach LSP' unless unresolved_text.include?('editor-line-0')
    raise 'external observation wrote the disk' unless File.read(source) == disk_one

    # Explicit command opens the disk-vs-editor review. Arrows and bracketed
    # paste stay inside the hard modal and cannot mutate the live document.
    review_offset = output.bytesize
    command(writer, 'external')
    await('external review') do
      rendered = terminal_text(output_since(output, review_offset))
      review_editor_visible?(rendered, 'editor-line-0')
    end

    review_changes = event_count(events, 'textDocument/didChange')
    24.times { key(writer, "\e[B") } # Down: reach the first added disk row.
    await('external review disk rows') do
      review_disk_visible?(terminal_text(output_since(output, review_offset)), 'disk-one-line-0')
    end
    review_text = terminal_text(output_since(output, review_offset))
    raise 'review did not label editor rows' unless review_text.include?('- Editor')
    raise 'review did not label disk rows' unless review_text.include?('+ Disk')
    key(writer, "\e[200~PASTE_SHOULD_BE_IGNORED\e[201~")
    sleep 0.25
    raise 'review navigation or paste leaked into the editor' unless event_count(events, 'textDocument/didChange') == review_changes
    raise 'review interaction changed the disk' unless File.read(source) == disk_one

    key(writer, "\e[13u") # Default Enter means Later.
    sleep 0.25
    raise 'default review action mutated the disk' unless File.read(source) == disk_one
    raise 'default review action changed the document' unless event_count(events, 'textDocument/didChange') == review_changes

    # Tab cycles Later -> Reload -> Overwrite -> Later.  The wraparound must
    # be non-mutating when Enter confirms the returned Later choice.
    reopened_offset = output.bytesize
    command(writer, 'external')
    await('reopened review') do
      review_editor_visible?(terminal_text(output_since(output, reopened_offset)), 'editor-line-0')
    end
    3.times { key(writer, "\e[9u") }
    key(writer, "\e[13u")
    sleep 0.25
    raise 'wrapped Later review action mutated the disk' unless File.read(source) == disk_one
    raise 'wrapped Later review action changed the document' unless event_count(events, 'textDocument/didChange') == review_changes

    # Escape is the same non-mutating Later action, and the review remains
    # explicitly reopenable while the conflict remains unresolved.
    escape_review_offset = output.bytesize
    command(writer, 'external')
    await('escape review') do
      review_editor_visible?(terminal_text(output_since(output, escape_review_offset)), 'editor-line-0')
    end
    key(writer, "\e[27u")
    sleep 0.25
    raise 'Escape review action mutated the disk' unless File.read(source) == disk_one
    raise 'Escape review action changed the document' unless event_count(events, 'textDocument/didChange') == review_changes

    # Later -> Reload from disk -> Enter. Reload must be the one undoable
    # replacement, and the original editor text must remain available through
    # the normal Undo path.
    reload_review_offset = output.bytesize
    command(writer, 'external')
    await('reload review') do
      review_editor_visible?(terminal_text(output_since(output, reload_review_offset)), 'editor-line-0')
    end
    24.times { key(writer, "\e[B") }
    await('reload review disk rows') do
      review_disk_visible?(terminal_text(output_since(output, reload_review_offset)), 'disk-one-line-0')
    end
    key(writer, "\e[9u") # Tab selects Reload from disk.
    reload_changes = event_count(events, 'textDocument/didChange')
    key(writer, "\e[13u")
    await('reload applied') do
      event_count(events, 'textDocument/didChange') > reload_changes &&
        latest_change_text(events).to_s.include?('disk-one-line-0')
    end
    raise 'reload changed the disk' unless File.read(source) == disk_one

    undo_changes = event_count(events, 'textDocument/didChange')
    command(writer, 'undo')
    await('reload undo') do
      event_count(events, 'textDocument/didChange') > undo_changes &&
        latest_change_text(events).to_s.include?('editor-line-0') &&
        !latest_change_text(events).to_s.include?('disk-one-line-0')
    end
    raise 'undo did not restore the pre-reload editor text' unless latest_change_text(events).to_s.include?('editor-line-0')
    raise 'undo unexpectedly wrote the disk' unless File.read(source) == disk_one

    # A known conflict reached through Ctrl+S must open the same review. Two
    # Tabs choose Overwrite disk; the save target is the current editor text.
    second_external_offset = output.bytesize
    File.write(source, disk_two)
    await('second external observation') do
      lowered = terminal_text(output_since(output, second_external_offset)).downcase
      lowered.include?('external') && lowered.include?('review')
    end
    before_second_edit = event_count(events, 'textDocument/didChange')
    key(writer, "\e[89u") # Y: dirty the editor after the reload undo.
    await('second editor edit') { event_count(events, 'textDocument/didChange') > before_second_edit }
    expected_overwrite = latest_change_text(events)
    raise 'could not capture the editor text for overwrite' if expected_overwrite.nil? || expected_overwrite.empty?

    save_review_offset = output.bytesize
    key(writer, "\e[115;5u") # Ctrl+S on a known conflict.
    await('save conflict review') do
      review_editor_visible?(terminal_text(output_since(output, save_review_offset)), 'editor-line-0')
    end
    24.times { key(writer, "\e[B") }
    await('save conflict review disk rows') do
      review_disk_visible?(terminal_text(output_since(output, save_review_offset)), 'disk-two-line-0')
    end
    2.times { key(writer, "\e[9u") } # Later -> Reload -> Overwrite.
    key(writer, "\e[13u")
    await('overwrite applied') { File.read(source) == expected_overwrite }
    raise 'overwrite did not use the reviewed editor bytes' unless File.read(source) == expected_overwrite

    # Reopen the conflict, select Overwrite, then replace the disk candidate
    # before Enter. Acceptance must re-read the candidate and reject the stale
    # action without writing the newer disk revision.
    stale_edit_changes = event_count(events, 'textDocument/didChange')
    key(writer, "\e[90u") # Z: make the current editor dirty again.
    await('stale scenario editor edit') { event_count(events, 'textDocument/didChange') > stale_edit_changes }

    stale_notice_offset = output.bytesize
    File.write(source, disk_three)
    await('third external observation') do
      lowered = terminal_text(output_since(output, stale_notice_offset)).downcase
      lowered.include?('external') && lowered.include?('review')
    end

    stale_review_offset = output.bytesize
    command(writer, 'external')
    await('stale review') do
      review_editor_visible?(terminal_text(output_since(output, stale_review_offset)), 'editor-line-0')
    end
    24.times { key(writer, "\e[B") }
    await('stale review disk rows') do
      review_disk_visible?(terminal_text(output_since(output, stale_review_offset)), 'disk-three-line-0')
    end
    stale_choice_offset = output.bytesize
    2.times do
      key(writer, "\e[9u")
      sleep 0.12
    end
    await('stale overwrite selection') do
      terminal_text(output_since(output, stale_choice_offset)).include?('Overwrite]')
    end
    rejection_changes = event_count(events, 'textDocument/didChange')
    File.write(source, disk_four)
    key(writer, "\e[13u")
    # The final warning is a useful diagnostic, but full-screen redraws can
    # split or overpaint its words in a PTY transcript. Prove the action was
    # processed through the stronger observable boundary: after Enter, a
    # subsequent editor key must produce a didChange containing the still-live
    # editor text, while the newer disk bytes remain untouched.
    await('stale overwrite rejection') do
      raise 'stale overwrite wrote over the newer disk revision' unless File.read(source) == disk_four
      if event_count(events, 'textDocument/didChange') == rejection_changes
        # A key delivered during the yielding guarded read is intentionally
        # consumed by the modal. Retry only this harmless fixture edit until
        # the closed review releases input; do not infer closure from old text.
        key(writer, "\e[81u")
        sleep 0.1
      end
      latest = latest_change_text(events).to_s
      File.read(source) == disk_four &&
        event_count(events, 'textDocument/didChange') > rejection_changes &&
        latest.include?('editor-line-0') &&
        !latest.include?('disk-three-line-0') &&
        !latest.include?('disk-four-line-0')
    end
    command(writer, 'q!')
    await('clean exit') { Process.waitpid(pid, Process::WNOHANG) }
    drain.join(1)
    puts JSON.generate(
      result: 'PASS',
      isolated_state: true,
      popup_isolation: true,
      unresolved_edit: true,
      later_default: true,
      review_labels: true,
      paste_isolation: true,
      reload_undo: true,
      save_conflict_overwrite: true,
      stale_overwrite_rejected: true,
      root: root,
    )
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
