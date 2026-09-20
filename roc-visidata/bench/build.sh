#!/usr/bin/env sh
#
# Build the benchmark against libroc_embed.a.
#
#   ./build.sh <path/to/libroc_embed.a>
#   ROC_EMBED_LIB=... ./build.sh
#
# libroc_embed.a comes from a Roc compiler with roc-vim's compiler-patch
# applied; see roc-vim/compiler-patch/README.md.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lib=${1:-${ROC_EMBED_LIB:-$here/libroc_embed.a}}

if [ ! -f "$lib" ]; then
    echo "bench: no libroc_embed.a at $lib" >&2
    exit 1
fi

# The archive is Zig's output and may want Zig's compiler-rt; `zig cc` has it.
if [ -n "${BENCH_CC:-}" ]; then link="$BENCH_CC"
elif command -v zig >/dev/null 2>&1; then link="zig cc"
else link="${CC:-cc}"
fi

$link -O2 -o "$here/bench" "$here/bench.c" "$lib" \
    -I"$here/../../roc-vim/embed" -lm -lpthread
echo "bench: built $here/bench"
