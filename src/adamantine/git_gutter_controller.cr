require "./git_repository"

module Adamantine
  class GitGutterState
    property generation : UInt64 = 0_u64
    property cancellation : GitRepository::Cancellation? = nil
    property pending : Proc(Nil)? = nil
    property worker_active : Bool = false
    property shutdown : Bool = false
    property active_editor : EditingTextEditor? = nil
    property active_buffer : OpenBuffer? = nil
    property last_notice : String? = nil
  end

  # The gutter reader shares GitRepository's bounded child-process boundary.
  # Rendering and input only observe editor-owned marker maps; they never run
  # Git or retain the parsed patch.
  module GitGutterController
    private def git_gutter_active_file_changed : Nil
      git_gutter_revoke
      return if @git_gutter.shutdown

      buffer = active_buffer_internal
      editor = active_editor_internal.as?(EditingTextEditor)
      return unless buffer && editor

      @git_gutter.active_buffer = buffer
      @git_gutter.active_editor = editor
      git_gutter_clear_markers(editor)
      return if editor.modified? || buffer.external_conflict

      paths = git_gutter_paths(editor)
      return unless paths
      root, relative_path = paths

      project_root = @project_root
      version = buffer.version
      cancellation = GitRepository::Cancellation.new
      @git_gutter.cancellation = cancellation
      @git_gutter.generation &+= 1_u64
      generation = @git_gutter.generation
      buffer_path = buffer.path.to_s

      @git_gutter.pending = -> {
        begin
          markers = GitRepository.line_markers(root, relative_path, cancellation)
          if git_gutter_request_current?(generation, project_root, buffer, editor, buffer_path, version, cancellation)
            editor.line_change_markers = markers
            @git_gutter.last_notice = nil
            editor.mark_dirty!
          end
        rescue ex
          if git_gutter_request_current?(generation, project_root, buffer, editor, buffer_path, version, cancellation)
            git_gutter_clear_markers(editor)
            git_gutter_report_unavailable(buffer_path, ex)
          end
        ensure
          if git_gutter_request_current?(generation, project_root, buffer, editor, buffer_path, version, cancellation)
            mark_dirty!
            wakeup
          end
        end
        nil
      }

      unless @git_gutter.worker_active
        @git_gutter.worker_active = true
        spawn(name: "git-gutter-reader") do
          begin
            while work = @git_gutter.pending
              @git_gutter.pending = nil
              work.call
            end
          ensure
            @git_gutter.worker_active = false
          end
        end
      end
    end

    private def git_gutter_buffer_changed(buffer : OpenBuffer) : Nil
      git_gutter_clear_buffer_markers(buffer)

      if @git_gutter.active_buffer.try(&.same?(buffer))
        git_gutter_revoke(clear_editor: false)
        git_gutter_active_file_changed if !buffer.editor.modified? && !buffer.external_conflict
      end
    end

    private def git_gutter_buffer_saved(buffer : OpenBuffer) : Nil
      return unless @git_gutter.active_buffer.try(&.same?(buffer)) || active_buffer_internal.try(&.same?(buffer))
      git_gutter_active_file_changed
    end

    private def git_gutter_external_conflict(buffer : OpenBuffer) : Nil
      git_gutter_clear_buffer_markers(buffer)
      git_gutter_revoke(clear_editor: false) if @git_gutter.active_buffer.try(&.same?(buffer))
    end

    private def git_gutter_tab_switched : Nil
      git_gutter_active_file_changed
    end

    private def git_gutter_tab_closing(tab_id : String) : Nil
      buffer = @document_session.open_buffers[tab_id]?
      if buffer
        git_gutter_clear_buffer_markers(buffer.not_nil!)
        git_gutter_revoke(clear_editor: false) if @git_gutter.active_buffer.try(&.same?(buffer.not_nil!))
      end
    end

    private def git_gutter_tab_closed(_tab_id : String) : Nil
      git_gutter_active_file_changed
    end

    private def git_gutter_project_changed : Nil
      git_gutter_revoke
      @document_session.open_buffers.each_value do |buffer|
        git_gutter_clear_buffer_markers(buffer)
      end
      git_gutter_active_file_changed unless @git_gutter.shutdown
    end

    def git_gutter_shutdown : Nil
      return if @git_gutter.shutdown
      @git_gutter.shutdown = true
      git_gutter_revoke
    end

    private def git_gutter_revoke(clear_editor : Bool = true) : Nil
      @git_gutter.generation &+= 1_u64
      @git_gutter.cancellation.try &.cancel
      @git_gutter.cancellation = nil
      @git_gutter.pending = nil
      if clear_editor
        if editor = @git_gutter.active_editor
          git_gutter_clear_markers(editor)
        end
      end
      @git_gutter.active_editor = nil
      @git_gutter.active_buffer = nil
    end

    private def git_gutter_clear_markers(editor : EditingTextEditor) : Nil
      return if editor.line_change_markers.empty?
      editor.line_change_markers.clear
      editor.mark_dirty!
      mark_dirty!
    end

    private def git_gutter_clear_buffer_markers(buffer : OpenBuffer) : Nil
      @document_session.views_for(buffer).each do |view|
        if editor = view.as?(EditingTextEditor)
          git_gutter_clear_markers(editor)
        end
      end
    end

    private def git_gutter_request_current?(
      generation : UInt64,
      project_root : Path,
      buffer : OpenBuffer,
      editor : EditingTextEditor,
      buffer_path : String,
      version : Int32,
      cancellation : GitRepository::Cancellation,
    ) : Bool
      return false if @git_gutter.shutdown || cancellation.cancelled?
      return false unless @git_gutter.generation == generation
      return false unless @project_root == project_root
      return false unless @git_gutter.active_buffer.try(&.same?(buffer))
      return false unless @git_gutter.active_editor.try(&.same?(editor))
      return false unless active_buffer_internal.try(&.same?(buffer))
      return false unless active_editor_internal.try(&.same?(editor))
      return false unless @document_session.open_buffers[buffer_path]?.try(&.same?(buffer))
      return false unless buffer.path.to_s == buffer_path && buffer.version == version
      # Git observes live worktree bytes, while the editor shows its accepted
      # disk revision. Refuse publication if the metadata stamp moved since
      # that revision was opened or saved; this probe does not read file bytes.
      disk_revision = buffer.disk_revision
      return false unless disk_revision
      return false unless FileRevision.probe(buffer.path).same_as?(disk_revision.stamp)
      return false if editor.modified? || buffer.external_conflict
      true
    end

    private def git_gutter_paths(editor : EditingTextEditor) : Tuple(Path, String)?
      source = editor.path
      return nil unless source

      expanded_root = @project_root.expand
      expanded_source = source.not_nil!.absolute? ? source.not_nil!.expand : (@project_root / source.not_nil!).expand
      return nil unless git_gutter_path_within?(expanded_source, expanded_root)
      info = File.info?(expanded_source.to_s, follow_symlinks: false)
      return nil if info.try(&.symlink?)

      real_root = Path.new(File.realpath(@project_root.to_s))
      real_source = Path.new(File.realpath(expanded_source.to_s))
      return nil unless git_gutter_path_within?(real_source, real_root)

      relative_path = real_source.relative_to(real_root).to_s
      return nil if relative_path.empty? || relative_path == "."
      {real_root, relative_path}
    rescue
      nil
    end

    private def git_gutter_path_within?(path : Path, root : Path) : Bool
      path_text = path.expand.to_s
      root_text = root.expand.to_s
      path_text == root_text || path_text.starts_with?("#{root_text}/")
    end

    private def git_gutter_report_unavailable(path : String, error : Exception) : Nil
      detail = GitRepository.display(error.message || error.class.to_s, 160)
      notice = "#{path}: #{detail}"
      return if @git_gutter.last_notice == notice
      @git_gutter.last_notice = notice
      @status_log.warning("Git gutter unavailable: #{detail}")
    end
  end
end
