module LunaLuaDemo
  module Pagination
    # Returns up to `limit` items from a zero-based offset.
    def self.page(items : Array(T), offset : Int32, limit : Int32) : Array(T) forall T
      raise ArgumentError.new("offset must be non-negative") if offset < 0
      raise ArgumentError.new("limit must be non-negative") if limit < 0
      return [] of T if limit == 0 || offset >= items.size

      last_index = limit >= items.size - offset ? items.size - 1 : offset + limit
      items[offset..last_index] || [] of T
    end
  end
end
