require "../src/adamantine/editing_text_editor"
require "../src/adamantine/replace_utils"

# Diagnostic only: allocation deltas are gross allocations, not retained RSS.
# Setup, explicit GC, output comparison and Undo checks are outside timing.
# No LSP client is connected. Preparation is synchronous: elapsed time is also
# a lower bound on the UI pause for this operation.
# Usage: benchmark_buffer_replace [buffer|baseline]
mode = ARGV.shift? || "buffer"
abort "expected buffer or baseline" unless {"buffer", "baseline"}.includes?(mode)
flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)
fixtures = [
  {"sparse-lines", ("a" * 196 + "\r\n") * 20_000 + "old"},
  {"sparse-long-line", "a" * 4_000_000 + "old"},
  {"dense", ("old" + "a" * 197) * 20_000},
]
puts "mode,fixture,bytes,iteration,replace_ms,allocated_bytes"
fixtures.each do |name, original|
  expected = original.gsub("old", "NEW!")
  3.times do |iteration|
    editor = Adamantine::EditingTextEditor.new("replace-probe")
    raise "fixture refused" unless editor.load_content_as_saved(original)
    GC.collect
    allocated = GC.stats.total_bytes
    started = Time.instant
    if mode == "baseline"
      # The previous command route counted, replaced, compared, then delegated
      # to replace_text, which performs its own comparison before the edit.
      count = Adamantine::ReplaceUtils.replace_match_count(editor.text, "old", flags)
      raise "missing positive control" if count == 0
      result = Adamantine::ReplaceUtils.replace_text_content(editor.text, "old", "NEW!", flags)
      raise "unexpected no-op" if result == editor.text
      raise "replace refused" unless editor.replace_text(result)
    else
      raise "replace refused" unless editor.replace_literal("old", "NEW!", flags)
    end
    elapsed = Time.instant - started
    allocated = GC.stats.total_bytes - allocated
    raise "wrong replacement" unless editor.text == expected
    raise "missing undo" unless editor.undo
    raise "wrong undo" unless editor.text == original
    raise "extra undo" if editor.can_undo?
    raise "missing redo" unless editor.redo
    raise "wrong redo" unless editor.text == expected
    puts "#{mode},#{name},#{original.bytesize},#{iteration + 1},#{elapsed.total_milliseconds.round(3)},#{allocated}"
  end
end
