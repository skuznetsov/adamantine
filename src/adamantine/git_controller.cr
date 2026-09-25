require "./git_repository"
require "./modal_state"

module Adamantine
  class GitViewState
    include ModalState
    property open : Bool = false
    property overlay : Tui::OverlayRenderer? = nil
    property snapshot : GitRepository::Snapshot? = nil
    property page : Symbol = :status
    property return_page : Symbol = :status
    property index : Int32 = 0
    property scroll : Int32 = 0
    property diff_lines : Array(String) = [] of String
    property message : String = ""
    property loading : Bool = false
    property generation : UInt64 = 0_u64
    property cancellation : GitRepository::Cancellation? = nil
    property pending : Proc(Nil)? = nil
    property worker_active : Bool = false
  end

  module GitController
    private def git_view_active? : Bool
      @git_view.open && active_input_mode == InputModeController::InputMode::Git
    end

    private def open_git_view : Nil
      close_git_view
      close_context_menu
      close_lsp_popup
      close_quick_open
      close_problems
      close_settings_dialog if @settings.open
      close_search_panel if @search.open
      close_command_palette if @command_palette.open
      @clipboard_paste_generation &+= 1_u64
      @git_view.page = :status
      @git_view.index = 0
      @git_view.scroll = 0
      with_input_mode_guard(InputModeController::InputMode::Git) do
        @git_view.overlay = open_overlay(nil, ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_git_view(buffer, clip)
        })
        @git_view.open = true
      end
      schedule_git_read(:snapshot)
    end

    private def close_git_view : Nil
      @git_view.generation &+= 1_u64
      @git_view.cancellation.try &.cancel
      @git_view.cancellation = nil
      @git_view.pending = nil
      @git_view.snapshot = nil
      @git_view.diff_lines.clear
      @git_view.loading = false
      close_modal(@git_view, InputModeController::InputMode::Git)
    end

    # One running process chain and one replaceable pending request. A close or
    # root switch revokes publication authority and cancels the active reader.
    private def schedule_git_read(kind : Symbol, target : String = "") : Nil
      @git_view.cancellation.try &.cancel
      cancellation = GitRepository::Cancellation.new
      @git_view.cancellation = cancellation
      @git_view.generation &+= 1_u64
      generation = @git_view.generation
      project_root = @project_root
      repo_root = @git_view.snapshot.try(&.root) || project_root
      @git_view.loading = true
      @git_view.message = "Loading Git #{kind}…"
      @git_view.pending = -> {
        begin
          if kind == :snapshot
            snapshot = GitRepository.snapshot(project_root, cancellation)
            if git_read_current?(generation, project_root, cancellation)
              @git_view.snapshot = snapshot
              @git_view.index = 0
              @git_view.scroll = 0
              @git_view.message = snapshot.notices.join(" · ")
            end
          else
            diff = if kind == :commit
                     GitRepository.commit_diff(repo_root, target, cancellation)
                   else
                     GitRepository.file_diff(repo_root, target, cancellation)
                   end
            if git_read_current?(generation, project_root, cancellation)
              @git_view.diff_lines = diff.lines
              @git_view.diff_lines = ["No textual diff (binary, untracked or unchanged)."] if @git_view.diff_lines.empty?
              @git_view.page = :diff
              @git_view.scroll = 0
              @git_view.message = GitRepository.display(target, 160)
            end
          end
        rescue ex
          if git_read_current?(generation, project_root, cancellation)
            @git_view.message = "Git error: #{GitRepository.display(ex.message || ex.class.to_s, 240)}"
          end
        ensure
          if git_read_current?(generation, project_root, cancellation)
            @git_view.loading = false
            mark_dirty!
            wakeup
          end
        end
        nil
      }
      unless @git_view.worker_active
        @git_view.worker_active = true
        spawn(name: "git-view-reader") do
          begin
            while work = @git_view.pending
              @git_view.pending = nil
              work.call
            end
          ensure
            @git_view.worker_active = false
          end
        end
      end
      mark_dirty!
    end

    private def git_read_current?(generation : UInt64, root : Path, cancellation : GitRepository::Cancellation) : Bool
      @git_view.open && @git_view.generation == generation && @project_root == root && !cancellation.cancelled?
    end

    private def handle_git_input(event : Tui::KeyEvent) : Bool
      if event.key == Tui::Key::Escape
        if @git_view.page == :diff && !@git_view.loading
          @git_view.page = @git_view.return_page
          @git_view.scroll = 0
        else
          close_git_view
        end
      elsif event.matches?("tab") || event.char == 's' || event.char == 'l'
        return true if @git_view.loading
        @git_view.page = if event.char == 's'
                           :status
                         elsif event.char == 'l'
                           :log
                         else
                           @git_view.page == :status ? :log : :status
                         end
        @git_view.index = 0
        @git_view.scroll = 0
      elsif event.char == 'r'
        @git_view.page = :status
        schedule_git_read(:snapshot)
      elsif event.matches?("up") || event.matches?("down") || event.matches?("pageup") || event.matches?("pagedown")
        delta = event.matches?("up") ? -1 : event.matches?("down") ? 1 : event.matches?("pageup") ? -10 : 10
        if @git_view.page == :diff
          @git_view.scroll = (@git_view.scroll + delta).clamp(0, [@git_view.diff_lines.size - 1, 0].max)
        else
          count = git_row_count
          @git_view.index = (@git_view.index + delta).clamp(0, [count - 1, 0].max)
        end
      elsif event.matches?("enter") || event.matches?("return")
        return true if @git_view.loading || @git_view.page == :diff
        if snapshot = @git_view.snapshot
          @git_view.return_page = @git_view.page
          if @git_view.page == :log
            if commit = snapshot.commits[@git_view.index]?
              schedule_git_read(:commit, commit.hash)
            end
          elsif file = snapshot.files[@git_view.index]?
            schedule_git_read(:file, file.path)
          end
        end
      end
      mark_dirty!
      true
    end

    private def git_row_count : Int32
      snapshot = @git_view.snapshot
      return 0 unless snapshot
      @git_view.page == :log ? snapshot.commits.size : snapshot.files.size
    end

    private def render_git_view(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless @git_view.open
      return if clip.width < 2 || clip.height < 4
      style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      active = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)
      title = "Git · #{@git_view.page} · read-only / disk state#{@git_view.page == :log ? " · approximate graph" : ""}"
      draw_box_border(buffer, clip, clip.x, clip.y, clip.width, clip.height, style, style, title, active)
      width = [clip.width - 4, 0].max
      visible = [clip.height - 6, 0].max
      snapshot = @git_view.snapshot
      branch = snapshot ? GitRepository.display(snapshot.branch, 120) : ""
      draw_text_line(buffer, clip, clip.x + 2, clip.y + 1, "#{branch}  Tab: status/log  Enter: diff  r: refresh  Esc: back/close", style, width)
      if @git_view.page == :diff
        @git_view.diff_lines[@git_view.scroll, visible].each_with_index do |line, offset|
          color = line.starts_with?('+') ? Theme::Status.success : line.starts_with?('-') ? Theme::Status.error : Theme::Popup.text
          draw_text_line(buffer, clip, clip.x + 2, clip.y + 2 + offset, Tui::Unicode.truncate(line, width), Tui::Style.new(fg: color, bg: Theme::Popup.active_bg), width)
        end
      elsif snapshot
        count = git_row_count
        if @git_view.index < @git_view.scroll
          @git_view.scroll = @git_view.index
        elsif @git_view.index >= @git_view.scroll + visible
          @git_view.scroll = [@git_view.index - visible + 1, 0].max
        end
        visible.times do |offset|
          index = @git_view.scroll + offset
          break if index >= count
          line = if @git_view.page == :log
                   commit = snapshot.commits[index]
                   refs = commit.refs.empty? ? "" : " [#{commit.refs.join(", ")}]"
                   "#{commit.graph} #{commit.short_hash}#{refs} #{commit.message} (#{commit.author}, #{commit.date})"
                 else
                   snapshot.files[index].display
                 end
          draw_text_line(buffer, clip, clip.x + 2, clip.y + 2 + offset, Tui::Unicode.truncate(GitRepository.display(line, 512), width), index == @git_view.index ? active : style, width)
        end
        if count == 0
          empty = @git_view.page == :log ? "No commits." : "No disk/index changes. Unsaved editor buffers are not included."
          draw_text_line(buffer, clip, clip.x + 2, clip.y + 2, empty, style, width)
        end
      end
      total = @git_view.page == :diff ? @git_view.diff_lines.size : git_row_count
      position = total == 0 ? 0 : (@git_view.page == :diff ? @git_view.scroll : @git_view.index) + 1
      draw_text_line(buffer, clip, clip.x + 2, clip.bottom - 3, "#{position}/#{total} · ↑↓ PgUp/PgDn · #{@git_view.loading ? "Loading…" : "Disk snapshot; r refreshes"}", style, width)
      draw_text_line(buffer, clip, clip.x + 2, clip.bottom - 2, @git_view.message, style, width)
    end
  end
end
