require "json"
require "../src/adamantine/safe_document_edits"

# Release probe, not a wall-clock CI gate. Source loading is excluded. Report
# edit-plan preparation separately from preview/navigation/visible row reads.
single = ARGV.includes?("--single-line")
text = single ? "x" * 6_000_000 : "value = sample_expression(argument) # context\n" * 160_000
line = single ? 0 : 150_000
editor = Adamantine::EditingTextEditor.new("preview-probe")
editor.load_content_as_saved(text, Path.new("preview-probe"))
edit = JSON.parse({"range" => {"start" => {"line" => line, "character" => 0},
                               "end" => {"line" => line, "character" => 1}},
                   "newText" => "Z"}.to_json)
started = Time.instant
plan = editor.prepare_document_edits([edit])
prepare_ms = (Time.instant - started).total_milliseconds
GC.collect
before = GC.stats.total_bytes
started = Time.instant
preview = plan.inline_preview("Probe")
first_top = preview.top
100.times do
  preview.next_change
  preview.previous_change
end
seen_change = false
(first_top...[first_top + 30, preview.row_count].min).each do |index|
  row = preview.row_at(index)
  raise "row allocation bound violated" if row.text.bytesize > Adamantine::InlineEditPreview::MAX_ROW_BYTES
  seen_change ||= row.prefix == '-' || row.prefix == '+'
end
raise "preview did not open at change" unless seen_change
raise "preview mutated history" if editor.can_undo?
elapsed = (Time.instant - started).total_milliseconds
allocated = GC.stats.total_bytes - before
puts "source_bytes,prepare_ms,preview_and_200_jumps_ms,gross_preview_allocated_bytes,virtual_rows,initial_top"
puts "#{text.bytesize},#{prepare_ms.round(3)},#{elapsed.round(3)},#{allocated},#{preview.row_count},#{first_top}"
