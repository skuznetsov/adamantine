require "spec"
require "file_utils"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private class ChatAppAdversaryHandle < Adamantine::Chat::Handle
  getter cancelled : Bool
  getter deliveries : Array({String, String})

  def initialize
    @cancelled = false
    @deliveries = [] of {String, String}
  end

  def cancel : Nil
    @cancelled = true
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    @deliveries << {call_id, result_json}
  end
end

private class ChatAppAdversaryTransport < Adamantine::Chat::Transport
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  getter handles : Array(ChatAppAdversaryHandle)

  def initialize
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
    @handles = [] of ChatAppAdversaryHandle
  end

  def available? : Bool
    true
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    @callbacks << on_event
    handle = ChatAppAdversaryHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class ChatAppAdversaryClipboard < Adamantine::Clipboard::Backend
  getter started : Channel(Nil)
  getter release : Channel(Nil)
  getter returned : Channel(Nil)
  @released = false

  def initialize(@text : String = "clipboard")
    @started = Channel(Nil).new(1)
    @release = Channel(Nil).new(1)
    @returned = Channel(Nil).new(1)
  end

  def read : Adamantine::Clipboard::Result
    @started.send(nil)
    @release.receive
    @returned.send(nil)
    Adamantine::Clipboard::Result.success(@text)
  end

  def write(text : String) : Adamantine::Clipboard::Result
    _ = text
    Adamantine::Clipboard::Result.success
  end

  def release_read : Nil
    return if @released
    @released = true
    @release.send(nil)
  end

  def await_read_start : Nil
    select
    when @started.receive
    when timeout(2.seconds)
      raise "clipboard backend did not start its delayed read"
    end
  end

  def await_read_return : Nil
    select
    when @returned.receive
    when timeout(2.seconds)
      raise "clipboard backend did not return its delayed read"
    end
  end
end

private class ChatAppAdversaryHarness < Adamantine::App
  @observed_sessions = [] of Adamantine::EditorTools::Session
  @test_wakeups = Channel(Nil).new(1)

  def open_tool_session(
    consumer : Adamantine::EditorTools::Consumer = Adamantine::EditorTools::Consumer::Chat,
    capabilities : Array(Adamantine::EditorTools::Capability) = [
      Adamantine::EditorTools::Capability::ReadEditor,
      Adamantine::EditorTools::Capability::ReadDebugger,
    ],
  ) : Adamantine::EditorTools::Session
    session = super(consumer, capabilities)
    @observed_sessions << session
    session
  end

  def wakeup : Nil
    select
    when @test_wakeups.send(nil)
    else
    end
  end

  def await_test_wakeup : Nil
    select
    when @test_wakeups.receive
    when timeout(2.seconds)
      raise "asynchronous callback did not wake the App owner"
    end
  end

  def discard_test_wakeups : Nil
    loop do
      select
      when @test_wakeups.receive
      else
        break
      end
    end
  end

  def layout_public(width : Int32 = 100, height : Int32 = 30) : Nil
    mount_headless(width, height)
    render(Tui::Buffer.new(width, height), Tui::Rect.new(0, 0, width, height))
  end

  def render_surface_public(width : Int32 = 100, height : Int32 = 30) : Tui::Buffer
    mount_headless(width, height)
    buffer = Tui::Buffer.new(width, height)
    render(buffer, Tui::Rect.new(0, 0, width, height))
    buffer
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def editor_widget_public : Tui::TextEditor?
    current_editor
  end

  def focused_widget_public : Tui::Widget?
    Tui::Widget.focused_widget
  end

  def command_palette_open_public? : Bool
    @command_palette.open
  end

  def open_lsp_modal_public : Nil
    open_lsp_popup("Test popup", ["modal owns input"] of String)
  end

  def close_lsp_modal_public : Nil
    close_lsp_popup
  end

  def lsp_modal_active_public? : Bool
    active_input_mode == InputMode::LspPopup
  end

  def clipboard_generation_public : UInt64
    @clipboard_paste_generation
  end

  def normal_mode_public? : Bool
    active_input_mode == InputMode::Normal
  end

  def root_retire_tools_public : Nil
    retire_editor_tools_context
  end

  def observed_sessions : Array(Adamantine::EditorTools::Session)
    @observed_sessions
  end

  def resize_before_paint_public(width : Int32, height : Int32) : Nil
    self.rect = Tui::Rect.new(0, 0, width, height)
    on_capture(Tui::ResizeEvent.new(width, height))
  end

  def drain_wakeup_public : Bool
    on_capture(Tui::WakeupEvent.new)
  end

  def close_test_resources : Nil
    quit(force: true)
    @clipboard.close
  end
end

private def with_chat_app_adversary_root(&)
  root = Path.new(Dir.tempdir, "adamantine-chat-app-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def prepare_chat_app(
  root : Path,
  clipboard : ChatAppAdversaryClipboard,
  transport : Adamantine::Chat::Transport = Adamantine::Chat::UnavailableTransport.new,
) : ChatAppAdversaryHarness
  path = root / "main.cr"
  File.write(path, "source\n")
  keymap = root / "keymap.json"
  File.write(keymap, "{}")
  app = ChatAppAdversaryHarness.new(
    project_root: root,
    lsp_command: "",
    keymap_path: keymap.to_s,
    clipboard_backend: clipboard,
    session_enabled: false,
    chat_transport: transport
  )
  app.layout_public
  app.open_file_public(path).should be_true
  app.layout_public
  app.chat_focus_action.should be_true
  raise "chat composer is not focused after chat focus" unless app.chat_panel.composer_focused?
  app
end

private def start_delayed_chat_paste(
  app : ChatAppAdversaryHarness,
  clipboard : ChatAppAdversaryClipboard,
) : Nil
  app.discard_test_wakeups
  handled = app.on_capture(Tui::KeyEvent.new('v', Tui::Modifiers::Ctrl))
  raise "Ctrl+V should be handled by the focused composer" unless handled
  clipboard.await_read_start
end

private def release_delayed_chat_paste(
  app : ChatAppAdversaryHarness,
  clipboard : ChatAppAdversaryClipboard,
) : Nil
  clipboard.release_read
  clipboard.await_read_return
  # The service invokes the queued callback immediately after Backend#read
  # returns. Allow that owner-independent callback to finish before delivering
  # the explicit owner wakeup below; App may also have unrelated wakeups queued.
  sleep 20.milliseconds
  app.discard_test_wakeups
end

describe "chat App asynchronous lifetime adversaries" do
  it "delivers an eligible delayed paste when no modal intervenes" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new("expected paste")
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard)
        app.not_nil!.normal_mode_public?.should be_true
        composer = app.not_nil!.chat_panel.composer
        composer.text = "draft"
        start_delayed_chat_paste(app.not_nil!, clipboard)
        release_delayed_chat_paste(app.not_nil!, clipboard)
        app.not_nil!.drain_wakeup_public.should be_true
        composer.text.should eq("expected pastedraft")
      ensure
        clipboard.release_read
        app.try(&.close_test_resources)
      end
    end
  end

  it "rejects a queued clipboard result after the command palette becomes modal" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new("should not paste")
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard)
        composer = app.not_nil!.chat_panel.composer
        composer.text = "preserved draft"
        start_delayed_chat_paste(app.not_nil!, clipboard)

        app.not_nil!.on_capture(Tui::KeyEvent.new(Tui::Key::F1)).should be_true
        app.not_nil!.command_palette_open_public?.should be_true
        release_delayed_chat_paste(app.not_nil!, clipboard)
        app.not_nil!.drain_wakeup_public.should be_true

        composer.text.should eq("preserved draft")
        app.not_nil!.command_palette_open_public?.should be_true
      ensure
        clipboard.release_read
        app.try(&.close_test_resources)
      end
    end
  end

  it "does not revive a delayed paste after a modal opens and closes before owner drain" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new("must stay stale")
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard)
        composer = app.not_nil!.chat_panel.composer
        composer.text = "preserved draft"
        start_delayed_chat_paste(app.not_nil!, clipboard)
        captured_generation = app.not_nil!.clipboard_generation_public

        # LSP popups enter the existing modal router without changing the
        # user's draft. Their lifetime fences clipboard callbacks captured
        # before the modal opened, even if the callback is retained until Chat
        # input resumes.
        app.not_nil!.open_lsp_modal_public
        app.not_nil!.lsp_modal_active_public?.should be_true
        modal_generation = app.not_nil!.clipboard_generation_public
        modal_generation.should be > captured_generation
        app.not_nil!.chat_panel.composer_focused?.should be_true
        release_delayed_chat_paste(app.not_nil!, clipboard)
        app.not_nil!.drain_wakeup_public.should be_true
        composer.text.should eq("preserved draft")

        app.not_nil!.close_lsp_modal_public
        app.not_nil!.lsp_modal_active_public?.should be_false
        app.not_nil!.clipboard_generation_public.should eq(modal_generation)
        app.not_nil!.chat_panel.composer_focused?.should be_true
        app.not_nil!.drain_wakeup_public.should be_true
        composer.text.should eq("preserved draft")
      ensure
        clipboard.release_read
        app.try(&.close_test_resources)
      end
    end
  end

  it "rejects a clipboard callback that arrives only after a modal opens and closes" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new("must remain stale")
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard)
        composer = app.not_nil!.chat_panel.composer
        composer.text = "unchanged draft"
        cursor_line = composer.cursor_line
        cursor_col = composer.cursor_col
        mutation_revision = composer.mutation_revision
        start_delayed_chat_paste(app.not_nil!, clipboard)
        captured_generation = app.not_nil!.clipboard_generation_public

        # No key event occurs here: opening and closing the existing modal
        # must invalidate an already captured clipboard target on their own.
        app.not_nil!.open_lsp_modal_public
        app.not_nil!.lsp_modal_active_public?.should be_true
        modal_generation = app.not_nil!.clipboard_generation_public
        modal_generation.should be > captured_generation
        app.not_nil!.close_lsp_modal_public
        app.not_nil!.lsp_modal_active_public?.should be_false
        app.not_nil!.clipboard_generation_public.should eq(modal_generation)
        app.not_nil!.chat_panel.composer_focused?.should be_true
        composer.text.should eq("unchanged draft")
        composer.cursor_line.should eq(cursor_line)
        composer.cursor_col.should eq(cursor_col)
        composer.mutation_revision.should eq(mutation_revision)

        # The async result is delivered only after the modal has closed, so a
        # Wakeup-only modal guard cannot satisfy this regression.
        release_delayed_chat_paste(app.not_nil!, clipboard)
        app.not_nil!.drain_wakeup_public.should be_true
        composer.text.should eq("unchanged draft")
        composer.cursor_line.should eq(cursor_line)
        composer.cursor_col.should eq(cursor_col)
      ensure
        clipboard.release_read
        app.try(&.close_test_resources)
      end
    end
  end

  it "rejects delayed paste after edit then undo restores the same composer text and cursor" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new("stale paste")
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard)
        composer = app.not_nil!.chat_panel.composer
        composer.text = "draft"
        before_line = composer.cursor_line
        before_col = composer.cursor_col
        start_delayed_chat_paste(app.not_nil!, clipboard)

        composer.insert_text("x")
        composer.undo.should be_true
        composer.set_cursor(before_line, before_col)
        composer.text.should eq("draft")
        composer.cursor_line.should eq(before_line)
        composer.cursor_col.should eq(before_col)

        release_delayed_chat_paste(app.not_nil!, clipboard)
        app.not_nil!.drain_wakeup_public.should be_true
        composer.text.should eq("draft")
      ensure
        clipboard.release_read
        app.try(&.close_test_resources)
      end
    end
  end

  it "rejects delayed paste across a same-text active-turn transition" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new("late clipboard")
      transport = ChatAppAdversaryTransport.new
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard, transport)
        composer = app.not_nil!.chat_panel.composer
        composer.text = "same visible text"
        before_revision = composer.mutation_revision
        start_delayed_chat_paste(app.not_nil!, clipboard)

        app.not_nil!.chat_frontend.submit.should be_true
        app.not_nil!.chat_frontend.active?.should be_true
        composer.text.should eq("same visible text")
        composer.mutation_revision.should eq(before_revision)

        release_delayed_chat_paste(app.not_nil!, clipboard)
        app.not_nil!.drain_wakeup_public.should be_true
        composer.text.should eq("same visible text")
      ensure
        clipboard.release_read
        app.try(&.close_test_resources)
      end
    end
  end

  it "renders streamed multiline assistant text with Unicode without byte-index slicing" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new
      transport = ChatAppAdversaryTransport.new
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard, transport)
        app.not_nil!.chat_panel.composer.text = "question"
        app.not_nil!.chat_panel.submit.should be_true
        transport.emit(0, Adamantine::Chat::Event.delta("first line\n第二行🙂"))
        transport.emit(0, Adamantine::Chat::Event.complete)
        app.not_nil!.chat_frontend.drain.should be_true

        surface = app.not_nil!.render_surface_public
        rendered_rows = (0...surface.height).map do |y|
          (0...surface.width).map { |x| surface.get(x, y).glyph }.join
        end
        rendered_rows.any?(&.includes?("Assistant: first line")).should be_true
        rendered_rows.map(&.gsub(" ", "")).any?(&.includes?("第二行🙂")).should be_true
      ensure
        app.try(&.close_test_resources)
      end
    end
  end

  it "retires the real host session and fences late tool/chat and clipboard callbacks at root retirement" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new("stale after root retirement")
      transport = ChatAppAdversaryTransport.new
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard, transport)
        composer = app.not_nil!.chat_panel.composer
        composer.text = "read the current file"
        start_delayed_chat_paste(app.not_nil!, clipboard)
        app.not_nil!.chat_frontend.submit.should be_true
        app.not_nil!.observed_sessions.size.should eq(1)
        session = app.not_nil!.observed_sessions.first
        session.closed?.should be_false
        composer.text = "keep this unsent draft"
        app.not_nil!.chat_frontend.draft.should eq("keep this unsent draft")

        app.not_nil!.root_retire_tools_public
        app.not_nil!.chat_frontend.active?.should be_false
        app.not_nil!.chat_frontend.messages.should be_empty
        app.not_nil!.chat_frontend.draft.should eq("keep this unsent draft")
        session.closed?.should be_true
        transport.handles.first.cancelled.should be_true

        transport.emit(0, Adamantine::Chat::Event.delta("stale assistant output"))
        app.not_nil!.await_test_wakeup
        app.not_nil!.drain_wakeup_public.should be_true
        app.not_nil!.chat_frontend.messages.should be_empty

        release_delayed_chat_paste(app.not_nil!, clipboard)
        app.not_nil!.drain_wakeup_public.should be_true
        composer.text.should eq("keep this unsent draft")
        app.not_nil!.chat_frontend.draft.should eq("keep this unsent draft")
      ensure
        clipboard.release_read
        app.try(&.close_test_resources)
      end
    end
  end

  it "returns focus to the visible editor when hiding Chat or resizing it below the split minimum" do
    with_chat_app_adversary_root do |root|
      clipboard = ChatAppAdversaryClipboard.new
      app : ChatAppAdversaryHarness? = nil
      begin
        app = prepare_chat_app(root, clipboard)
        editor = app.not_nil!.editor_widget_public
        raise "expected an opened editor" unless editor

        app.not_nil!.chat_panel.composer.text = "keep this draft"
        app.not_nil!.chat_panel.composer_focused?.should be_true
        app.not_nil!.chat_toggle_panel_action.should be_true
        app.not_nil!.chat_panel.composer_focused?.should be_false
        app.not_nil!.focused_widget_public.should eq(editor)
        app.not_nil!.chat_panel.composer.text.should eq("keep this draft")

        app.not_nil!.chat_focus_action.should be_true
        app.not_nil!.chat_panel.composer_focused?.should be_true
        app.not_nil!.resize_before_paint_public(100, 8)
        app.not_nil!.chat_panel.composer_focused?.should be_false
        app.not_nil!.focused_widget_public.should eq(editor)
        app.not_nil!.chat_panel.composer.text.should eq("keep this draft")
      ensure
        app.try(&.close_test_resources)
      end
    end
  end
end
