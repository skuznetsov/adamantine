module Adamantine
  class DocumentSession
    getter open_buffers : Hash(String, OpenBuffer)
    getter navigation_history : Array(NavigationLocation)
    getter navigation_forward_history : Array(NavigationLocation)
    getter command_marks : Hash(String, CommandMark)
    getter navigation_history_limit : Int32

    # LSP publishDiagnostics versions are scoped to an open document.  Keep a
    # small session-wide floor so closing and reopening the same URI cannot
    # reuse an old version and admit a delayed notification from the previous
    # editor instance.  This is deliberately a scalar, not a per-URI history.
    @next_buffer_version : Int32 = 1

    def initialize(@navigation_history_limit : Int32 = 128)
      @open_buffers = {} of String => OpenBuffer
      @navigation_history = [] of NavigationLocation
      @navigation_forward_history = [] of NavigationLocation
      @command_marks = {} of String => CommandMark
    end

    def allocate_buffer_version : Int32
      version = @next_buffer_version
      @next_buffer_version = version < Int32::MAX ? version + 1 : Int32::MAX
      version
    end

    def retire_buffer_version(version : Int32) : Nil
      return if version < @next_buffer_version
      @next_buffer_version = version < Int32::MAX ? version + 1 : Int32::MAX
    end

    # Return the live widgets attached to this session's open document. The
    # view registry is kept on OpenBuffer so consumers such as LSP folding,
    # lexical rendering, and recovery share one ownership boundary.
    def views_for(buffer : OpenBuffer) : Array(Tui::TextEditor)
      live = @open_buffers[buffer.path.to_s]?
      return [] of Tui::TextEditor unless live && live.same?(buffer)

      buffer.views.dup
    end
  end
end
