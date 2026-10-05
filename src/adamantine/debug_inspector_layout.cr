require "crystal_tui"
require "./theme"

module Adamantine
  enum DebugInspectorDock
    Left
    Right
    Bottom
  end

  enum DebugInspectorSection
    Files
    Debug
  end

  # FilePanel owns a standalone frame. In the App's compact inspector the
  # layout owns the shared edges, so keep the inherited geometry/input and
  # file-list rendering while replacing the framed title with a plain header.
  # This avoids both doubled vertical strokes and orphaned horizontal rules.
  class DebugSharedEdgeFilePanel < Tui::FilePanel
    def initialize(path : Path, id : String? = nil)
      super(path, id: id)
    end

    def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless visible?
      super
      return if rect.empty?

      frame_style = Tui::Style.new(fg: bg_color, bg: bg_color)
      rect.width.times do |offset|
        x = rect.x + offset
        buffer.set(x, rect.y, ' ', frame_style) if clip.contains?(x, rect.y)
        if rect.height > 1
          bottom = rect.bottom - 1
          buffer.set(x, bottom, ' ', frame_style) if clip.contains?(x, bottom)
        end
      end
      rect.height.times do |offset|
        y = rect.y + offset
        buffer.set(rect.x, y, ' ', frame_style) if clip.contains?(rect.x, y)
        if rect.width > 1
          right = rect.right - 1
          buffer.set(right, y, ' ', frame_style) if clip.contains?(right, y)
        end
      end

      # FilePanel's path title is private to its frame renderer. Repaint it as
      # a bounded plain header while leaving the real tree/list renderer intact.
      header_width = Math.max(rect.width - 2, 0)
      return if header_width <= 0 || rect.y < clip.y || rect.y >= clip.bottom
      header = path_header(path.to_s, header_width)
      header_style = Tui::Style.new(fg: title_color, bg: bg_color, attrs: Tui::Attributes::Bold)
      x = rect.x + 1
      header.each_grapheme do |grapheme|
        glyph = grapheme.to_s
        width = Tui::Unicode.grapheme_width(glyph)
        break if x + width > rect.right - 1
        buffer.set(x, rect.y, glyph, header_style) if clip.contains?(x, rect.y)
        x += width
      end
    end

    private def path_header(value : String, max_width : Int32) : String
      return "" if max_width <= 0
      return value if Tui::Unicode.display_width(value) <= max_width
      return "…" if max_width == 1

      suffix = [] of String
      suffix_width = 0
      target_width = max_width - 1
      value.each_grapheme.to_a.reverse_each do |raw|
        grapheme = raw.to_s
        width = Tui::Unicode.grapheme_width(grapheme)
        break if suffix_width + width > target_width
        suffix << grapheme
        suffix_width += width
      end
      "…#{suffix.reverse.join}"
    end
  end

  # Geometry is the resolved, non-overlapping composition for one frame. The
  # rail occupies the first cell; rail_separator_x is its shared second cell.
  struct DebugInspectorGeometry
    getter dock : DebugInspectorDock
    getter effective_dock : DebugInspectorDock
    getter rail : Tui::Rect
    getter rail_separator_x : Int32?
    getter editor : Tui::Rect
    getter inspector : Tui::Rect?
    getter inspector_separator_x : Int32?
    getter inspector_separator_y : Int32?
    getter compact : Bool

    def initialize(
      @dock : DebugInspectorDock,
      @effective_dock : DebugInspectorDock,
      @rail : Tui::Rect,
      @rail_separator_x : Int32?,
      @editor : Tui::Rect,
      @inspector : Tui::Rect?,
      @inspector_separator_x : Int32?,
      @inspector_separator_y : Int32?,
      @compact : Bool,
    )
    end

    def compact? : Bool
      @compact
    end
  end

  # Two-cell-wide activity rail: one label cell and one shared separator cell.
  # Selection is intentionally separate from focus so choosing a panel never
  # changes the active editor unless it would otherwise leave focus in a
  # widget that has just become hidden.
  class DebugActivityRail < Tui::Widget
    property selected_section : DebugInspectorSection = DebugInspectorSection::Files

    @on_select : Proc(DebugInspectorSection, Bool)? = nil

    def initialize(id : String = "debug-activity-rail")
      super(id)
      @focusable = true
    end

    def on_select(&block : DebugInspectorSection -> Bool) : Nil
      @on_select = block
    end

    def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless visible?
      return if @rect.empty?

      if @rect.height == 1
        draw_initial(buffer, clip, @rect.y, @selected_section)
      elsif @rect.height < 11
        draw_initial(buffer, clip, @rect.y, DebugInspectorSection::Files)
        draw_initial(buffer, clip, @rect.bottom - 1, DebugInspectorSection::Debug)
      else
        draw_label(buffer, clip, "Files", @rect.y, DebugInspectorSection::Files)
        draw_label(buffer, clip, "Debug", @rect.y + 6, DebugInspectorSection::Debug)
      end
    end

    def on_event(event : Tui::Event) : Bool
      return false if event.stopped?

      case event
      when Tui::MouseEvent
        return false unless event.press? && event.left? && event.in_rect?(@rect)
        if section = section_at(event.y)
          request_selection(section)
        else
          false
        end
      when Tui::KeyEvent
        case event.key
        when .up?, .left?
          request_selection(DebugInspectorSection::Files)
        when .down?, .right?
          request_selection(DebugInspectorSection::Debug)
        when .enter?
          request_selection(@selected_section)
        else
          false
        end
      else
        false
      end
    end

    private def request_selection(section : DebugInspectorSection) : Bool
      @on_select.try(&.call(section))
      true
    end

    private def section_at(y : Int32) : DebugInspectorSection?
      return @selected_section if @rect.height == 1 && y == @rect.y
      if @rect.height >= 11
        return DebugInspectorSection::Files if y >= @rect.y && y < @rect.y + 5
        return DebugInspectorSection::Debug if y >= @rect.y + 6 && y < @rect.y + 11
        return nil
      end
      return DebugInspectorSection::Files if y == @rect.y
      return DebugInspectorSection::Debug if y == @rect.bottom - 1
      nil
    end

    private def draw_initial(buffer : Tui::Buffer, clip : Tui::Rect, y : Int32, section : DebugInspectorSection) : Nil
      return unless @rect.contains?(@rect.x, y) && clip.contains?(@rect.x, y)
      selected = @selected_section == section
      char = if selected
               section.files? ? 'F' : 'D'
             else
               section.files? ? 'f' : 'd'
             end
      buffer.set(@rect.x, y, char, rail_style(selected))
    end

    private def draw_label(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      label : String,
      y : Int32,
      section : DebugInspectorSection,
    ) : Nil
      selected = @selected_section == section
      label.each_char_with_index do |char, index|
        row = y + index
        break if row >= @rect.bottom
        next unless clip.contains?(@rect.x, row)
        rendered = index == 0 && selected ? char.upcase : char.downcase
        buffer.set(@rect.x, row, rendered, rail_style(selected))
      end
    end

    private def rail_style(selected : Bool) : Tui::Style
      return Tui::Style.default unless selected
      Tui::Style.new(
        fg: Theme::Popup.active_fg,
        bg: Theme::Popup.active_bg,
        attrs: Tui::Attributes::Bold | Tui::Attributes::Underline
      )
    end
  end

  # The Files surface is always the ordinary left inspector. The persisted
  # dock preference applies to Debug only; the far-left rail never moves.
  class DebugInspectorLayout < Tui::Widget
    RAIL_WIDTH                    = 1
    RAIL_SEPARATOR_WIDTH          = 1
    RAIL_COLUMNS                  = RAIL_WIDTH + RAIL_SEPARATOR_WIDTH
    MIN_EDITOR_WIDTH              =   20
    MIN_INSPECTOR_WIDTH           =   12
    MIN_EDITOR_HEIGHT             =    5
    MIN_INSPECTOR_HEIGHT          =    3
    DEFAULT_FILES_INSPECTOR_WIDTH =   24
    DEFAULT_DEBUG_INSPECTOR_WIDTH =   34
    MIN_VISIBLE_INSPECTOR_WIDTH   =    8
    DEFAULT_BOTTOM_RATIO          = 0.33

    getter editor : Tui::Widget
    getter files_panel : Tui::Widget
    getter debug_panel : Tui::Widget
    getter activity_rail : DebugActivityRail
    getter selected_section : DebugInspectorSection
    getter files_width : Int32
    getter debug_width : Int32
    property debug_dock : DebugInspectorDock = DebugInspectorDock::Left

    def files_inspector_hidden? : Bool
      @files_hidden
    end

    @selection_allowed : Proc(Bool)? = nil
    @focus_editor : Proc(Nil)? = nil
    @on_unusable_inspector : Proc(Bool, Nil)? = nil
    @on_section_changed : Proc(DebugInspectorSection, Nil)? = nil
    @inspector_unusable = false
    @debug_bottom_ratio = DEFAULT_BOTTOM_RATIO
    @dragging_separator = false
    @layout_initialized = false
    @files_hidden = false

    def initialize(@editor : Tui::Widget, @files_panel : Tui::Widget, @debug_panel : Tui::Widget, id : String = "debug-inspector-layout")
      super(id)
      @selected_section = DebugInspectorSection::Files
      @files_width = DEFAULT_FILES_INSPECTOR_WIDTH
      @debug_width = DEFAULT_DEBUG_INSPECTOR_WIDTH
      @activity_rail = DebugActivityRail.new
      add_child(@editor)
      add_child(@files_panel)
      add_child(@debug_panel)
      add_child(@activity_rail)
      @activity_rail.on_select { |section| select_section(section) }
      update_panel_visibility
      @layout_initialized = true
    end

    def rect=(value : Tui::Rect) : Tui::Rect
      @rect = value
      apply_geometry(resolve_geometry) if @layout_initialized
      mark_dirty!
      value
    end

    def debug_dock=(value : DebugInspectorDock) : Nil
      @debug_dock = value
      apply_geometry(resolve_geometry) if @layout_initialized
      mark_dirty!
    end

    # Swap the full editor region without touching its tabs or document views.
    def editor=(widget : Tui::Widget) : Nil
      return if widget.same?(@editor)
      remove_child(@editor)
      @editor = widget
      add_child(widget)
      apply_geometry(resolve_geometry) if @layout_initialized
      mark_dirty!
    end

    # Lets the App preserve its focused editor group. The fallback focuses the
    # editor container for standalone layouts and specs.
    def on_focus_editor(&block : -> Nil) : Nil
      @focus_editor = block
    end

    # Modal owners can deny panel selection without causing a focus or layout
    # transition. The default is permissive for use outside App.
    def on_selection_allowed(&block : -> Bool) : Nil
      @selection_allowed = block
    end

    # App can surface a resize hint when the selected sidebar cannot fit.
    def on_unusable_inspector(&block : Bool -> Nil) : Nil
      @on_unusable_inspector = block
    end

    def on_section_changed(&block : DebugInspectorSection -> Nil) : Nil
      @on_section_changed = block
    end

    def select_section(section : DebugInspectorSection) : Bool
      if section == @selected_section && !(@selected_section.files? && @files_hidden)
        return true
      end
      return false if @selection_allowed && !@selection_allowed.not_nil!.call

      old_panel = visible_inspector
      @files_hidden = false if section.files?
      @selected_section = section
      @activity_rail.selected_section = section
      update_panel_visibility
      @on_section_changed.try(&.call(section))
      apply_geometry(resolve_geometry) if @layout_initialized
      if focused_within?(Tui::Widget.focused_widget, old_panel)
        if callback = @focus_editor
          callback.call
        else
          @editor.focus
        end
      end
      mark_dirty!
      true
    end

    # Hiding Files is an explicit layout action; switching to Debug never
    # discards its tree state, and selecting Files again restores it.
    def hide_files_inspector : Bool
      return false unless @selected_section.files? && !@files_hidden
      return false if @selection_allowed && !@selection_allowed.not_nil!.call

      @files_hidden = true
      update_panel_visibility
      apply_geometry(resolve_geometry) if @layout_initialized
      if focused_within?(Tui::Widget.focused_widget, @files_panel) && focus_repair_allowed?
        focus_editor
      end
      mark_dirty!
      true
    end

    def geometry : DebugInspectorGeometry
      resolve_geometry
    end

    # Columns where the vertical shared edges continue to the App's full-width
    # status divider. The editor splitter only qualifies when its pane reaches
    # the outer layout bottom; Bottom inspectors end it at their own divider.
    def status_junction_columns : Array(Int32)
      resolved = resolve_geometry
      columns = [] of Int32
      columns << resolved.rail_separator_x.not_nil! if resolved.rail_separator_x
      columns << resolved.inspector_separator_x.not_nil! if resolved.inspector_separator_x
      columns.concat(editor_splitter_xs(@editor, @rect.bottom))
      columns.uniq
    end

    # Modal owners call this only after releasing their input mode. Geometry
    # may have become unusable while the modal was active, when focus repair
    # was correctly denied; make that deferred repair before normal input can
    # reach a now-invisible child widget with stale internal geometry.
    def repair_focus_if_unusable : Nil
      apply_geometry(resolve_geometry) if @layout_initialized
    end

    def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless visible?
      resolved = resolve_geometry
      apply_geometry(resolved)
      return if @rect.empty?
      render_child(@activity_rail, resolved.rail, buffer, clip)
      render_child(@editor, resolved.editor, buffer, clip)
      if inspector = resolved.inspector
        panel = visible_inspector
        render_child(panel, inspector, buffer, clip)
      end
      render_separators(buffer, clip, resolved)
    end

    def on_event(event : Tui::Event) : Bool
      return false if event.stopped?
      if mouse = event.as?(Tui::MouseEvent)
        if @dragging_separator
          case mouse.action
          when .drag?
            resize_inspector(mouse.x, mouse.y)
            mark_dirty!
            mouse.stop!
            return true
          when .release?
            @dragging_separator = false
            release_mouse
            mouse.stop!
            mark_dirty!
            return true
          else
            return true
          end
        end

        if mouse.press? && mouse.left?
          if separator_hit?(mouse.x, mouse.y)
            @dragging_separator = true
            capture_mouse
            mouse.stop!
            return true
          end
          return @activity_rail.handle_event(mouse) if @activity_rail.rect.contains?(mouse.x, mouse.y)
        end
      end
      false
    end

    private def resolve_geometry : DebugInspectorGeometry
      width = Math.max(@rect.width, 0)
      height = Math.max(@rect.height, 0)
      rail = Tui::Rect.new(@rect.x, @rect.y, Math.min(width, RAIL_WIDTH), height)
      rail_separator_x = width > RAIL_WIDTH ? @rect.x + RAIL_WIDTH : nil
      workspace_x = @rect.x + Math.min(width, RAIL_COLUMNS)
      workspace_width = Math.max(@rect.right - workspace_x, 0)

      requested_dock = @selected_section.debug? ? @debug_dock : DebugInspectorDock::Left
      if @selected_section.files? && @files_hidden
        editor = Tui::Rect.new(workspace_x, @rect.y, workspace_width, height)
        return DebugInspectorGeometry.new(requested_dock, requested_dock, rail, rail_separator_x, editor, nil, nil, nil, false)
      end
      width_compact = width < RAIL_COLUMNS + MIN_EDITOR_WIDTH + MIN_INSPECTOR_WIDTH + 1
      effective_dock = width_compact && @selected_section.debug? ? DebugInspectorDock::Bottom : requested_dock
      main_height = Math.max(height - 1, 0)
      height_compact = height < MIN_INSPECTOR_HEIGHT || effective_dock.bottom? && main_height < MIN_EDITOR_HEIGHT + MIN_INSPECTOR_HEIGHT
      compact = width_compact || height_compact
      if height_compact
        effective_dock = DebugInspectorDock::Bottom
      end

      if effective_dock.bottom?
        return bottom_geometry(requested_dock, effective_dock, rail, rail_separator_x, workspace_x, workspace_width, main_height, compact)
      end

      if height < MIN_INSPECTOR_HEIGHT
        editor = Tui::Rect.new(workspace_x, @rect.y, workspace_width, height)
        return DebugInspectorGeometry.new(requested_dock, effective_dock, rail, rail_separator_x, editor, nil, nil, nil, true)
      end

      preferred_width = @selected_section.debug? ? @debug_width : @files_width
      max_inspector_width = Math.min(workspace_width - MIN_EDITOR_WIDTH - 1, workspace_width)
      minimum_inspector_width = [MIN_VISIBLE_INSPECTOR_WIDTH, max_inspector_width].min
      if max_inspector_width < minimum_inspector_width || max_inspector_width < MIN_VISIBLE_INSPECTOR_WIDTH
        editor = Tui::Rect.new(workspace_x, @rect.y, workspace_width, height)
        return DebugInspectorGeometry.new(requested_dock, effective_dock, rail, rail_separator_x, editor, nil, nil, nil, true)
      end
      inspector_width = preferred_width.clamp(minimum_inspector_width, max_inspector_width)
      separator_x = if workspace_width > 0
                      effective_dock.left? ? workspace_x + inspector_width : workspace_x + workspace_width - inspector_width - 1
                    else
                      nil
                    end

      if effective_dock.left?
        inspector = Tui::Rect.new(workspace_x, @rect.y, inspector_width, height)
        editor_x = separator_x ? separator_x + 1 : workspace_x
        editor = Tui::Rect.new(editor_x, @rect.y, Math.max(@rect.right - editor_x, 0), height)
      else
        editor_width = Math.max(workspace_width - inspector_width - (workspace_width > 0 ? 1 : 0), 0)
        editor = Tui::Rect.new(workspace_x, @rect.y, editor_width, height)
        inspector_x = separator_x ? separator_x + 1 : workspace_x + editor_width
        inspector = Tui::Rect.new(inspector_x, @rect.y, Math.max(@rect.right - inspector_x, 0), height)
      end

      DebugInspectorGeometry.new(
        requested_dock, effective_dock, rail, rail_separator_x, editor, inspector,
        separator_x, nil, compact
      )
    end

    private def bottom_geometry(
      requested_dock : DebugInspectorDock,
      effective_dock : DebugInspectorDock,
      rail : Tui::Rect,
      rail_separator_x : Int32?,
      workspace_x : Int32,
      workspace_width : Int32,
      main_height : Int32,
      compact : Bool,
    ) : DebugInspectorGeometry
      # Do not steal the editor's only usable rows in a compact terminal. A
      # bottom inspector needs the minimum editor rows, minimum panel rows,
      # and one separator row together; otherwise leave the full body to the
      # editor and report the selected inspector as temporarily unusable.
      if main_height < MIN_EDITOR_HEIGHT + MIN_INSPECTOR_HEIGHT
        editor = Tui::Rect.new(workspace_x, @rect.y, workspace_width, @rect.height)
        return DebugInspectorGeometry.new(requested_dock, effective_dock, rail, rail_separator_x, editor, nil, nil, nil, true)
      end

      inspector_height = if compact
                           preferred_compact_height = Math.max(main_height // 2, MIN_INSPECTOR_HEIGHT)
                           Math.min(preferred_compact_height, main_height - MIN_EDITOR_HEIGHT)
                         elsif @selected_section.debug? && @debug_dock.bottom?
                           (@debug_bottom_ratio * main_height).to_i.clamp(MIN_INSPECTOR_HEIGHT, main_height - MIN_EDITOR_HEIGHT)
                         else
                           (main_height // 3).clamp(MIN_INSPECTOR_HEIGHT, main_height - MIN_EDITOR_HEIGHT)
                         end
      editor_height = Math.max(main_height - inspector_height, 0)
      separator_y = @rect.y + editor_height
      editor = Tui::Rect.new(workspace_x, @rect.y, workspace_width, editor_height)
      inspector = Tui::Rect.new(workspace_x, separator_y + 1, workspace_width, inspector_height)
      DebugInspectorGeometry.new(requested_dock, effective_dock, rail, rail_separator_x, editor, inspector, nil, separator_y, compact)
    end

    private def apply_geometry(resolved : DebugInspectorGeometry) : Nil
      @activity_rail.rect = resolved.rail
      @editor.rect = resolved.editor
      if inspector = resolved.inspector
        visible_inspector.rect = inspector
        set_inspector_unusable(false)
        if (inspector.height < MIN_INSPECTOR_HEIGHT || inspector.width < MIN_VISIBLE_INSPECTOR_WIDTH) && focus_repair_allowed? && focused_within?(Tui::Widget.focused_widget, visible_inspector)
          focus_editor
        end
      else
        visible_inspector.rect = Tui::Rect.new(@rect.x, @rect.y, 0, 0)
        user_hidden = @selected_section.files? && @files_hidden
        set_inspector_unusable(!user_hidden)
        if focus_repair_allowed? && focused_within?(Tui::Widget.focused_widget, visible_inspector)
          focus_editor
        end
      end
    end

    private def render_child(child : Tui::Widget, area : Tui::Rect, buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless child.visible?
      return if area.empty?
      child.rect = area
      if child_clip = clip.intersect(area)
        child.render(buffer, child_clip)
      end
    end

    private def render_separators(buffer : Tui::Buffer, clip : Tui::Rect, resolved : DebugInspectorGeometry) : Nil
      if x = resolved.rail_separator_x
        draw_vertical(buffer, clip, x, '│')
      end
      if x = resolved.inspector_separator_x
        draw_vertical(buffer, clip, x, '│')
      end
      if y = resolved.inspector_separator_y
        @rect.width.times do |offset|
          x = @rect.x + offset
          next unless @rect.contains?(x, y) && clip.contains?(x, y)
          glyph = x == resolved.rail_separator_x ? '┼' : '─'
          buffer.set(x, y, glyph, border_style)
        end
        editor_splitter_xs(@editor, y).uniq.each do |x|
          next unless @rect.contains?(x, y) && clip.contains?(x, y)
          buffer.set(x, y, '┴', border_style)
        end
      end
    end

    private def editor_splitter_xs(widget : Tui::Widget, bottom_y : Int32) : Array(Int32)
      splitters = [] of Int32
      collect_editor_splitter_xs(widget, bottom_y, splitters)
      splitters
    end

    private def collect_editor_splitter_xs(widget : Tui::Widget, bottom_y : Int32, splitters : Array(Int32)) : Nil
      if split = widget.as?(Tui::SplitContainer)
        split.calculate_layout
        if split.direction.horizontal? && !split.show_border && split.rect.height > 0 && split.rect.bottom == bottom_y
          splitters << split.splitter_x
        end
      end

      widget.children.each do |child|
        collect_editor_splitter_xs(child, bottom_y, splitters)
      end
    end

    private def draw_vertical(buffer : Tui::Buffer, clip : Tui::Rect, x : Int32, glyph : Char) : Nil
      return unless x >= @rect.x && x < @rect.right
      @rect.height.times do |offset|
        y = @rect.y + offset
        next unless clip.contains?(x, y)
        buffer.set(x, y, glyph, border_style)
      end
    end

    private def border_style : Tui::Style
      color = @dragging_separator ? Theme::Split.splitter_drag : Theme::Split.border
      Tui::Style.new(fg: color)
    end

    private def set_inspector_unusable(value : Bool) : Nil
      return if value == @inspector_unusable
      @inspector_unusable = value
      @on_unusable_inspector.try(&.call(value))
    end

    private def separator_hit?(x : Int32, y : Int32) : Bool
      return false unless @rect.contains?(x, y)
      geometry = resolve_geometry
      if separator_x = geometry.inspector_separator_x
        return x == separator_x && y >= @rect.y && y < @rect.bottom
      end
      if separator_y = geometry.inspector_separator_y
        workspace_x = @rect.x + Math.min(@rect.width, RAIL_COLUMNS)
        return y == separator_y && x >= workspace_x && x < @rect.right
      end
      false
    end

    private def resize_inspector(mouse_x : Int32, mouse_y : Int32) : Nil
      geometry = resolve_geometry
      if geometry.effective_dock.bottom?
        total = Math.max(@rect.height - 1, 0)
        return if total < MIN_INSPECTOR_HEIGHT + 1
        inspector_height = (@rect.bottom - 1 - mouse_y).clamp(MIN_INSPECTOR_HEIGHT, total - 1)
        @debug_bottom_ratio = inspector_height.to_f / total
      else
        workspace_x = @rect.x + Math.min(@rect.width, RAIL_COLUMNS)
        workspace_width = Math.max(@rect.right - workspace_x, 0)
        max_width = Math.min(workspace_width - MIN_EDITOR_WIDTH - 1, workspace_width)
        return if max_width < MIN_VISIBLE_INSPECTOR_WIDTH
        requested_width = if geometry.effective_dock.left?
                            mouse_x - workspace_x
                          else
                            @rect.right - mouse_x - 1
                          end
        new_width = requested_width.clamp(MIN_VISIBLE_INSPECTOR_WIDTH, max_width)
        if @selected_section.files?
          @files_width = new_width
        else
          @debug_width = new_width
        end
      end
      apply_geometry(resolve_geometry)
    end

    private def visible_inspector : Tui::Widget
      @selected_section.files? ? @files_panel : @debug_panel
    end

    private def focus_editor : Nil
      if callback = @focus_editor
        callback.call
      else
        @editor.focus
      end
    end

    private def focus_repair_allowed? : Bool
      callback = @selection_allowed
      callback.nil? || callback.call
    end

    private def update_panel_visibility : Nil
      @files_panel.visible = @selected_section.files? && !@files_hidden
      @debug_panel.visible = @selected_section.debug?
      @activity_rail.selected_section = @selected_section
    end

    private def focused_within?(focused : Tui::Widget?, ancestor : Tui::Widget) : Bool
      current = focused
      while widget = current
        return true if widget == ancestor
        current = widget.parent
      end
      false
    end
  end

  # SplitContainer draws the full-width status separator before rendering its
  # children. Add the shared-edge junctions afterward, still inside the child
  # phase so App overlays retain their normal topmost rendering order.
  class DebugStatusSplitContainer < Tui::SplitContainer
    property junction_layout : DebugInspectorLayout?

    # Tui::SplitContainer computes child areas before painting but assigns
    # those rectangles only from render. Resize input may arrive before that
    # paint, so expose the same calculated areas to App's focus-repair path
    # without rendering or duplicating the split ratio calculation.
    def synchronize_child_rects_without_render : Nil
      return if rect.empty?

      calculate_layout
      first.try { |child| child.rect = @first_area }
      second.try { |child| child.rect = @second_area }
    end

    def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      super
      return unless visible? && !rect.empty?
      return unless layout = @junction_layout

      y = splitter_y
      return unless rect.contains?(rect.x, y) && clip.contains?(rect.x, y)
      style = buffer.get(rect.x, y).style
      layout.status_junction_columns.each do |x|
        buffer.set(x, y, '┴', style) if rect.contains?(x, y) && clip.contains?(x, y)
      end
    end
  end
end
