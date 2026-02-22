require "json"
require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/app"

class FakeLspClient < CrystalEditor::Lsp::Client
  property hover_result : CrystalEditor::Lsp::Hover? = nil
  property references_result : Array(CrystalEditor::Lsp::Location) = [] of CrystalEditor::Lsp::Location
  property signature_result : CrystalEditor::Lsp::SignatureHelp? = nil
  property completion_result : Array(CrystalEditor::Lsp::CompletionItem) = [] of CrystalEditor::Lsp::CompletionItem
  property code_actions_result : Array(JSON::Any) = [] of JSON::Any
  property definition_result : Array(CrystalEditor::Lsp::Location) = [] of CrystalEditor::Lsp::Location

  getter hover_calls : Int32 = 0
  getter references_calls : Int32 = 0
  getter signature_calls : Int32 = 0
  getter completion_calls : Int32 = 0
  getter diagnostics_calls : Int32 = 0
  getter code_actions_calls : Int32 = 0
  getter definition_calls : Int32 = 0
  getter declaration_calls : Int32 = 0
  getter type_definition_calls : Int32 = 0
  getter implementation_calls : Int32 = 0

  def initialize
    super("", Path.new(Dir.current), [] of String)
    self.connected = true

    @hover_result = nil
    @references_result = [] of CrystalEditor::Lsp::Location
    @signature_result = nil
    @completion_result = [] of CrystalEditor::Lsp::CompletionItem
    @code_actions_result = [] of JSON::Any
    @definition_result = [] of CrystalEditor::Lsp::Location
  end

  def goto_definition(uri : String, line : Int32, character : Int32) : Array(CrystalEditor::Lsp::Location)
    @definition_calls += 1
    @definition_result
  end

  def declaration(uri : String, line : Int32, character : Int32) : Array(CrystalEditor::Lsp::Location)
    @declaration_calls += 1
    @definition_result
  end

  def type_definition(uri : String, line : Int32, character : Int32) : Array(CrystalEditor::Lsp::Location)
    @type_definition_calls += 1
    @definition_result
  end

  def implementation(uri : String, line : Int32, character : Int32) : Array(CrystalEditor::Lsp::Location)
    @implementation_calls += 1
    @definition_result
  end

  def hover(uri : String, line : Int32, character : Int32) : CrystalEditor::Lsp::Hover?
    @hover_calls += 1
    @hover_result
  end

  def references(uri : String, line : Int32, character : Int32, include_declaration : Bool = true) : Array(CrystalEditor::Lsp::Location)
    @references_calls += 1
    @references_result
  end

  def signature_help(uri : String, line : Int32, character : Int32) : CrystalEditor::Lsp::SignatureHelp?
    @signature_calls += 1
    @signature_result
  end

  def completion(uri : String, line : Int32, character : Int32, max_items : Int32 = 30) : Array(CrystalEditor::Lsp::CompletionItem)
    @completion_calls += 1
    @completion_result.first([@completion_result.size, max_items].min)
  end

  def code_action(uri : String, line : Int32, character : Int32) : Array(JSON::Any)
    @code_actions_calls += 1
    @code_actions_result
  end
end

class LspProtocolTestApp < CrystalEditor::App
  def open_file_public(path : Path | String, line : Int32? = nil, column : Int32? = nil) : Bool
    open_file(resolve_path(path), line, column)
  end

  def set_fake_lsp_client(client : CrystalEditor::Lsp::Client) : Nil
    @lsp = client
  end

  def clear_lsp_client : Nil
    @lsp = nil
  end

  def lsp_popup_open? : Bool
    @lsp_popup_open
  end

  def lsp_popup_title : String
    @lsp_popup_title
  end

  def lsp_popup_lines : Array(String)
    @lsp_popup_lines
  end

  def context_menu_open? : Bool
    @context_menu_open
  end

  def current_buffer_path : String?
    current_buffer.try(&.path.to_s)
  end

  def set_current_buffer_diagnostics(diagnostics : Array(CrystalEditor::Lsp::Diagnostic)) : Nil
    current_buffer.try do |buffer|
      buffer.diagnostics = diagnostics
    end
  end

  def set_cursor(line : Int32, column : Int32) : Nil
    editor = current_editor
    raise "no active editor" unless editor
    editor.set_cursor(line, column)
  end

  def open_lsp_context_menu_public : Nil
    open_lsp_context_menu
  end

  def show_hover_hint_public : Nil
    show_hover_hint
  end

  def show_references_hint_public : Nil
    show_references_hint
  end

  def show_signature_hint_public : Nil
    show_signature_hint
  end

  def show_completion_hint_public : Nil
    show_completion_hint
  end

  def show_diagnostics_hint_public : Nil
    show_diagnostics_hint
  end

  def execute_code_action_hint_public : Nil
    execute_code_action_hint
  end

  def navigation_history_size : Int32
    @document_session.navigation_history.size
  end

  def set_key_bindings(bindings : CrystalEditor::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def lsp_warnings : Array(String)
    @status_log.entries.select do |entry|
      entry.level == Tui::Log::Level::Warning
    end.map(&.message)
  end

  private def current_editor : Tui::TextEditor?
    super
  end

  private def current_buffer : CrystalEditor::OpenBuffer?
    super
  end

  private def resolve_path(path : Path | String) : Path
    case path
    when Path
      path
    else
      Path.new(path)
    end
  end
end

def with_temp_workspace(prefix : String = "editor-lsp-protocol-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::App do
  it "shows hover and reference popup content from protocol responses" do
    with_temp_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "main.cr")
      target = Path.new(tmp_dir, "util.cr")
      File.write(source, "module A\n  def one\n  end\nend\n")
      File.write(target, "module B\nend\n")

      app = LspProtocolTestApp.new(project_root: tmp_dir, lsp_command: "")
      fake = FakeLspClient.new

      fake.hover_result = CrystalEditor::Lsp::Hover.new("hover text")
      fake.references_result = [
        CrystalEditor::Lsp::Location.new(CrystalEditor::UriCodec.path_to_uri(source), 1, 2),
        CrystalEditor::Lsp::Location.new(CrystalEditor::UriCodec.path_to_uri(target), 0, 0),
      ]
      app.set_fake_lsp_client(fake)
      app.open_file_public(source)

      app.show_hover_hint_public
      raise "hover popup should open" unless app.lsp_popup_open?
      raise "hover popup title should be Hover" unless app.lsp_popup_title == "Hover"
      raise "hover popup should include returned text" unless app.lsp_popup_lines.any? { |line| line.includes?("hover text") }

      app.show_references_hint_public
      raise "references popup should open" unless app.lsp_popup_open?
      raise "references popup title should be References" unless app.lsp_popup_title == "References"
      raise "references popup should include file names" unless app.lsp_popup_lines.any?(&.starts_with?("1. "))
      raise "references request should be counted" unless fake.references_calls == 1
    end
  end

  it "renders signature and completion hints in popup mode" do
    with_temp_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "main.cr")
      File.write(source, "def foo = 1\n")

      app = LspProtocolTestApp.new(project_root: tmp_dir, lsp_command: "")
      fake = FakeLspClient.new
      fake.signature_result = CrystalEditor::Lsp::SignatureHelp.new(["sig one(a, b)", "sig two(c)"], 0, 0)
      fake.completion_result = [
        CrystalEditor::Lsp::CompletionItem.new("foo", "first item"),
        CrystalEditor::Lsp::CompletionItem.new("bar"),
      ]

      app.set_fake_lsp_client(fake)
      app.open_file_public(source)

      app.show_signature_hint_public
      raise "signature popup should open" unless app.lsp_popup_open?
      raise "signature popup title should be Signature" unless app.lsp_popup_title == "Signature"
      raise "signature popup should mark active signature" unless app.lsp_popup_lines.any? { |line| line.starts_with?("▶ sig one") }
      raise "signature request should be counted" unless fake.signature_calls == 1

      app.show_completion_hint_public
      raise "completion popup should open" unless app.lsp_popup_open?
      raise "completion popup title should be Completion" unless app.lsp_popup_title == "Completion"
      raise "completion popup should include first suggestion" unless app.lsp_popup_lines.any? { |line| line.starts_with?("1. foo - first item") }
      raise "completion request should be counted" unless fake.completion_calls == 1
    end
  end

  it "shows diagnostics and code actions from protocol contracts" do
    with_temp_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "main.cr")
      File.write(source, "error = 123\n")

      app = LspProtocolTestApp.new(project_root: tmp_dir, lsp_command: "")
      fake = FakeLspClient.new
      fake.code_actions_result = [
        JSON.parse(%({"title":"Extract method"})),
        JSON.parse(%({"title":"Rename"})),
      ]
      app.set_fake_lsp_client(fake)
      app.open_file_public(source)
      app.set_cursor(0, 0)
      app.set_current_buffer_diagnostics([
        CrystalEditor::Lsp::Diagnostic.new(
          line: 0,
          character: 0,
          message: "unknown variable",
          source: "lsp",
          severity: 1,
          end_line: 0,
          end_character: 5,
        ),
      ])

      app.show_diagnostics_hint_public
      raise "diagnostics popup should open" unless app.lsp_popup_open?
      raise "diagnostics popup title should be Diagnostics" unless app.lsp_popup_title == "Diagnostics"
      raise "diagnostics popup should include source tag" unless app.lsp_popup_lines.any? { |line| line.includes?("[lsp]") }

      app.execute_code_action_hint_public
      raise "code actions popup should open" unless app.lsp_popup_open?
      raise "code actions popup title should be Code actions" unless app.lsp_popup_title == "Code actions"
      raise "code actions should include Extract method" unless app.lsp_popup_lines.any?(&.includes?("1. Extract method"))
      raise "code action request should be counted" unless fake.code_actions_calls == 1
    end
  end

  it "drives all declaration-style menu actions through LSP context menu" do
    with_temp_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "a.cr")
      target = Path.new(tmp_dir, "b.cr")
      File.write(source, "a = 1\n")
      File.write(target, "b = 2\n")

      app = LspProtocolTestApp.new(project_root: tmp_dir, lsp_command: "")
      fake = FakeLspClient.new
      fake.definition_result = [
        CrystalEditor::Lsp::Location.new(CrystalEditor::UriCodec.path_to_uri(target), 0, 0),
      ]
      app.set_fake_lsp_client(fake)
      app.open_file_public(source)

      app.open_lsp_context_menu_public
      raise "LSP context menu should open" unless app.context_menu_open?
      raise "LSP context menu should have actions" if app.lsp_popup_open?

      handled = app.on_capture(Tui::KeyEvent.new('1'))
      raise "definition menu action should be handled" unless handled
      raise "context menu should close after selection" if app.context_menu_open?
      raise "definition should be requested through menu action" unless fake.definition_calls == 1
      raise "buffer should jump to target from LSP definition" unless app.current_buffer_path == target.to_s
      raise "navigation history should contain one jump" unless app.navigation_history_size == 1

      app.open_file_public(source)
      app.open_lsp_context_menu_public
      handled = app.on_capture(Tui::KeyEvent.new('2'))
      raise "declaration menu action should be handled" unless handled
      raise "context menu should close after selection" if app.context_menu_open?
      raise "declaration should be requested through menu action" unless fake.declaration_calls == 1
      raise "buffer should jump to target from LSP declaration" unless app.current_buffer_path == target.to_s
      raise "navigation history should contain two jumps" unless app.navigation_history_size == 2

      app.open_file_public(source)
      app.open_lsp_context_menu_public
      handled = app.on_capture(Tui::KeyEvent.new('3'))
      raise "type-definition menu action should be handled" unless handled
      raise "context menu should close after selection" if app.context_menu_open?
      raise "type definition should be requested through menu action" unless fake.type_definition_calls == 1
      raise "buffer should jump to target from LSP type definition" unless app.current_buffer_path == target.to_s
      raise "navigation history should contain three jumps" unless app.navigation_history_size == 3

      app.open_file_public(source)
      app.open_lsp_context_menu_public
      handled = app.on_capture(Tui::KeyEvent.new('4'))
      raise "implementation menu action should be handled" unless handled
      raise "context menu should close after selection" if app.context_menu_open?
      raise "implementation should be requested through menu action" unless fake.implementation_calls == 1
      raise "buffer should jump to target from LSP implementation" unless app.current_buffer_path == target.to_s
      raise "navigation history should contain four jumps" unless app.navigation_history_size == 4
    end
  end

  it "closes stale LSP popups when LSP connection is absent" do
    with_temp_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "a.cr")
      File.write(source, "a = 1\n")

      app = LspProtocolTestApp.new(project_root: tmp_dir, lsp_command: "")
      fake = FakeLspClient.new
      fake.hover_result = CrystalEditor::Lsp::Hover.new("hover text")
      app.set_fake_lsp_client(fake)
      app.open_file_public(source)

      app.show_hover_hint_public
      raise "hover popup should open before disconnect" unless app.lsp_popup_open?
      raise "expected hover popup title" unless app.lsp_popup_title == "Hover"

      app.clear_lsp_client
      app.show_hover_hint_public
      raise "popup should close after LSP disconnect" if app.lsp_popup_open?
      raise "popup title should reset after cleanup" unless app.lsp_popup_title.empty?
      raise "popup content should be cleared after cleanup" unless app.lsp_popup_lines.empty?
    end
  end

  it "keeps navigation history unchanged when goto-definition runs without LSP" do
    with_temp_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "main.cr")
      File.write(source, "def one\nend\n")

      app = LspProtocolTestApp.new(project_root: tmp_dir, lsp_command: "")
      bindings = CrystalEditor::KeyConfig.defaults
      bindings["lsp.goto_definition"] = ["f12"]
      app.set_key_bindings(bindings)
      app.open_file_public(source)

      app.clear_lsp_client
      initial_history = app.navigation_history_size
      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::F12))

      raise "F12 should be handled even when LSP is absent" unless handled
      raise "navigation history must remain unchanged without LSP" unless app.navigation_history_size == initial_history
      raise "expected warning on missing LSP connection" unless app.lsp_warnings.any? { |entry| entry.includes?("LSP is not connected") }
      raise "current buffer should remain unchanged" unless app.current_buffer_path == source.to_s
    end
  end

  it "does not open LSP context actions when LSP client is absent" do
    with_temp_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "main.cr")
      File.write(source, "def one\nend\n")

      app = LspProtocolTestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(source)
      app.clear_lsp_client
      app.open_lsp_context_menu_public

      raise "context menu should stay closed when LSP is absent" if app.context_menu_open?
      raise "popup should stay closed when LSP is absent" if app.lsp_popup_open?
      raise "expected warning on missing LSP actions" unless app.lsp_warnings.any? { |entry| entry.includes?("No LSP actions available for this cursor") }
      raise "active editor should remain unchanged" unless app.current_buffer_path == source.to_s
    end
  end
end
