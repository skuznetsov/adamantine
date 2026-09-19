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
  end
end
