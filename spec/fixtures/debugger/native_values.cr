def native_values_probe : Int32
  native_string_empty = ""
  native_string_utf8 = "snowman ☃"
  native_string_nul = "left\0right"
  native_string_long = "x" * 2048
  native_array_empty = [] of Int32
  native_array = [22, 44]
  native_array_large = Array(Int32).new(300) { |index| index }
  native_array_shifted = [3, 5, 7]
  native_array_shifted.shift

  native_values_marker = 314159 # DAP_BREAKPOINT: native values
  native_values_sink = native_values_marker
  native_values_sink += native_string_empty.bytesize + native_string_utf8.bytesize
  native_values_sink += native_string_nul.bytesize + native_string_long.bytesize
  native_values_sink += native_array_empty.size + native_array[0] + native_array[1]
  native_values_sink += native_array_large[299]
  native_values_sink += native_array_shifted[0] + native_array_shifted[1]
  native_values_sink
end

exit(native_values_probe == 314159 + 11 + 10 + 2048 + 66 + 299 + 12 ? 0 : 1)
