def debugger_locals_probe : Int32
  debugger_sentinel = 271828
  debugger_string_empty = ""
  debugger_string_utf8 = "snowman ☃"
  debugger_string_nul = "left\0right"
  debugger_array_empty = [] of Int32
  debugger_array = [22, 44]
  debugger_union_int : Int32 | String = 22
  debugger_union_string : Int32 | String = "forty-four"
  debugger_nullable_string_nil : String? = nil
  debugger_nullable_string_value : String? = "present"
  debugger_nullable_pointer_nil : Pointer(UInt8)? = nil
  debugger_nullable_pointer_value : Pointer(UInt8)? = "pointer".to_unsafe
  debugger_nested_outer = {value: 31}

  debugger_out_of_scope_holder = 0
  [90].each do |debugger_out_of_scope|
    debugger_out_of_scope_holder = debugger_out_of_scope
  end

  debugger_shadowed = 10
  [20].each do |debugger_shadowed|
    debugger_nested = debugger_sentinel + debugger_out_of_scope_holder
    debugger_marker = debugger_sentinel                       # DAP_BREAKPOINT: locals
    debugger_after_step = debugger_marker + debugger_shadowed # DAP_AFTER_STEP
    debugger_sink = debugger_after_step + debugger_nested
    debugger_sink += debugger_nested_outer[:value]
    debugger_sink += debugger_string_empty.bytesize + debugger_string_utf8.bytesize + debugger_string_nul.bytesize
    debugger_sink += debugger_array_empty.size + debugger_array[0] + debugger_array[1]
    debugger_sink += debugger_union_int.to_s.bytesize + debugger_union_string.to_s.bytesize
    debugger_sink += debugger_nullable_string_nil.nil? ? 1 : 0
    debugger_sink += debugger_nullable_string_value.to_s.bytesize
    debugger_sink += debugger_nullable_pointer_nil.nil? ? 1 : 0
    debugger_sink += debugger_nullable_pointer_value.nil? ? 1 : 0
    debugger_sink += debugger_shadowed
  end

  debugger_sentinel
end

exit(debugger_locals_probe == 271828 ? 0 : 1)
