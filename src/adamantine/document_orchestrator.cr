require "crystal_tui"
require "digest/sha256"

require "./external_file_conflict"
require "./editing_text_editor"
require "./external_change_review"

module Adamantine
  class DocumentOrchestrator
    alias CurrentLspContext = NamedTuple(uri: String, line: Int32, character: Int32)?
    alias SaveExpectation = NamedTuple(digest: String, target: Path?)
    # Resolves a requested cursor against the editor that open_file is about
    # to commit.  LSP navigation uses this hook so UTF-16 coordinates are
    # never converted against a separate, stale file read.
    alias CursorResolver = Proc(Tui::TextEditor, Tuple(Int32, Int32)?)
    MAX_FILE_BYTES = 16 * 1024 * 1024

    @active_tabs_provider : Proc(Tui::TabbedPanel)?
    @tabs_for_path_provider : Proc(String, Tui::TabbedPanel?)?
    @activate_tabs : Proc(Tui::TabbedPanel, Nil)?
    @editor_groups_provider : Proc(Array(Tui::TabbedPanel))?

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

    # The App may present the same document session through more than one tab
    # group. Keep the constructor's original panel as the single-group
    # fallback so existing orchestrator clients retain their behavior.
    def configure_editor_groups(
      active_tabs : Proc(Tui::TabbedPanel),
      tabs_for_path : Proc(String, Tui::TabbedPanel?),
      activate_tabs : Proc(Tui::TabbedPanel, Nil),
      editor_groups : Proc(Array(Tui::TabbedPanel))? = nil,
    ) : Nil
      @active_tabs_provider = active_tabs
      @tabs_for_path_provider = tabs_for_path
      @activate_tabs = activate_tabs
      @editor_groups_provider = editor_groups
    end

    private def editor_tabs : Tui::TabbedPanel
      @active_tabs_provider.try(&.call) || @editor_tabs
    end

    def current_editor : Tui::TextEditor?
      tabs = editor_tabs
      if active = tabs.active_tab_id
        editor_for_tab(tabs, active)
      end
    end

    # Install callbacks that depend on the fully constructed App only after
    # its orchestrator has been assigned.
    def on_change(&@sync_change : OpenBuffer, Tui::TextEditor::TextChange -> Nil) : Nil
    end

    def current_buffer : OpenBuffer?
      if active = editor_tabs.active_tab_id
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
      tabs = editor_tabs
      tab_count = tabs.tabs.size
      if tab_count < 1
        @status_log.warning("No open tabs")
        return
      end

      next_tab = (tabs.active_tab + 1) % tab_count
      tabs.active_tab = next_tab
      focus_active_editor
      @update_header.call
    end

    def switch_to_previous_tab : Nil
      tabs = editor_tabs
      tab_count = tabs.tabs.size
      if tab_count < 1
        @status_log.warning("No open tabs")
        return
      end

      prev_tab = tabs.active_tab - 1
      prev_tab = tab_count - 1 if prev_tab < 0
      tabs.active_tab = prev_tab
      focus_active_editor
      @update_header.call
    end

    def switch_to_tab_by_position(position : Int32) : Nil
      tabs = editor_tabs
      tab_count = tabs.tabs.size
      if position < 0 || position >= tab_count
        if tab_count > 0
          @status_log.warning("No tab at position #{position + 1}")
        else
          @status_log.warning("No open tabs")
        end
        return
      end

      tabs.active_tab = position
      focus_active_editor
      @update_header.call
    end

    def switch_to_tab_by_position_buffer(path_str : String) : Nil
      return if @document_session.open_buffers.empty?
      return unless @document_session.open_buffers[path_str]?

      tabs = editor_tabs
      tabs = @tabs_for_path_provider.try(&.call(path_str)) || tabs unless editor_for_tab(tabs, path_str)
      @activate_tabs.try(&.call(tabs))
      tabs.switch_to(path_str)
      focus_active_editor
      @update_header.call
    end

    def open_file(
      path : Path,
      cursor_line : Int32? = nil,
      cursor_character : Int32? = nil,
      guard : Proc(Bool)? = nil,
      on_commit : Proc(Nil)? = nil,
      cursor_resolver : CursorResolver? = nil,
      max_bytes : Int64? = nil,
      expected_stamp : FileRevision::Stamp? = nil,
    ) : Bool
      return false if guard && !guard.call

      read_limit = if requested = max_bytes
                     requested.clamp(0_i64, MAX_FILE_BYTES.to_i64)
                   else
                     MAX_FILE_BYTES.to_i64
                   end

      path_str = path.to_s
      resolved_cursor : Tuple(Int32, Int32)? = nil

      if existing = @document_session.open_buffers[path_str]?
        tabs = editor_tabs
        if view = editor_for_tab(tabs, path_str)
          safe_invoke("style_editor", path_str) do
            @style_editor.call(view, existing)
          end
          return false if guard && !guard.call

          if resolver = cursor_resolver
            resolved_cursor = resolver.call(view)
            return false if resolved_cursor.nil?
          elsif cursor_line && cursor_character
            resolved_cursor = {cursor_line, cursor_character}
          end

          # Resolve against the view in the active group before the tab
          # switch, then seal the guard immediately before UI mutation.
          return false if guard && !guard.call
          tabs.switch_to(path_str)
          if cursor = resolved_cursor
            move_editor_cursor(view, cursor[0], cursor[1])
          end
          @update_header.call
          @focus_editor.call(view)
          on_commit.try(&.call)
          return true
        end

        # A path can have one tab per editor group while retaining a single
        # document, file watch, and LSP lifecycle.  The current group gets a
        # lightweight view over the already-open document.
        view = EditingTextEditor.new(path_str, existing.editor.document)
        safe_invoke("style_editor", path_str) do
          @style_editor.call(view, existing)
        end
        safe_invoke("configure_editor_lsp_styles", path_str) do
          @configure_editor_lsp_styles.call(view, existing)
        end
        if guard && !guard.call
          view.detach
          return false
        end

        if resolver = cursor_resolver
          resolved_cursor = resolver.call(view)
          unless resolved_cursor
            view.detach
            return false
          end
        elsif cursor_line && cursor_character
          resolved_cursor = {cursor_line, cursor_character}
        end

        # The new view remains detached from UI and session state until the
        # guarded request is sealed.  It never opens a second LSP document.
        unless !guard || guard.call
          view.detach
          return false
        end
        tabs.add_tab(path_str, file_tab_label(existing)) { view }
        existing.add_view(view)
        tabs.switch_to(path_str)
        if cursor = resolved_cursor
          move_editor_cursor(view, cursor[0], cursor[1])
        end
        @focus_editor.call(view)
        @update_header.call
        on_commit.try(&.call)
        return true
      end

      snapshot = FileRevision.read(path, max_bytes: read_limit, expected_stamp: expected_stamp)
      return false if guard && !guard.call

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

      editor = EditingTextEditor.new(path_str)
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
      buffer.version = @document_session.allocate_buffer_version
      buffer.disk_revision = revision.not_nil!
      safe_invoke("configure_editor_lsp_styles", path_str) do
        @configure_editor_lsp_styles.call(editor, buffer)
      end

      if resolver = cursor_resolver
        resolved_cursor = resolver.call(editor)
        return false if resolved_cursor.nil?
      elsif cursor_line && cursor_character
        resolved_cursor = {cursor_line, cursor_character}
      end

      # Seal the guarded request immediately before mutating the document
      # session and committing the new tab. The commit callback below then
      # runs before sync_open, which may yield in the transport.
      return false if guard && !guard.call
      buffer.watch_token = @external_file_monitor.watch(path, baseline: revision.not_nil!)
      @document_session.open_buffers[path_str] = buffer

      editor.document.on_text_change do |change|
        if local_buffer = @document_session.open_buffers[path_str]?
          if local_buffer.same?(buffer)
            local_buffer.version += 1
            rename_tab(local_buffer)
            safe_invoke("sync_change", path_str) do
              @sync_change.call(local_buffer, change)
            end
            @update_header.call
          end
        end
      end

      editor.document.on_save do |saved_path|
        if local_buffer = @document_session.open_buffers[path_str]?
          if local_buffer.same?(buffer)
            safe_invoke("sync_save", path_str) do
              @sync_save.call(local_buffer)
            end
            @status_log.success("Saved #{saved_path.basename}")
            rename_tab(local_buffer)
            @update_header.call
          end
        end
      end

      tabs = editor_tabs
      tabs.add_tab(path_str, file_tab_label(buffer)) { editor }
      tabs.switch_to(path_str)

      if cursor = resolved_cursor
        move_editor_cursor(editor, cursor[0], cursor[1])
      end
      @focus_editor.call(editor)
      @update_header.call
      on_commit.try(&.call)

      # Keep the UI commit ahead of transport work: sync_open may yield while
      # the server consumes the document, and no stale-response guard can
      # undo a tab/cursor commit after that boundary.
      safe_invoke("sync_open", path_str) do
        @sync_open.call(buffer)
      end
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

    def close_tab(tab_id : String, closed_view : Tui::TextEditor? = nil) : Nil
      if buffer = @document_session.open_buffers[tab_id]?
        view_to_close = closed_view || buffer.editor
        remove_tab_for_view(tab_id, view_to_close) unless closed_view
        buffer.remove_view(view_to_close)
        view_to_close.detach
        unless buffer.views.empty?
          # OpenBuffer.editor is the canonical live-view anchor used by
          # existing document consumers. remove_view promotes a survivor if
          # the canonical widget was the one detached.
          rename_tab(buffer)
          @status_log.info("Closed view: #{buffer.path.basename}")
          @update_header.call
          return
        end

        @document_session.open_buffers.delete(tab_id)
        @document_session.retire_buffer_version(buffer.version)
        if token = buffer.watch_token
          @external_file_monitor.unwatch(token)
        end
        @save_expectations.delete(tab_id)
        safe_invoke("close_lsp_document", tab_id) do
          @close_lsp_document.call(buffer.uri)
        end
        @status_log.info("Closed: #{buffer.path.basename}")
      end
      @update_header.call
    end

    def editor_views_for(buffer : OpenBuffer) : Array(Tui::TextEditor)
      @document_session.views_for(buffer)
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
      tabs = editor_tabs
      if active_tab_id = tabs.active_tab_id
        return false unless can_close_tab?(active_tab_id)

        closed = tabs.close_active_tab
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

      save_target(buffer)
    end

    def save_target(buffer : OpenBuffer) : Bool
      unless @document_session.open_buffers[buffer.path.to_s]?.try(&.same?(buffer))
        @status_log.warning("Refusing stale save target for #{buffer.path.basename}")
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

    # Capture the exact OURS/editor state and a bounded disk observation for
    # an explicit inline external-change review.  The read may yield;
    # the captured version/token/generation therefore remain mandatory guards
    # at apply time rather than being treated as a live snapshot.
    def prepare_external_review(buffer : OpenBuffer) : ExternalChangeReview?
      live = @document_session.open_buffers[buffer.path.to_s]?
      return nil unless live && live.same?(buffer)
      conflict = buffer.external_conflict
      token = buffer.watch_token
      return nil unless conflict && token

      editor = buffer.editor
      source = editor.is_a?(EditingTextEditor) ? editor.external_review_source : nil
      return nil unless source

      version = buffer.version
      generation = conflict.not_nil!.generation
      event = conflict.not_nil!.event
      disk = FileRevision.read(
        buffer.path,
        max_bytes: MAX_FILE_BYTES.to_i64,
        expected_stamp: event.current.stamp
      )

      observation_matches = exact_observation?(event.current, disk)
      preview : InlineEditPreview::Model? = nil
      if observation_matches && disk.stable?
        if content = disk.content
          if text_content?(content)
            candidate = Tui::PieceTreeBuffer.new(content)
            span = InlineEditPreview::EditSpan.new(
              0,
              source.line_count,
              0,
              candidate.line_count
            )
            preview = InlineEditPreview::Model.new(
              source,
              candidate,
              [span],
              "External change: Editor vs Disk"
            )
          end
        end
      end

      preview_status = if !observation_matches
                         "unavailable: disk changed during capture"
                       elsif preview
                         "available"
                       elsif disk.stable?
                         "unavailable: non-text content"
                       else
                         "unavailable: #{external_status_label(disk.status)}"
                       end

      ExternalChangeReview.new(
        buffer,
        editor,
        version,
        token.not_nil!,
        generation,
        event,
        disk,
        external_event_label(event.kind),
        external_status_label(disk.status),
        preview_status,
        preview
      )
    rescue ex
      @status_log.warning("Failed to prepare external review for #{buffer.path.basename}: #{ex.message || ex.class}")
      nil
    end

    # Apply only an authority capture which still names the same open buffer,
    # editor version, watch token, conflict generation and disk fingerprint.
    # Reload/overwrite re-read the path themselves; their guards are checked
    # again after those yielding reads and immediately before mutation.
    def apply_external_review(review : ExternalChangeReview, action : ExternalConflictAction) : Bool
      buffer = review.buffer
      unless external_review_current?(review)
        @status_log.warning("External review is stale for #{buffer.path.basename}")
        if latest = buffer.external_conflict
          notify_external_conflict(buffer, latest)
        end
        return false
      end

      conflict = current_external_conflict(buffer, review.watch_token, review.conflict_generation)
      return false unless conflict

      case action
      when ExternalConflictAction::Reload
        reload_external_file(buffer, conflict, review)
      when ExternalConflictAction::Keep
        @status_log.info("Kept in-memory version of #{buffer.path.basename}; disk conflict remains unresolved")
        rename_tab(buffer)
        @update_header.call
        true
      when ExternalConflictAction::Overwrite
        overwrite_external_file(buffer, conflict, review)
      else
        false
      end
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

    private def save_buffer(
      buffer : OpenBuffer,
      conflict : ExternalFileConflict?,
      review : ExternalChangeReview? = nil,
    ) : Bool
      editor = buffer.editor
      path_str = buffer.path.to_s
      baseline = buffer.disk_revision
      token = buffer.watch_token
      unless baseline && token
        @status_log.warning("Cannot verify disk baseline for #{buffer.path.basename}")
        return false
      end

      return false if review && !external_review_current?(review.not_nil!)

      action_generation = buffer.external_conflict_generation

      digest = editor_digest(editor)
      @save_expectations[path_str] = {digest: digest, target: nil}
      check_result : FileRevision::Result? = nil
      accepted_revision : FileRevision? = nil

      before_rename = ->(target : Path) do
        current = FileRevision.capture(buffer.path, max_bytes: MAX_FILE_BYTES.to_i64)
        check_result = current
        conflict_current = conflict.nil? || same_external_conflict?(buffer, conflict.not_nil!)
        review_current = review.nil? || external_review_current?(review.not_nil!)
        review_disk = review.nil? || exact_observation?(review.not_nil!.current, current)
        authorized = conflict_current && review_current && review_disk && if conflict
          overwrite_candidate_matches?(conflict.not_nil!, current)
        else
          accepted_revision_matches?(baseline.not_nil!, current)
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
        conflict_current = conflict.nil? || same_external_conflict?(buffer, conflict.not_nil!)
        review_current = review.nil? || external_review_current?(review.not_nil!)
        authorized = conflict_current && review_current && !!revision && own_save_matches?(revision.not_nil!, digest, target)
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
      if conflict && buffer.external_conflict_generation != action_generation
        @status_log.warning("#{buffer.path.basename} changed again during save")
        return false
      end
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

    private def reload_external_file(
      buffer : OpenBuffer,
      conflict : ExternalFileConflict,
      review : ExternalChangeReview? = nil,
    ) : Bool
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

      if review
        unless exact_observation?(review.not_nil!.current, snapshot) && external_review_current?(review.not_nil!)
          @status_log.warning("#{buffer.path.basename} external review changed during reload")
          publish_save_mismatch(buffer, snapshot)
          return false
        end
      else
        return false unless same_external_conflict?(buffer, conflict)
      end

      content = snapshot.content
      revision = snapshot.revision
      unless content && revision && text_content?(content.not_nil!)
        @status_log.warning("Cannot reload non-text content from #{buffer.path.basename}")
        return false
      end

      content_changed = editor_digest(buffer.editor) != revision.not_nil!.digest
      return false if review && !external_review_current?(review.not_nil!)
      return false unless same_external_conflict?(buffer, conflict)

      mutation_version = buffer.version
      mutation_editor = buffer.editor
      if content_changed
        return false unless mutation_editor.reload_as_saved(content.not_nil!, buffer.path)
      else
        return false unless mutation_editor.accept_current_as_saved(buffer.path)
      end

      # Reload notifies editor/LSP callbacks. They may yield and allow a new
      # edit or external event before this method resumes. Do not acknowledge
      # the old fingerprint or clear a newer conflict in that case.
      expected_version = content_changed ? mutation_version + 1 : mutation_version
      unless buffer.editor.same?(mutation_editor) && buffer.version == expected_version && same_external_conflict?(buffer, conflict)
        @status_log.warning("#{buffer.path.basename} changed during reload; newer conflict retained")
        return false
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

    private def overwrite_external_file(
      buffer : OpenBuffer,
      conflict : ExternalFileConflict,
      review : ExternalChangeReview? = nil,
    ) : Bool
      status = conflict.event.current.status
      unless status.in?(FileRevision::Status::Stable, FileRevision::Status::Missing)
        @status_log.warning("Cannot overwrite #{buffer.path.basename} while the path is #{external_status_label(status)}")
        return false
      end
      if review
        # A Stable candidate is only overwrite-authorized once the bounded
        # read proved it is text. Missing is intentionally allowed as an
        # explicit recreate path; all other unavailable candidates fail
        # closed before any temporary file is written.
        if status == FileRevision::Status::Stable && !review.not_nil!.preview_available?
          @status_log.warning("Cannot overwrite non-text content from #{buffer.path.basename}")
          return false
        end
      elsif status == FileRevision::Status::Stable
        # The monitor intentionally stores a digest-only candidate.  A
        # legacy token/generation action must still prove that the bytes are
        # text before allowing an overwrite; otherwise unseen binary bytes
        # would be silently authorized by a status-only check.
        candidate = FileRevision.read(
          buffer.path,
          max_bytes: MAX_FILE_BYTES.to_i64,
          expected_stamp: conflict.event.current.stamp
        )
        unless same_external_conflict?(buffer, conflict) && exact_observation?(conflict.event.current, candidate)
          publish_save_mismatch(buffer, candidate)
          @status_log.warning("#{buffer.path.basename} changed again before overwrite")
          return false
        end
        content = candidate.content
        unless candidate.stable? && content && text_content?(content.not_nil!)
          @status_log.warning("Cannot overwrite non-text content from #{buffer.path.basename}")
          return false
        end
      end
      save_buffer(buffer, conflict, review)
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

    private def external_review_current?(review : ExternalChangeReview) : Bool
      live = @document_session.open_buffers[review.buffer.path.to_s]?
      return false unless live && live.same?(review.buffer)
      return false unless live.editor.same?(review.editor)
      return false unless live.version == review.version
      return false unless live.watch_token == review.watch_token
      conflict = live.external_conflict
      return false unless conflict
      conflict.not_nil!.watch_token == review.watch_token &&
        conflict.not_nil!.generation == review.conflict_generation
    end

    private def same_external_conflict?(buffer : OpenBuffer, expected : ExternalFileConflict) : Bool
      live = buffer.external_conflict
      return false unless live
      live.not_nil!.watch_token == expected.watch_token &&
        live.not_nil!.generation == expected.generation
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
      label = file_tab_label(buffer)
      panels = @editor_groups_provider.try(&.call) || [@tabs_for_path_provider.try(&.call(buffer.path.to_s)) || editor_tabs]
      panels.each do |tabs|
        tabs.rename_tab(buffer.path.to_s, label) if tabs.tabs.any? { |tab| tab.id == buffer.path.to_s }
      end
    end

    private def editor_for_tab(tabs : Tui::TabbedPanel, tab_id : String) : Tui::TextEditor?
      tab = tabs.tabs.find { |candidate| candidate.id == tab_id }
      tab.try { |entry| entry.content.try(&.as?(Tui::TextEditor)) }
    end

    # Lower-level callers can retire a view without coming through the
    # TabbedPanel close callback (which has already removed its tab). Keep the
    # widget tree aligned with the session registry in that case too.
    private def remove_tab_for_view(tab_id : String, view : Tui::TextEditor) : Nil
      panels = @editor_groups_provider.try(&.call) || [@editor_tabs]
      panels.each do |panel|
        index = panel.tabs.index do |tab|
          tab.id == tab_id && tab.content.try(&.same?(view))
        end
        next unless index

        previous_active = panel.active_tab
        content = panel.tabs[index].content
        panel.remove_child(content.not_nil!) if content
        panel.tabs.delete_at(index)
        if panel.tabs.empty?
          panel.active_tab = 0
        elsif index < previous_active
          panel.active_tab = previous_active - 1
        elsif previous_active >= panel.tabs.size
          panel.active_tab = panel.tabs.size - 1
        end
        panel.mark_dirty!
      end
    end

    private def safe_invoke(label : String, path : String, &)
      yield
    rescue ex
      message = ex.message || ex.class.to_s
      @status_log.warning("Orchestrator callback failed (#{label}) for #{path}: #{message}")
    end
  end
end
