module CrystalEditor
  class DocumentSession
    getter open_buffers : Hash(String, OpenBuffer)
    getter navigation_history : Array(NavigationLocation)
    getter navigation_forward_history : Array(NavigationLocation)
    getter command_marks : Hash(String, CommandMark)
    getter navigation_history_limit : Int32

    def initialize(@navigation_history_limit : Int32 = 128)
      @open_buffers = {} of String => OpenBuffer
      @navigation_history = [] of NavigationLocation
      @navigation_forward_history = [] of NavigationLocation
      @command_marks = {} of String => CommandMark
    end
  end
end
