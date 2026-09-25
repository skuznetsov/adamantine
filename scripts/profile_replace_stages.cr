require "../src/adamantine/editing_text_editor"
require "../src/adamantine/buffer_replace"
require "../src/adamantine/replace_utils"

# Source-linked diagnostic for the stages behind EditingTextEditor#replace_literal.
# The candidate builder mirrors its bounded batch/splice loop so it can replay
# precomputed matches without modifying production code. Timed stages are
# independent probes and are not additive wall-clock components.
private class ReplaceStageEditor < Adamantine::EditingTextEditor
  def collect_replace_matches(matches_query : String) : Array(Adamantine::BufferReplace::Match)
    matches = [] of Adamantine::BufferReplace::Match
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)
    Adamantine::BufferReplace.each_match(search_source, matches_query, "Z", flags) do |match|
      matches << match
    end
    matches
  end

  def count_replace_matches(matches_query : String) : Int32
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)
    Adamantine::BufferReplace.each_match(search_source, matches_query, "Z", flags) { }
  end

  # Replays the production bounded batching and atomic tree splice over the
  # captured matches. The fixture is ASCII with no CRLF seams, but the source
  # helpers are called so the range policy remains linked to production code.
  def build_replace_candidate(matches : Array(Adamantine::BufferReplace::Match)) : Tui::PieceTreeBuffer
    candidate = @buffer.replace_fork
    delta = 0_i64
    candidate_bytes = @buffer.byte_length.to_i64
    batch_start : Int32? = nil
    batch_end = 0
    batch_last_end = 0
    batch_output = IO::Memory.new
    batch_output_bytes = 0

    flush_batch = -> : Nil do
      if start_byte = batch_start
        replacement = batch_output.to_s
        candidate_start = start_byte.to_i64 + delta
        candidate_finish = batch_end.to_i64 + delta
        unless candidate_start >= 0 && candidate_finish >= candidate_start && candidate_finish <= candidate.byte_length
          raise IndexError.new("replacement batch outside candidate")
        end

        start, finish, spliced = atomic_replace_span(
          candidate,
          candidate_start.to_i32,
          candidate_finish.to_i32,
          replacement
        )
        original_span = batch_end - start_byte
        batch_delta = replacement.bytesize - original_span
        candidate_bytes += batch_delta
        raise "candidate byte count overflow" if candidate_bytes > Int32::MAX

        candidate_span = finish - start
        candidate_range = candidate.slice(start, candidate_span)
        candidate.replace_range_atomic(start, candidate_span, spliced) unless candidate_range == spliced
        delta += batch_delta

        batch_start = nil
        batch_end = 0
        batch_last_end = 0
        batch_output = IO::Memory.new
        batch_output_bytes = 0
      end
    end

    matches.each do |match|
      next if match.original == match.replacement

      if start_byte = batch_start
        source_span = match.end_byte - start_byte
        if source_span > REPLACE_BATCH_SOURCE_BYTES
          flush_batch.call
        else
          gap = original_replace_slice(batch_last_end, match.start_byte)
          projected_batch_bytes = batch_output_bytes + gap.bytesize + match.replacement.bytesize
          if projected_batch_bytes + 2 > REPLACE_BATCH_OUTPUT_BYTES
            flush_batch.call
          else
            batch_output.write(gap.to_slice)
            batch_output.write(match.replacement.to_slice)
            batch_output_bytes = projected_batch_bytes
            batch_end = match.end_byte
            batch_last_end = match.end_byte
            next
          end
        end
      end

      batch_start = match.start_byte
      batch_end = match.end_byte
      batch_last_end = match.end_byte
      batch_output = IO::Memory.new
      batch_output.write(match.replacement.to_slice)
      batch_output_bytes = match.replacement.bytesize
    end

    flush_batch.call
    raise "candidate byte count differs" unless candidate.byte_length.to_i64 == candidate_bytes
    candidate
  end

  def detect_candidate_line_ending(candidate : Tui::PieceTreeBuffer) : String
    replacement_line_ending(candidate)
  end

  # Mirrors the commit tail of replace_literal, using the already measured
  # production line-ending result so tree adoption/history/callback time stays
  # separately visible.
  def commit_replace_candidate(candidate : Tui::PieceTreeBuffer, line_ending : String) : Nil
    cursor_line = @cursor.line
    cursor_col = @cursor.col
    begin_edit(nil)
    @buffer.adopt_replace_fork!(candidate)
    @line_ending = line_ending
    @cursor.line = cursor_line.clamp(0, line_count - 1)
    @cursor.col = cursor_col.clamp(0, line_length(@cursor.line))
    @selection = nil
    text_changed(Tui::TextEditor::TextChange.full)
  end
end

private def elapsed_ms(started : Time::Instant) : Float64
  (Time.instant - started).total_milliseconds
end

private def emit(stage : String, iteration : Int32, matches : Int32, bytes : Int32, ms : Float64, allocated : Int64) : Nil
  puts "#{stage},#{iteration},#{matches},#{bytes},#{ms.round(3)},#{allocated}"
end

size_mib = (ARGV[0]? || "15").to_i?
repeats = (ARGV[1]? || "5").to_i?
abort "usage: crystal run scripts/profile_replace_stages.cr -- [size_mib 1..15] [repeats 3..20]" unless ARGV.size <= 2
abort "size_mib must be 1..15" unless size_mib && size_mib.in?(1..15)
abort "repeats must be 3..20" unless repeats && repeats.in?(3..20)

fixture_bytes = size_mib.to_i * 1024 * 1024
fixture_repeats = fixture_bytes // 256
original = "old" + ("x" * 253)
original *= fixture_repeats
expected = "Z" + ("x" * 253)
expected *= fixture_repeats
flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)
absent_query = "needle-not-in-fixture"
width = 80
height = 24

puts "# crystal=#{Crystal::VERSION}; source=working-tree require; fixture=single-line ASCII old+253x repeated"
puts "stage,iteration,matches,fixture_bytes,elapsed_ms,gross_allocated_bytes"

repeats.to_i.times do |index|
  iteration = index + 1
  stage_editor = ReplaceStageEditor.new("replace-stage-profile")
  raise "fixture load failed" unless stage_editor.load_content_as_saved(original)

  scan_count = 0
  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  scan_count = stage_editor.count_replace_matches("old")
  scan_ms = elapsed_ms(started)
  emit("match_scan", iteration, scan_count, fixture_bytes, scan_ms, (GC.stats.total_bytes - allocated_before).to_i64)
  raise "match scan count mismatch: #{scan_count}" unless scan_count == fixture_repeats

  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  matches = stage_editor.collect_replace_matches("old")
  capture_ms = elapsed_ms(started)
  emit("match_capture_for_replay", iteration, matches.size, fixture_bytes, capture_ms, (GC.stats.total_bytes - allocated_before).to_i64)
  raise "captured match count mismatch" unless matches.size == fixture_repeats

  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  candidate = stage_editor.build_replace_candidate(matches)
  build_ms = elapsed_ms(started)
  emit("detached_tree_build", iteration, matches.size, fixture_bytes, build_ms, (GC.stats.total_bytes - allocated_before).to_i64)

  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  line_ending = stage_editor.detect_candidate_line_ending(candidate)
  line_scan_ms = elapsed_ms(started)
  emit("line_ending_scan", iteration, matches.size, fixture_bytes, line_scan_ms, (GC.stats.total_bytes - allocated_before).to_i64)

  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  stage_editor.commit_replace_candidate(candidate, line_ending)
  commit_ms = elapsed_ms(started)
  emit("editor_commit", iteration, matches.size, fixture_bytes, commit_ms, (GC.stats.total_bytes - allocated_before).to_i64)
  raise "mirrored candidate output mismatch" unless stage_editor.text == expected

  actual_editor = ReplaceStageEditor.new("replace-actual-profile")
  raise "fixture load failed" unless actual_editor.load_content_as_saved(original)
  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  changed = actual_editor.replace_literal("old", "Z", flags)
  total_ms = elapsed_ms(started)
  emit("replace_literal_total", iteration, fixture_repeats, fixture_bytes, total_ms, (GC.stats.total_bytes - allocated_before).to_i64)
  raise "actual replacement refused" unless changed
  raise "actual replacement output mismatch" unless actual_editor.text == expected

  actual_editor.rect = Tui::Rect.new(0, 0, width, height)
  actual_editor.focus
  render_buffer = Tui::Buffer.new(width, height)
  clip = Tui::Rect.new(0, 0, width, height)
  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  actual_editor.render(render_buffer, clip)
  render_ms = elapsed_ms(started)
  emit("widget_render_80x24", iteration, fixture_repeats, fixture_bytes, render_ms, (GC.stats.total_bytes - allocated_before).to_i64)

  control_editor = ReplaceStageEditor.new("replace-negative-control")
  raise "fixture load failed" unless control_editor.load_content_as_saved(original)
  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  control_matches = control_editor.count_replace_matches(absent_query)
  control_scan_ms = elapsed_ms(started)
  emit("no_match_scan_control", iteration, control_matches, fixture_bytes, control_scan_ms, (GC.stats.total_bytes - allocated_before).to_i64)
  raise "negative matcher control found a match" unless control_matches == 0

  GC.collect
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  control_changed = control_editor.replace_literal(absent_query, "Z", flags)
  control_total_ms = elapsed_ms(started)
  emit("no_match_replace_control", iteration, control_matches, fixture_bytes, control_total_ms, (GC.stats.total_bytes - allocated_before).to_i64)
  raise "negative replace control changed the document" if control_changed || control_editor.text != original || control_editor.can_undo?
end
