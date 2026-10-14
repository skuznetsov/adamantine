/* Test-only libraries for exercising preflight without another Lua install. */
#include <stdlib.h>

#if defined(FAKE_LUA_53)
const double *lua_version(void *state) {
  (void)state;
  abort();
}
#else
void lua_newuserdatauv(void) {}

double lua_version(void *state) {
  (void)state;
  return 505.0;
}
#endif
