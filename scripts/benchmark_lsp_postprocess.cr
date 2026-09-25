require "../src/adamantine/editing_text_editor"
require "../src/adamantine/semantic_tokens"
require "../src/adamantine/folding"

# Gross GC allocation and synchronous CPU time, not retained RSS or end-to-end
# LSP latency. File loading and buffer construction are outside the interval.
path = ARGV.shift? || abort("usage: benchmark_lsp_postprocess FILE [baseline|snapshot]")
mode = ARGV.shift? || "snapshot"
abort "expected baseline or snapshot" unless {"baseline", "snapshot"}.includes?(mode)
text = File.read(path)
editor = Adamantine::EditingTextEditor.new("postprocess-probe")
raise "fixture refused" unless editor.load_content_as_saved(text)
legend = Adamantine::SemanticOverlay::STANDARD_LEGEND
tokens = [0, 0, 1, 15, 0]
expected_folds = Adamantine::Folding.merge_crystal_branches(editor.lines, [] of Tui::TextEditor::FoldRange)
  .map { |range| {range.start_line, range.end_line} }
puts "mode,bytes,iteration,elapsed_ms,allocated_bytes,fold_count"
3.times do |iteration|
  GC.collect
  allocated = GC.stats.total_bytes
  started = Time.instant
  if mode == "baseline"
    overlay = Adamantine::SemanticOverlay.build(tokens, editor.lines, legend)
    overlay.apply_hash_comments(editor.lines)
    folds = Adamantine::Folding.merge_crystal_branches(editor.lines, [] of Tui::TextEditor::FoldRange)
  else
    source = editor.lsp_line_source
    overlay = Adamantine::SemanticOverlay.build(tokens, source, legend)
    overlay.apply_hash_comments(source)
    folds = Adamantine::Folding.merge_crystal_branches(source, [] of Tui::TextEditor::FoldRange)
  end
  elapsed = Time.instant - started
  allocated = GC.stats.total_bytes - allocated
  raise "missing positive token control" unless overlay.any_tokens?
  raise "folding output differs from reference" unless folds.map { |range| {range.start_line, range.end_line} } == expected_folds
  puts "#{mode},#{text.bytesize},#{iteration + 1},#{elapsed.total_milliseconds.round(3)},#{allocated},#{folds.size}"
end
