#!/usr/bin/env ruby

require "digest"
require "io/console"
require "json"
require "pty"
require "tmpdir"
require "timeout"

binary = File.expand_path(ARGV.fetch(0))
raise "editor binary is not executable: #{binary}" unless File.executable?(binary)

def terminal_text(output)
  output
    .gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
    .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")
    .gsub("\r", "")
end

def output_since(output, offset)
  (output.byteslice(offset..) || "").scrub
end

def await(label, timeout_seconds: 15.0, interval: 0.05)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
  loop do
    return yield if yield

    raise "timed out waiting for #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep interval
  end
end

def command(writer, text)
  writer.write("\e[112;6u")
  sleep 0.15
  ":#{text}".each_codepoint { |codepoint| writer.write("\e[#{codepoint}u") }
  writer.write("\e[13u")
  writer.flush
end

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def type_text(writer, text)
  text.each_codepoint { |codepoint| writer.write("\e[#{codepoint}u") }
  writer.flush
end

def messages(path)
  return [] unless File.file?(path)

  File.readlines(path, chomp: true).map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end.compact
end

def frame_paths(state)
  Dir.glob(File.join(state, "adamantine", "recovery", "sessions", "session-*", "snapshot-*.arc"))
    .select { |path| File.file?(path) }
    .sort
end

def frame_manifest(state)
  frame_paths(state).to_h do |path|
    [path, { bytes: File.size(path), digest: Digest::SHA256.file(path).hexdigest }]
  end
end

def recovered_tree_manifest(state)
  root = File.join(state, "adamantine", "recovery", "recovered")
  result = {}
  return result unless File.directory?(root)

  visit = nil
  visit = lambda do |directory, prefix|
    Dir.each_child(directory) do |name|
      path = File.join(directory, name)
      relative = prefix.empty? ? name : File.join(prefix, name)
      if File.symlink?(path)
        result[relative] = { type: "symlink", target: File.readlink(path) }
      elsif File.directory?(path)
        result[relative] = { type: "directory" }
        visit.call(path, relative)
      elsif File.file?(path)
        result[relative] = {
          type: "file",
          bytes: File.size(path),
          digest: Digest::SHA256.file(path).hexdigest,
        }
      end
    end
  end
  visit.call(root, "")
  result
end

def stop_child(pid, signal = "TERM")
  return unless pid

  begin
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end
  begin
    Process.waitpid(pid)
  rescue Errno::ECHILD
    nil
  end
end

def spawn_drain(reader, output)
  Thread.new do
    loop do
      output << reader.readpartial(16_384)
    rescue EOFError, Errno::EIO
      break
    end
  end
end

root = File.realpath(Dir.mktmpdir("adamantine-recovery-preview-"))
project = File.join(root, "project")
state = File.join(root, "state")
Dir.mkdir(project)
source = File.join(project, "draft.cr")
config = File.join(root, "config.toml")
events_one = File.join(root, "lsp-one.jsonl")
events_two = File.join(root, "lsp-two.jsonl")
File.binwrite(source, "puts \"disk source\"\n")
File.binwrite(config, "")

fixture = File.expand_path("../spec/fixtures/formatting_probe_server.rb", __dir__)
marker = "RECOVERYCHECKPOINTMARKER"
env = {
  "TERM" => "xterm-256color",
  "XDG_STATE_HOME" => state,
  "ADAMANTINE_SESSION" => "0",
  "ADAMANTINE_RECOVERY" => "1",
}

first_source_bytes = File.binread(source)
first_frames = nil
first_pid = nil
first_reaped = false
first_output = +""
first_drain = nil

begin
  PTY.spawn(
    env,
    binary,
    project,
    "--config", config,
    "--lsp", RbConfig.ruby,
    "--lsp-arg", fixture,
    "--lsp-arg", events_one,
  ) do |reader, writer, pid|
    first_pid = pid
    reader.winsize = [24, 140]
    first_drain = spawn_drain(reader, first_output)

    await("first LSP initialization") do
      messages(events_one).any? { |message| message["method"] == "initialized" }
    end
    command(writer, "open #{source}")
    await("first didOpen") do
      messages(events_one).any? { |message| message["method"] == "textDocument/didOpen" }
    end

    type_text(writer, marker)
    await("first didChange") do
      messages(events_one).any? { |message| message["method"] == "textDocument/didChange" }
    end
    await("checkpoint containing edited draft", timeout_seconds: 25.0) do
      frame_paths(state).any? do |path|
        begin
          File.binread(path).include?(marker)
        rescue Errno::ENOENT
          false
        end
      end
    end

    first_frames = frame_manifest(state)
    raise "no recovery frame was captured" if first_frames.empty?
    raise "source changed before abandoned-session kill" unless File.binread(source) == first_source_bytes

    Process.kill("KILL", pid)
    Process.waitpid(pid)
    first_reaped = true
  ensure
    stop_child(pid) unless first_reaped
    first_drain&.join(1)
  end
ensure
  stop_child(first_pid) unless first_reaped
end

second_output = +""
second_drain = nil
second_pid = nil
second_reaped = false
second_frames_before_review = nil
recovered_before_review = nil

begin
  PTY.spawn(
    env,
    binary,
    project,
    "--config", config,
    "--lsp", RbConfig.ruby,
    "--lsp-arg", fixture,
    "--lsp-arg", events_two,
  ) do |reader, writer, pid|
    second_pid = pid
    reader.winsize = [24, 140]
    second_drain = spawn_drain(reader, second_output)

    await("second LSP initialization") do
      messages(events_two).any? { |message| message["method"] == "initialized" }
    end
    await("abandoned recovery menu") do
      terminal_text(second_output).include?("Abandoned Recovery Checkpoints")
    end
    key(writer, "\e")
    sleep 0.2

    command(writer, "recover")
    menu_offset = second_output.bytesize
    await("explicit recover menu") do
      text = terminal_text(output_since(second_output, menu_offset))
      text.include?("Review draft") && text.include?("Open recovered copy") && text.include?("Discard checkpoint")
    end

    review_offset = second_output.bytesize
    key(writer, "\e[13u")
    await("read-only recovery review") do
      text = terminal_text(output_since(second_output, review_offset))
      text.include?("Checkpoint") &&
        (text.include?("Disk -> Checkpoint") || text.include?("Editor -> Checkpoint") || text.include?("Checkpoint contents"))
    end

    review_source_bytes = File.binread(source)
    second_frames_before_review = frame_manifest(state)
    recovered_before_review = recovered_tree_manifest(state)
    raise "checkpoint frame changed before review" unless second_frames_before_review == first_frames
    raise "source changed before review" unless review_source_bytes == first_source_bytes

    next_view_offset = second_output.bytesize
    key(writer, "\t")
    await("next recovery review view") do
      text = terminal_text(output_since(second_output, next_view_offset))
      text.include?("Checkpoint contents") || text.include?("Disk -> Checkpoint") || text.include?("Editor -> Disk")
    end

    key(writer, "\e[120u")
    key(writer, "\e[200~PASTE_MUST_BE_IGNORED\e[201~")
    key(writer, "\e[13u")
    writer.write("\e[<0;4;4M\e[<0;4;4m")
    writer.flush
    sleep 0.35

    raise "review input changed source" unless File.binread(source) == review_source_bytes
    raise "review input changed checkpoint frame" unless frame_manifest(state) == second_frames_before_review
    raise "review created or changed recovered copy" unless recovered_tree_manifest(state) == recovered_before_review

    key(writer, "\e")
    sleep 0.25

    # Escape may close the full-screen review without emitting a redraw.  The
    # following command is therefore the closure oracle: if the modal still
    # owns input, q! is consumed; if Escape closed it, q! reaches the editor.
    command(writer, "q!")
    await("second editor exit", timeout_seconds: 10.0) do
      begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        true
      end
    end
    second_reaped = true
  ensure
    stop_child(pid) unless second_reaped
    second_drain&.join(1)
  end
ensure
  stop_child(second_pid) unless second_reaped
end

raise "source changed after review" unless File.binread(source) == first_source_bytes
raise "checkpoint frame changed after review" unless frame_manifest(state) == first_frames
raise "recovered copy appeared after review" unless recovered_tree_manifest(state) == recovered_before_review

puts JSON.generate(
  status: "PASS",
  source_unchanged: true,
  checkpoint_unchanged: true,
  review_input_isolated: true,
  no_recovered_copy_or_discard: true,
  command_recover: true,
  view_cycle: true,
)
warn "recovery preview smoke artifacts: #{root}"
