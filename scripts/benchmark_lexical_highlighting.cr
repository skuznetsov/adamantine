require "../src/adamantine/lexical_highlighter"

# Release-only probe, not a wall-clock CI gate. Source loading and piece-tree
# construction are outside the measured lexical work.
control = Adamantine::LexicalHighlighter.new(
  Adamantine::BufferSearch::Source.new(Tui::PieceTreeBuffer.new("def value\n  42\nend"))
)
control.request(2)
while control.advance(64)
end
raise "keyword positive control failed" unless control.name_at(0, 0) == "keyword"
raise "number positive control failed" unless control.name_at(1, 2) == "number"

path = ARGV.first?
text = if path == "--single-line"
         "x" * 6_000_000 + "\nend"
       elsif path
         File.read(path)
       else
         "def sample\n  value = 42 # comment\nend\n" * 160_000
       end
tree = Tui::PieceTreeBuffer.new(text)
lexer = Adamantine::LexicalHighlighter.new(Adamantine::BufferSearch::Source.new(tree))
lexer.request(tree.line_count - 1)
GC.collect
before_stats = GC.stats
before = before_stats.total_bytes
started = Time.instant
max_batch = Time::Span.zero
batches = 0
loop do
  batch_started = Time.instant
  more = lexer.advance(4096)
  raise "work budget exceeded" if lexer.last_progress.codepoints_scanned > 4096
  raise "line cache exceeded" if lexer.cached_line_count > Adamantine::LexicalHighlighter::DEFAULT_MAX_CACHED_LINES
  raise "span cache exceeded" if lexer.cached_span_count > Adamantine::LexicalHighlighter::DEFAULT_MAX_CACHED_SPANS
  elapsed = Time.instant - batch_started
  max_batch = elapsed if elapsed > max_batch
  batches += 1
  break unless more
end
elapsed = Time.instant - started
allocated = GC.stats.total_bytes - before
GC.collect
after_stats = GC.stats
# Pessimistic live GC bytes, not process RSS; construction is excluded.
retained_delta = (after_stats.heap_size - after_stats.free_bytes).to_i64 -
                 (before_stats.heap_size - before_stats.free_bytes).to_i64
puts "bytes,lines,batches,elapsed_ms,max_batch_ms,gross_allocated_bytes,live_gc_delta_bytes"
puts "#{text.bytesize},#{tree.line_count},#{batches},#{elapsed.total_milliseconds.round(3)},#{max_batch.total_milliseconds.round(3)},#{allocated},#{retained_delta}"
