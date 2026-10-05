def crystal_gate : Int32
  native_scalar = 314159
  native_string = "Crystal gate"
  native_array = [22, 44]
  native_breakpoint = native_scalar # DAP_BREAKPOINT: joined Crystal/App gate
  native_scalar += 1
  native_result = native_scalar + native_string.bytesize + native_array[0] + native_array[1] + native_breakpoint
  native_result
end

exit(crystal_gate == 628397 ? 0 : 1)
