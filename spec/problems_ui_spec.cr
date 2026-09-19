require "spec"
require "file_utils"

require "../src/adamantine/app"

private class ProblemsUiContractApp < Adamantine::App
  def open_public(path : Path) : Bool
    open_file(path)
  end

  def set_diagnostics_public(diagnostics : Array(Adamantine::Lsp::Diagnostic), partial : Bool = false) : Nil
    buffer = current_buffer.not_nil!
    buffer.diagnostics = diagnostics
    buffer.diagnostics_partial = partial
    buffer.diagnostics_generation &+= 1_u64
  end

  def open_problems_public : Nil
    open_problems
  end

  def dispatch_public(event : Tui::Event) : Nil
    on_capture(event)
  end

  def mode_public : String
    active_input_mode.to_s
  end

  def selected_line_public : Int32?
    @problems.rows[@problems.selected]?.try(&.diagnostic.line)
  end

  def partial_public : Bool
    @problems.partial
  end

  def empty_status_public : String
    problems_empty_status
  end

  def set_bindings_public(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end
end

private def with_problems_ui_app(&)
  root = Path.new(Dir.tempdir, "adamantine-problems-ui-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "source.cr"
  File.write(path, "🙂x\nsecond\n")
  app = ProblemsUiContractApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")
  app.open_public(path).should be_true
  yield app
ensure
  app.try &.quit(force: true)
  FileUtils.rm_rf(root) if root
end

private def ui_diagnostic(line : Int32, col : Int32, severity : Int32?, message : String) : Adamantine::Lsp::Diagnostic
  Adamantine::Lsp::Diagnostic.new(line, col, message, "ui", severity, line, col)
end

describe "Problems UI contracts" do
  it "orders rows by severity while retaining codepoint navigation" do
    with_problems_ui_app do |app|
      app.set_diagnostics_public([
        ui_diagnostic(1, 2, 2, "warning"),
        ui_diagnostic(0, 1, 1, "error"),
      ])
      app.open_problems_public
      app.mode_public.should eq("Problems")
      app.selected_line_public.should eq(0)

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down))
      app.selected_line_public.should eq(1)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.mode_public.should eq("Normal")
    end
  end

  it "keeps explicit partial state for an empty current-document list" do
    with_problems_ui_app do |app|
      app.set_diagnostics_public([] of Adamantine::Lsp::Diagnostic, true)
      app.open_problems_public
      app.partial_public.should be_true
      app.empty_status_public.should contain("partial")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.mode_public.should eq("Problems")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
    end
  end

  it "honors remapped modal navigation and consumes unknown editor keys" do
    with_problems_ui_app do |app|
      bindings = Adamantine::KeyConfig.defaults
      bindings["lsp.problems_down"] = ["ctrl+n"]
      bindings["lsp.problems_cancel"] = ["ctrl+x"]
      app.set_bindings_public(bindings)
      app.set_diagnostics_public([
        ui_diagnostic(0, 1, 1, "error"),
        ui_diagnostic(1, 0, 2, "warning"),
      ])
      text = "🙂x\nsecond\n"
      app.open_problems_public
      app.dispatch_public(Tui::KeyEvent.new('n', Tui::Modifiers::Ctrl))
      app.selected_line_public.should eq(1)
      app.dispatch_public(Tui::KeyEvent.new('z'))
      app.dispatch_public(Tui::PasteEvent.new("must not edit"))
      app.dispatch_public(Tui::KeyEvent.new('x', Tui::Modifiers::Ctrl))
      app.mode_public.should eq("Normal")
    end
  end
end
