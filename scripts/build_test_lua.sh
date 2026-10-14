#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 PRIVATE_OUTPUT_DIRECTORY" >&2
  exit 2
fi

output_dir=$1
if [[ "$output_dir" != /* ]]; then
  echo "output directory must be an absolute private path" >&2
  exit 2
fi
mkdir -p "$output_dir"
build_dir=$(mktemp -d "$output_dir/lua-5.4.9.XXXXXX")
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
archive="$build_dir/lua-5.4.9.tar.gz"
source_dir="$build_dir/lua-5.4.9"
url="https://www.lua.org/ftp/lua-5.4.9.tar.gz"
sha256="2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6"

curl --fail --location --silent --show-error "$url" --output "$archive"
if command -v shasum >/dev/null 2>&1; then
  checksum_cmd=(shasum -a 256 --check --status)
elif command -v sha256sum >/dev/null 2>&1; then
  checksum_cmd=(sha256sum --check --status)
else
  echo "a SHA-256 checksum utility is required" >&2
  exit 1
fi
printf '%s  %s\n' "$sha256" "$archive" | "${checksum_cmd[@]}" || {
  echo "Lua 5.4.9 archive checksum mismatch" >&2
  exit 1
}
tar -xzf "$archive" -C "$build_dir"

src="$source_dir/src"
sources=(
  "$src/lapi.c" "$src/lcode.c" "$src/lctype.c" "$src/ldebug.c"
  "$src/ldo.c" "$src/ldump.c" "$src/lfunc.c" "$src/lgc.c"
  "$src/llex.c" "$src/lmem.c" "$src/lobject.c" "$src/lopcodes.c"
  "$src/lparser.c" "$src/lstate.c" "$src/lstring.c" "$src/ltable.c"
  "$src/ltm.c" "$src/lundump.c" "$src/lvm.c" "$src/lzio.c"
  "$src/lauxlib.c" "$src/lbaselib.c" "$src/lcorolib.c" "$src/ldblib.c"
  "$src/liolib.c" "$src/lmathlib.c" "$src/loadlib.c" "$src/loslib.c"
  "$src/lstrlib.c" "$src/ltablib.c" "$src/lutf8lib.c" "$src/linit.c"
)

case "$(uname -s)" in
  Darwin)
    library="$build_dir/liblua54.dylib"
    cc -O2 -fPIC -dynamiclib -DLUA_USE_MACOSX \
      -Wl,-install_name,@rpath/liblua54.dylib "${sources[@]}" -lm -o "$library"
    cc -O2 -fPIC -dynamiclib "$repo_root/spec/fixtures/lua_wrong_abi.c" \
      -DFAKE_LUA_53 -o "$build_dir/liblua53fake.dylib"
    cc -O2 -fPIC -dynamiclib "$repo_root/spec/fixtures/lua_wrong_abi.c" \
      -o "$build_dir/liblua55fake.dylib"
    ;;
  Linux)
    library="$build_dir/liblua54.so"
    cc -O2 -fPIC -shared -DLUA_USE_LINUX \
      -Wl,-soname,liblua54.so "${sources[@]}" -lm -ldl -o "$library"
    cc -O2 -fPIC -shared "$repo_root/spec/fixtures/lua_wrong_abi.c" \
      -DFAKE_LUA_53 -o "$build_dir/liblua53fake.so"
    cc -O2 -fPIC -shared "$repo_root/spec/fixtures/lua_wrong_abi.c" \
      -o "$build_dir/liblua55fake.so"
    ;;
  *)
    echo "test Lua builder supports only macOS and Linux" >&2
    exit 1
    ;;
esac

printf '%s\n' "$library"
