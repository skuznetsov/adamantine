require "crystal_tui"
require "digest/sha256"

require "./external_file_conflict"

module Adamantine
  class DocumentOrchestrator
    alias CurrentLspContext = NamedTuple(uri: String, line: Int32, character: Int32)?
    alias SaveExpectation = NamedTuple(digest: String, target: Path?)
    MAX_FILE_BYTES = 16 * 1024 * 1024

    class DigestSink < IO
      def initialize(@digest : Digest::SHA256)
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("digest sink is write-only")
      end

      def write(slice : Bytes) : Nil
        @digest.update(slice)
      end
    end

    def initialize(
      @document_session : DocumentSession,
      @editor_tabs : Tui::TabbedPanel,
      @status_log : Tui::Log,
      @focus_editor : Proc(Tui::TextEditor, Nil),
      @style_editor : Proc(Tui::TextEditor, OpenBuffer?, Nil),
      @configure_editor_lsp_styles : Proc(Tui::TextEditor, OpenBuffer, Nil),
      @detect_language : Proc(Path, String),
      @path_to_uri : Proc(Path, String),
      @uri_to_path : Proc(String, Path?),
      @update_header : Proc(Nil),
      @sync_open : Proc(OpenBuffer, Nil),
      @sync_change : Proc(OpenBuffer, Tui::TextEditor::TextChange, Nil),
      @sync_save : Proc(OpenBuffer, Nil),
      @close_lsp_document : Proc(String, Nil),
      @current_lsp_context : Proc(CurrentLspContext),
      @on_external_conflict : Proc(OpenBuffer, ExternalFileConflict, Nil) = ->(_buffer : OpenBuffer, _conflict : ExternalFileConflict) { },
    )
      @save_expectations = {} of String => SaveExpectation
      @external_file_monitor = ExternalFileMonitor.new(
        ->(event : ExternalFileMonitor::Event) do
          safe_invoke("external_file_event", event.path.to_s) { handle_external_file_event(event) }
        end,
        max_bytes: MAX_FILE_BYTES.to_i64
      )
    end

    def current_editor : Tui::TextEditor?
      if active = @editor_tabs.active_tab_id
        @document_session.open_buffers[active]?.try(&.editor)
      end
    end

    def current_buffer : OpenBuffer?
      if active = @editor_tabs.active_tab_id
        @document_session.open_buffers[active]?
      end
    end

    def move_editor_cursor(editor : Tui::TextEditor, line : Int32, character : Int32) : Nil
      editor.set_cursor(line, character)
    end

    def focus_active_editor : Nil
      if editor = current_editor
        @focus_editor.call(editor)
      end
    end

    def switch_to_next_tab : Nil
      tab_count = @editor_tabs.tabs.size
      if tab_count < 1
        @status_log.warning("No open tabs")
        return
      end

      next_tab = (@editor_tabs.active_tab + 1) % tab_count
      @editor_tabs.active_tab = next_tab
      focus_active_editor
      @update_header.call
    end

    def switch_to_previous_tab : Nil
      tab_count = @editor_tabs.tabs.size
      if tab_count < 1
        @status_log.warning("No open tabs")
        return
      end

      prev_tab = @editor_tabs.active_tab - 1
      prev_tab = tab_count - 1 if prev_tab < 0
      @editor_tabs.active_tab = prev_tab
      focus_active_editor
      @update_header.call
    end

    def switch_to_tab_by_position(position : Int32) : Nil
      tab_count = @editor_tabs.tabs.size
      if position < 0 || position >= tab_count
        if tab_count > 0
          @status_log.warning("No tab at position #{position + 1}")
        else
          @status_log.warning("No open tabs")
        end
        return
      end

      @editor_tabs.active_tab = position
      focus_active_editor
      @update_header.call
    end

    def switch_to_tab_by_position_buffer(path_str : String) : Nil
      return if @document_session.open_buffers.empty?
      return unless @document_session.open_buffers[path_str]?

      @editor_tabs.switch_to(path_str)
      focus_active_editor
      @update_header.call
    end

    def open_file(path : Path, cursor_line : Int32? = nil, cursor_character : Int32? = nil) : Bool
      path_str = path.to_s

      if existing = @document_session.open_buffers[path_str]?
        safe_invoke("style_editor", path_str) do
          @style_editor.call(existing.editor, existing)
        end
        @editor_tabs.switch_to(path_str)
        if cursor_line && cursor_character
          move_editor_cursor(existing.editor, cursor_line, cursor_character)
        end
        @update_header.call
        focus_active_editor
        return true
      end

      snapshot = FileRevision.read(path, max_bytes: MAX_FILE_BYTES.to_i64)
      unless snapshot.stable?
        log_open_snapshot_failure(path, snapshot)
        return false
      end

      content = snapshot.content
      revision = snapshot.revision
      unless content && revision && text_content?(content.not_nil!)
        @status_log.warning("Refusing to open non-text file #{path}")
        return false
      end

      editor = Tui::TextEditor.new(path_str)
      loaded = editor.load_content_as_saved(content.not_nil!, path)
      unless loaded
        @status_log.error("Failed to open #{path}")
        return false
      end
      safe_invoke("style_editor", path_str) do
        @style_editor.call(editor, nil)
      end

      language = @detect_language.call(path)
      uri = @path_to_uri.call(path)

      buffer = OpenBuffer.new(path, editor, language, uri)
      buffer.disk_revision = revision.not_nil!
      buffer.watch_token = @external_file_monitor.watch(path, baseline: revision.not_nil!)
      safe_invoke("configure_editor_lsp_styles", path_str) do
        @configure_editor_lsp_styles.call(editor, buffer)
      end
      @document_session.open_buffers[path_str] = buffer

      editor.on_text_change do |change|
        if local_buffer = @document_session.open_buffers[path_str]?
          local_buffer.version += 1
          rename_tab(local_buffer)
          safe_invoke("sync_change", path_str) do
            @sync_change.call(local_buffer, change)
          end
          @update_header.call
        end
      end

      editor.on_save do |saved_path|
        if local_buffer = @document_session.open_buffers[path_str]?
          safe_invoke("sync_save", path_str) do
            @sync_save.call(local_buffer)
          end
          @status_log.success("Saved #{saved_path.basename}")
          rename_tab(local_buffer)
          @update_header.call
        end
      end

      @editor_tabs.add_tab(path_str, file_tab_label(buffer)) { editor }
      @editor_tabs.switch_to(path_str)

      safe_invoke("sync_open", path_str) do
        @sync_open.call(buffer)
      end
      if cursor_line && cursor_character
        move_editor_cursor(editor, cursor_line, cursor_character)
      end
      @focus_editor.call(editor)
      @update_header.call
      true
    end

    private def text_content?(content : String) : Bool
      content.valid_encoding? && !content.to_slice.includes?(0_u8)
    end

    private def log_open_snapshot_failure(path : Path, snapshot : FileRevision::Result) : Nil
      case snapshot.status
      when FileRevision::Status::TooLarge
        @status_log.warning("Refusing to open large file #{path}: limit is #{MAX_FILE_BYTES} bytes")
      when FileRevision::Status::Missing
        @status_log.warning("File does not exist: #{path}")
      when FileRevision::Status::NonRegular
        @status_log.warning("Refusing to open non-regular file #{path}")
      else
        @status_log.warning("Failed to read stable file snapshot #{path}")
      end
    end

    def close_tab(tab_id : String) : Nil
      if buffer = @document_session.open_buffers.delete(tab_id)
        if token = buffer.watch_token
          @external_file_monitor.unwatch(token)
        end
        @save_expectations.delete(tab_id)
        safe_invoke("close_lsp_document", buffer.uri) do
          @close_lsp_document.call(buffer.uri)
        end
        @status_log.info("Closed: #{buffer.path.basename}")
      end
      @update_header.call
    end

    def can_close_tab?(tab_id : String) : Bool
      if buffer = @document_session.open_buffers[tab_id]?
        if buffer.editor.modified? || buffer.external_conflict
          reason = buffer.external_conflict ? "Unresolved external change" : "Unsaved changes"
          @status_log.warning("#{reason} in #{buffer.path.basename}; use :q! to force quit")
          return false
        end
      end
      true
    end

    def close_active_tab : Bool
      if active_tab_id = @editor_tabs.active_tab_id
        return false unless can_close_tab?(active_tab_id)

        closed = @editor_tabs.close_active_tab
        @update_header.call if @document_session.open_buffers.empty?
        return closed
      else
        @status_log.warning("No active editor")
      end

      @update_header.call if @document_session.open_buffers.empty?
      false
    end

    def save_active : Bool
      buffer = current_buffer
      unless buffer
        @status_log.warning("No active editor")
        return false
      end

      if conflict = buffer.external_conflict
        @status_log.warning("#{buffer.path.basename} changed outside Adamantine; choose a conflict action")
        notify_external_conflict(buffer, conflict)
        return false
      end

      save_buffer(buffer, nil)
    end

    def poll_external_files : Int32
      @external_file_monitor.poll
    rescue ex
      @status_log.warning("External file monitor failed: #{ex.message || ex.class}")
      0
    end

    def start_external_file_monitor(interval : Time::Span = 500.milliseconds) : Bool
      @external_file_monitor.start(interval)
    end

    def stop_external_file_monitor : Bool
      @external_file_monitor.stop
    end

    def unresolved_external_conflicts? : Bool
      @document_session.open_buffers.each_value.any? { |buffer| !buffer.external_conflict.nil? }
    end

    def resolve_external_conflict(
      tab_id : String,
      watch_token : ExternalFileMonitor::WatchToken,
      generation : UInt64,
      action : ExternalConflictAction,
    ) : Bool
      buffer = @document_session.open_buffers[tab_id]?
      return false unless buffer
      conflict = current_external_conflict(buffer, watch_token, generation)
      unless conflict
        @status_log.warning("External file action is stale for #{buffer.path.basename}")
        if latest = buffer.external_conflict
          notify_external_conflict(buffer, latest)
        end
        return false
      end

      case action
      when ExternalConflictAction::Reload
        reload_external_file(buffer, conflict)
      when ExternalConflictAction::Keep
        @status_log.info("Kept in-memory version of #{buffer.path.basename}; disk conflict remains unresolved")
        rename_tab(buffer)
        @update_header.call
        true
      when ExternalConflictAction::Overwrite
        overwrite_external_file(buffer, conflict)
      else
        false
      end
    end

    private def save_buffer(buffer : OpenBuffer, conflict : ExternalFileConflict?) : Bool
      editor = buffer.editor
      path_str = buffer.path.to_s
      baseline = buffer.disk_revision
      token = buffer.watch_token
      unless baseline && token
        @status_log.warning("Cannot verify disk baseline for #{buffer.path.basename}")
        return false
      end

      digest = editor_digest(editor)
      @save_expectations[path_str] = {digest: digest, target: nil}
      check_result : FileRevision::Result? = nil
      accepted_revision : FileRevision? = nil

      before_rename = ->(target : Path) do
        current = FileRevision.capture(buffer.path, max_bytes: MAX_FILE_BYTES.to_i64)
        check_result = current
        authorized = if conflict
                       overwrite_candidate_matches?(conflict, current)
                     else
                       accepted_revision_matches?(baseline, current)
                     end
        if authorized
          @save_expectations[path_str] = {digest: digest, target: target}
        end
        authorized
      end

      after_rename = ->(target : Path) do
        current = FileRevision.capture(buffer.path, max_bytes: MAX_FILE_BYTES.to_i64)
        check_result = current
        revision = current.revision
        authorized = !!revision && own_save_matches?(revision.not_nil!, digest, target)
        if authorized
          accepted_revision = revision.not_nil!
          buffer.disk_revision = revision.not_nil!
          @external_file_monitor.acknowledge(token, revision.not_nil!)
          buffer.external_conflict = nil
        end
        authorized
      end

      saved = editor.save_checked(before_rename, after_rename)

      unless saved
        replacement_started = !@save_expectations[path_str][:target].nil?
        @save_expectations.delete(path_str)
        publish_save_mismatch(buffer, check_result) if check_result
        if check_result && replacement_started
          @status_log.warning("#{buffer.path.basename} changed again immediately after save")
        end
        @status_log.warning("Failed to save #{buffer.path}")
        return false
      end

      return false unless accepted_revision
      rename_tab(buffer)
      @update_header.call
      true
    rescue ex
      @save_expectations.delete(path_str) if path_str
      @status_log.warning("Failed to save #{buffer.path}: #{ex.message || ex.class}")
      false
    ensure
      @save_expectations.delete(path_str) if path_str
    end

    private def reload_external_file(buffer : OpenBuffer, conflict : ExternalFileConflict) : Bool
      expected = conflict.event.current
      unless expected.stable?
        @status_log.warning("Cannot reload #{buffer.path.basename}: external file is #{external_status_label(expected.status)}")
        return false
      end

      snapshot = FileRevision.read(
        buffer.path,
        max_bytes: MAX_FILE_BYTES.to_i64,
        expected_stamp: expected.stamp
      )
      unless exact_observation?(expected, snapshot)
        publish_save_mismatch(buffer, snapshot)
        @status_log.warning("#{buffer.path.basename} changed again before reload")
        return false
      end

      content = snapshot.content
      revision = snapshot.revision
      unless content && revision && text_content?(content.not_nil!)
        @status_log.warning("Cannot reload non-text content from #{buffer.path.basename}")
        return false
      end

      content_changed = editor_digest(buffer.editor) != revision.not_nil!.digest
      if content_changed
        buffer.editor.reload_as_saved(content.not_nil!, buffer.path)
      else
        buffer.editor.accept_current_as_saved(buffer.path)
      end
      buffer.disk_revision = revision.not_nil!
      if token = buffer.watch_token
        @external_file_monitor.acknowledge(token, revision.not_nil!)
      end
      buffer.external_conflict = nil
      rename_tab(buffer)
      @update_header.call
      if content_changed
        @status_log.info("Reloaded #{buffer.path.basename} from disk; previous editor state is available via undo")
      else
        @status_log.info("Accepted unchanged bytes for #{buffer.path.basename} as the current disk revision")
      end
      true
    rescue ex
      @status_log.warning("Failed to reload #{buffer.path.basename}: #{ex.message || ex.class}")
      false
    end

    private def overwrite_external_file(buffer : OpenBuffer, conflict : ExternalFileConflict) : Bool
      status = conflict.event.current.status
      unless status.in?(FileRevision::Status::Stable, FileRevision::Status::Missing)
        @status_log.warning("Cannot overwrite #{buffer.path.basename} while the path is #{external_status_label(status)}")
        return false
      end
      save_buffer(buffer, conflict)
    end

    private def editor_digest(editor : Tui::TextEditor) : String
      digest = Digest::SHA256.new
      editor.write_to(DigestSink.new(digest))
      digest.hexfinal
    end

    private def own_save_matches?(revision : FileRevision, expected_digest : String, expected_target : Path) : Bool
      canonical_target = File.realpath(expected_target)
      revision.digest == expected_digest && revision.stamp.resolved_target == canonical_target
    rescue
      false
    end

    private def accepted_revision_matches?(baseline : FileRevision, current : FileRevision::Result) : Bool
      revision = current.revision
      return false unless revision
      baseline.digest == revision.not_nil!.digest && baseline.stamp.same_target?(revision.not_nil!.stamp)
    end

    private def overwrite_candidate_matches?(conflict : ExternalFileConflict, current : FileRevision::Result) : Bool
      exact_observation?(conflict.event.current, current)
    end

    private def exact_observation?(expected : FileRevision::Result, current : FileRevision::Result) : Bool
      return false unless expected.status == current.status
      if expected.stable?
        expected_revision = expected.revision
        current_revision = current.revision
        return false unless expected_revision && current_revision
        expected_revision.not_nil!.digest == current_revision.not_nil!.digest &&
          expected_revision.not_nil!.stamp.same_as?(current_revision.not_nil!.stamp)
      else
        expected.stamp.same_as?(current.stamp)
      end
    end

    private def publish_save_mismatch(buffer : OpenBuffer, fallback : FileRevision::Result?) : Nil
      token = buffer.watch_token
      return unless token
      generation = buffer.external_conflict_generation
      @external_file_monitor.force_recheck(token)
      return if buffer.external_conflict_generation != generation
      return unless fallback

      event = external_event_for(buffer, token, fallback)
      handle_external_file_event(event) if event
    end

    private def external_event_for(
      buffer : OpenBuffer,
      token : ExternalFileMonitor::WatchToken,
      current : FileRevision::Result,
    ) : ExternalFileMonitor::Event?
      baseline = buffer.disk_revision
      return nil unless baseline
      previous = revision_result(buffer.path, baseline)
      ExternalFileMonitor.event_for(token, previous, current)
    end

    private def revision_result(path : Path, revision : FileRevision) : FileRevision::Result
      FileRevision::Result.new(
        path,
        FileRevision::Status::Stable,
        nil,
        revision,
        revision.stamp,
        revision.stamp
      )
    end

    private def current_external_conflict(
      buffer : OpenBuffer,
      watch_token : ExternalFileMonitor::WatchToken,
      generation : UInt64,
    ) : ExternalFileConflict?
      conflict = buffer.external_conflict
      return nil unless conflict
      return nil unless buffer.watch_token == watch_token
      return nil unless conflict.not_nil!.watch_token == watch_token
      return nil unless conflict.not_nil!.generation == generation
      conflict
    end

    private def handle_external_file_event(event : ExternalFileMonitor::Event) : Nil
      buffer = @document_session.open_buffers[event.path.to_s]?
      return unless buffer
      return unless buffer.watch_token == event.token
      return if expected_own_save_event?(buffer, event)

      # The monitor advances through observed candidates independently from
      # the last revision accepted by the editor. If an in-place writer moves
      # A -> B -> A, invalidate stale dialog actions and clear the conflict
      # instead of treating the accepted BASE as a new external candidate.
      if baseline = buffer.disk_revision
        if accepted_revision_matches?(baseline, event.current)
          buffer.external_conflict_generation &+= 1_u64
          buffer.disk_revision = event.current.revision.not_nil!
          buffer.external_conflict = nil
          rename_tab(buffer)
          @update_header.call
          @status_log.info("#{buffer.path.basename} returned to the accepted disk revision")
          return
        end
      end

      buffer.external_conflict_generation &+= 1_u64
      conflict = ExternalFileConflict.new(event, buffer.external_conflict_generation)
      buffer.external_conflict = conflict
      rename_tab(buffer)
      @update_header.call
      @status_log.warning("#{buffer.path.basename} changed outside Adamantine (#{external_event_label(event.kind)})")
      notify_external_conflict(buffer, conflict)
    end

    private def expected_own_save_event?(buffer : OpenBuffer, event : ExternalFileMonitor::Event) : Bool
      expectation = @save_expectations[buffer.path.to_s]?
      return false unless expectation
      target = expectation[:target]
      revision = event.revision
      return false unless target && revision
      own_save_matches?(revision.not_nil!, expectation[:digest], target.not_nil!)
    end

    private def notify_external_conflict(buffer : OpenBuffer, conflict : ExternalFileConflict) : Nil
      safe_invoke("external_file_conflict", buffer.path.to_s) do
        @on_external_conflict.call(buffer, conflict)
      end
    end

    private def external_event_label(kind : ExternalFileMonitor::Event::Kind) : String
      case kind
      when ExternalFileMonitor::Event::Kind::Changed           then "content changed"
      when ExternalFileMonitor::Event::Kind::Deleted           then "deleted"
      when ExternalFileMonitor::Event::Kind::Unreadable        then "unreadable"
      when ExternalFileMonitor::Event::Kind::NonRegular        then "not a regular file"
      when ExternalFileMonitor::Event::Kind::Replaced          then "replaced"
      when ExternalFileMonitor::Event::Kind::SymlinkRetargeted then "symlink retargeted"
      when ExternalFileMonitor::Event::Kind::TooLarge          then "exceeds the size limit"
      else                                                          kind.to_s
      end
    end

    private def external_status_label(status : FileRevision::Status) : String
      status.to_s.underscore.gsub('_', ' ')
    end

    def jump_back : Nil
      if @document_session.navigation_history.empty?
        @status_log.warning("No navigation history")
        return
      end

      current = @current_lsp_context.call
      if current
        @document_session.navigation_forward_history << NavigationLocation.new(current[:uri], current[:line], current[:character])
      end

      last = @document_session.navigation_history.pop
      path = resolve_navigation_path(last.uri)
      unless path
        @document_session.navigation_history << last
        @document_session.navigation_forward_history.pop? if current
        @status_log.warning("Cannot resolve navigation URI #{last.uri}")
        return
      end

      unless open_file(path, last.line, last.character)
        @document_session.navigation_history << last
        @document_session.navigation_forward_history.pop? if current
        @status_log.error("Failed to restore #{path}")
        return
      end

      prune_navigation_forward_history
    end

    def jump_forward : Nil
      if @document_session.navigation_forward_history.empty?
        @status_log.warning("No navigation forward history")
        return
      end

      current = @current_lsp_context.call
      if current
        @document_session.navigation_history << NavigationLocation.new(current[:uri], current[:line], current[:character])
      end

      next_location = @document_session.navigation_forward_history.pop
      path = resolve_navigation_path(next_location.uri)
      unless path
        @document_session.navigation_forward_history << next_location
        @document_session.navigation_history.pop? if current
        @status_log.warning("Cannot resolve navigation URI #{next_location.uri}")
        return
      end

      unless open_file(path, next_location.line, next_location.character)
        @document_session.navigation_forward_history << next_location
        @document_session.navigation_history.pop? if current
        @status_log.error("Failed to restore #{path}")
        return
      end

      prune_navigation_history
      prune_navigation_forward_history
    end

    def prune_navigation_forward_history : Nil
      history = @document_session.navigation_forward_history
      limit = @document_session.navigation_history_limit
      return if history.size <= limit
      history.shift(history.size - limit)
    end

    def prune_navigation_history : Nil
      history = @document_session.navigation_history
      limit = @document_session.navigation_history_limit
      return if history.size <= limit
      history.shift(history.size - limit)
    end

    def configure_editor_lsp_styles(editor : Tui::TextEditor, buffer : OpenBuffer) : Nil
      @configure_editor_lsp_styles.call(editor, buffer)
    end

    def uri_to_path(uri : String) : Path?
      @uri_to_path.call(uri)
    end

    private def resolve_navigation_path(uri : String) : Path?
      @uri_to_path.call(uri)
    rescue
      nil
    end

    def file_tab_label(buffer : OpenBuffer?) : String
      return "unnamed" unless buffer
      modified = buffer.editor.modified? ? "*" : ""
      external = buffer.external_conflict ? "!" : ""
      "#{buffer.path.basename}#{modified}#{external}"
    end

    def rename_tab(buffer : OpenBuffer) : Nil
      @editor_tabs.rename_tab(buffer.path.to_s, file_tab_label(buffer))
    end

    private def safe_invoke(label : String, path : String, &)
      yield
    rescue ex
      message = ex.message || ex.class.to_s
      @status_log.warning("Orchestrator callback failed (#{label}) for #{path}: #{message}")
    end
  end
end
