require "../src/adamantine/editing_text_editor"
require "../src/adamantine/project_search"
require "../src/adamantine/buffer_search"

# Diagnostic, not a portable CI threshold. Initialization and explicit GC are
# outside the measured scan. GC allocation deltas are not retained memory/RSS.
# Usage: benchmark_buffer_search [buffer|baseline] [optional-input-file]
mode = ARGV.shift? || "buffer"
abort "expected buffer or baseline" unless {"buffer", "baseline"}.includes?(mode)
fixtures = if path = ARGV.shift?
             [{path, File.read(path)}]
           else
             [
               {"many-lines", ("a" * 199 + "\n") * 20_000},
               {"single-line", "a" * 4_000_000},
             ]
           end

# Positive controls ensure a no-hit timing cannot pass by disabling matching.
control = Adamantine::EditingTextEditor.new("search-control")
control.text = "prefix needle suffix"
raise "baseline positive control failed" unless Adamantine::ProjectSearch.search_text(control.text, "needle").size == 1
raise "buffer positive control failed" unless Adamantine::BufferSearch.scan(control.search_source, "needle").matches.size == 1

puts "mode,fixture,bytes,iteration,scan_ms,allocated_bytes,max_fiber_gap_ms"
fixtures.each do |name, text|
  editor = Adamantine::EditingTextEditor.new("search-probe")
  editor.text = text
  3.times do |iteration|
    GC.collect
    running = true
    maximum_gap = Time::Span.zero
    ready = Channel(Nil).new
    done = Channel(Nil).new
    spawn do
      previous = Time.instant
      ready.send(nil)
      while running
        Fiber.yield
        now = Time.instant
        maximum_gap = Math.max(maximum_gap, now - previous)
        previous = now
      end
      done.send(nil)
    end
    ready.receive
    allocated = GC.stats.total_bytes
    start = Time.instant
    matches = if mode == "baseline"
                Adamantine::ProjectSearch.search_text(editor.text, "__adamantine_absent_probe_573019__")
              else
                result = Adamantine::BufferSearch.scan(editor.search_source, "__adamantine_absent_probe_573019__", checkpoint: -> { true })
                raise "buffer probe unexpectedly cancelled or truncated" if result.cancelled? || result.truncated?
                result.matches
              end
    elapsed = Time.instant - start
    allocated = GC.stats.total_bytes - allocated
    raise "fixture unexpectedly contains the probe token" unless matches.empty?
    running = false
    done.receive
    puts "#{mode},#{name},#{text.bytesize},#{iteration + 1},#{elapsed.total_milliseconds.round(3)},#{allocated},#{maximum_gap.total_milliseconds.round(3)}"
  end
end
