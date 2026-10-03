#include <stddef.h>

typedef union DebuggerUnion {
  int integer;
  const char *text;
} DebuggerUnion;

typedef struct DebuggerNested {
  int value;
} DebuggerNested;

int main(void) {
  volatile int debugger_sentinel = 271828;
  const char *debugger_string_empty = "";
  const char *debugger_string_utf8 = "snowman \xE2\x98\x83";
  const char debugger_string_nul[] = "left\0right";
  int debugger_array_empty[0] = {};
  int debugger_array[2] = {22, 44};
  DebuggerUnion debugger_union_int = {.integer = 22};
  DebuggerUnion debugger_union_string = {.text = "forty-four"};
  const char *debugger_nullable_string_nil = NULL;
  const char *debugger_nullable_string_value = "present";
  const char *debugger_nullable_pointer_nil = NULL;
  const char *debugger_nullable_pointer_value = "pointer";
  volatile int debugger_shadowed = 10;
  volatile int debugger_out_of_scope_sink = 0;
  DebuggerNested debugger_nested_outer = {31};

  {
    volatile int debugger_out_of_scope = 90;
    debugger_out_of_scope_sink = debugger_out_of_scope;
  }

  {
    volatile int debugger_shadowed = 20;
    volatile int debugger_nested = debugger_nested_outer.value;
    volatile int debugger_marker = debugger_sentinel; /* DAP_BREAKPOINT: locals */
    volatile int debugger_after_step = debugger_marker + debugger_shadowed; /* DAP_AFTER_STEP */
    volatile int debugger_sink = debugger_after_step + debugger_nested + debugger_nested_outer.value;
    debugger_sink += debugger_array[0] + debugger_array[1];
    debugger_sink += debugger_union_int.integer + debugger_union_string.text[0];
    debugger_sink += debugger_string_empty[0] + debugger_string_utf8[0] + debugger_string_nul[0];
    debugger_sink += debugger_nullable_string_value[0] + debugger_nullable_pointer_value[0];
    debugger_sink += sizeof(debugger_array_empty);
    return debugger_sink == -1 ? 1 : 0;
  }
}
