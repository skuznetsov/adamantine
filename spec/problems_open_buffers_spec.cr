require "spec"
require "file_utils"

require "../src/adamantine/app"

private class OpenFilesProblemsApp < Adamantine::App
  def open_public(path : Path) : Bool
    open_file(path)
  end

  def set_diagnostics_public(path : Path, diagnostics : Array(Adamantine::Lsp::Diagnostic), partial : Bool = false) : Nil
    buffer = @document_session.open_buffers[path.to_s].not_nil!
    buffer.diagnostics = diagnostics
    buffer.diagnostics_partial = partial
    buffer.diagnostics_generation &+= 1_u64
  end

  def open_problems_public : Nil
    open_problems
  end

  def problem_count_public : Int32
    @problems.rows.size
  end

  def problem_paths_public : Array(String)
    @problems.rows.map(&.buffer_path)
  end

  def problem_display_paths_public : Array(String)
    @problems.rows.map(&.display_path)
  end

  def problem_row_texts_public : Array(String)
    @problems.rows.map { |row| problems_row_text(row) }
  end

  def select_problem_for_public(path : Path) : Nil
    @problems.selected = @problems.rows.index! { |row| row.buffer_path == path.to_s }.to_i32
  end

  def problems_partial_public : Bool
    @problems.partial
  end

  def mode_public : String
    active_input_mode.to_s
  end

  def current_path_public : String?
    current_buffer.try(&.path.to_s)
  end

  def buffer_text_public(path : Path) : String
    @document_session.open_buffers[path.to_s].not_nil!.editor.text
  end

  def insert_in_buffer_public(path : Path, text : String) : Nil
    @document_session.open_buffers[path.to_s].not_nil!.editor.insert_text(text)
  end

  def current_cursor_public : Tuple(Int32, Int32)
    editor = current_editor.not_nil!
    {editor.cursor_line, editor.cursor_col}
  end

  def dispatch_public(event : Tui::Event) : Nil
    current_editor.try(&.on_event(event)) unless on_capture(event)
  end

  def clear_diagnostics_public(path : Path) : Nil
    clear_buffer_diagnostics(@document_session.open_buffers[path.to_s].not_nil!)
  end

  def advance_diagnostics_generation_public(path : Path) : Nil
    @document_session.open_buffers[path.to_s].not_nil!.diagnostics_generation &+= 1_u64
  end
end

private def open_files_diagnostic(line : Int32, column : Int32, severity : Int32, message : String) : Adamantine::Lsp::Diagnostic
  Adamantine::Lsp::Diagnostic.new(line, column, message, "open-files", severity, line, column)
end

describe "open-files Problems" do
  it "aggregates diagnostics from every live open buffer" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    first = root / "first.cr"
    second = root / "second.cr"
    File.write(first, "first\n")
    File.write(second, "second\n")
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(first).should be_true
    app.open_public(second).should be_true
    app.set_diagnostics_public(first, [open_files_diagnostic(0, 0, 2, "first warning")])
    app.set_diagnostics_public(second, [open_files_diagnostic(0, 0, 1, "second error")])
    app.open_problems_public

    app.problem_count_public.should eq(2)
    app.problem_paths_public.should eq([second.to_s, first.to_s])
    app.problem_display_paths_public.should eq(["second.cr", "first.cr"])
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end

  it "navigates to the exact existing dirty target without rereading disk" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    first = root / "first.cr"
    second = root / "second.cr"
    File.write(first, "first\n")
    File.write(second, "second\n")
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(first).should be_true
    app.insert_in_buffer_public(first, "dirty ")
    app.open_public(second).should be_true
    app.set_diagnostics_public(first, [open_files_diagnostic(0, 1, 1, "first error")])
    app.set_diagnostics_public(second, [open_files_diagnostic(0, 0, 2, "second warning")])
    app.open_problems_public
    app.select_problem_for_public(first)
    File.write(first, "replacement from disk\n")

    app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

    app.current_path_public.should eq(first.to_s)
    app.buffer_text_public(first).should eq("dirty first\n")
    app.current_cursor_public.should eq({0, 1})
    app.mode_public.should eq("Normal")
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end

  it "rejects a row whose inactive target generation changed" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    first = root / "first.cr"
    second = root / "second.cr"
    File.write(first, "first\n")
    File.write(second, "second\n")
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(first).should be_true
    app.open_public(second).should be_true
    app.set_diagnostics_public(first, [open_files_diagnostic(0, 1, 1, "first error")])
    app.open_problems_public
    app.select_problem_for_public(first)
    app.advance_diagnostics_generation_public(first)

    app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

    app.current_path_public.should eq(second.to_s)
    app.current_cursor_public.should eq({0, 0})
    app.mode_public.should eq("Normal")
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end

  it "closes the aggregate snapshot when an inactive buffer is invalidated" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    first = root / "first.cr"
    second = root / "second.cr"
    File.write(first, "first\n")
    File.write(second, "second\n")
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(first).should be_true
    app.open_public(second).should be_true
    app.set_diagnostics_public(first, [open_files_diagnostic(0, 0, 1, "first error")])
    app.open_problems_public
    app.mode_public.should eq("Problems")

    app.clear_diagnostics_public(first)

    app.mode_public.should eq("Normal")
    app.current_path_public.should eq(second.to_s)
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end

  it "enforces the aggregate row limit and preserves partial coverage" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    first = root / "first.cr"
    second = root / "second.cr"
    File.write(first, "first\n")
    File.write(second, "second\n")
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(first).should be_true
    app.open_public(second).should be_true
    app.set_diagnostics_public(first, Array.new(600) { |index| open_files_diagnostic(0, 0, 2, "first #{index}") })
    app.set_diagnostics_public(second, Array.new(600) { |index| open_files_diagnostic(0, 0, 2, "second #{index}") })
    app.open_problems_public

    app.problem_count_public.should eq(Adamantine::ProblemsController::PROBLEMS_MAX_ROWS)
    app.problems_partial_public.should be_true
    app.problem_paths_public.count(first.to_s).should eq(600)
    app.problem_paths_public.count(second.to_s).should eq(400)
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end

  it "shows a partial empty aggregate when any open buffer is partial" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    first = root / "first.cr"
    second = root / "second.cr"
    File.write(first, "first\n")
    File.write(second, "second\n")
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(first).should be_true
    app.open_public(second).should be_true
    app.set_diagnostics_public(first, [] of Adamantine::Lsp::Diagnostic, true)
    app.open_problems_public

    app.problem_count_public.should eq(0)
    app.problems_partial_public.should be_true
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end

  it "keeps duplicate basenames distinguishable in rendered rows" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root / "one")
    Dir.mkdir_p(root / "two")
    first = root / "one" / "source.cr"
    second = root / "two" / "source.cr"
    File.write(first, "first\n")
    File.write(second, "second\n")
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(first).should be_true
    app.open_public(second).should be_true
    app.set_diagnostics_public(first, [open_files_diagnostic(0, 0, 1, "first")])
    app.set_diagnostics_public(second, [open_files_diagnostic(0, 0, 1, "second")])
    app.open_problems_public

    app.problem_display_paths_public.should eq(["one/source.cr", "two/source.cr"])
    app.problem_row_texts_public[0].should contain("one/source.cr:1:1")
    app.problem_row_texts_public[1].should contain("two/source.cr:1:1")
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end

  it "preserves publication order when diagnostics otherwise tie" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    source = root / "source.cr"
    File.write(source, "source\n")
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(source).should be_true
    app.set_diagnostics_public(source, [
      open_files_diagnostic(0, 0, 1, "z first publication"),
      open_files_diagnostic(0, 0, 1, "a second publication"),
      open_files_diagnostic(0, 0, 1, "m third publication"),
    ])
    app.open_problems_public

    app.problem_row_texts_public.map { |text| text.split(" ", 4).last }.should eq([
      "z first publication",
      "a second publication",
      "m third publication",
    ])
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end

  it "renders paths relative to the canonical project root" do
    container = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    actual_root = container / "actual"
    alias_root = container / "alias"
    Dir.mkdir_p(actual_root / "nested")
    File.symlink(actual_root, alias_root)
    source = actual_root / "nested" / "source.cr"
    File.write(source, "source\n")
    app = OpenFilesProblemsApp.new(project_root: alias_root, lsp_command: "", recovery_root: container / "recovery")

    app.open_public(source).should be_true
    app.set_diagnostics_public(source, [open_files_diagnostic(0, 0, 1, "canonical path")])
    app.open_problems_public

    app.problem_display_paths_public.should eq(["nested/source.cr"])
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(container) if container
  end

  it "retains the globally highest-priority rows after bounded compaction" do
    root = Path.new(Dir.tempdir, "adamantine-open-problems-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    warning_path = root / "warnings.cr"
    hint_path = root / "hints.cr"
    error_path = root / "errors.cr"
    [warning_path, hint_path, error_path].each { |path| File.write(path, "source\n") }
    app = OpenFilesProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")

    app.open_public(warning_path).should be_true
    app.open_public(hint_path).should be_true
    app.open_public(error_path).should be_true
    app.set_diagnostics_public(warning_path, Array.new(1000) { |index| open_files_diagnostic(0, 0, 2, "warning #{index}") })
    app.set_diagnostics_public(hint_path, Array.new(1000) { |index| open_files_diagnostic(0, 0, 4, "hint #{index}") })
    app.set_diagnostics_public(error_path, Array.new(1000) { |index| open_files_diagnostic(0, 0, 1, "error #{index}") })
    app.open_problems_public

    app.problem_count_public.should eq(1000)
    app.problems_partial_public.should be_true
    app.problem_paths_public.all? { |path| path == error_path.to_s }.should be_true
  ensure
    app.try &.quit(force: true)
    FileUtils.rm_rf(root) if root
  end
end
