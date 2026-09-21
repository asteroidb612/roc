#!/usr/bin/env sh
#
# Build libroc_vd_engine.so: the Roc compiler plus the glue that lets VisiData
# run plugins straight from their source.
#
# It needs libroc_embed.a, which is built from the Roc compiler:
#
#     cd <roc checkout>
#     git apply <roc-visidata>/../roc-vim/compiler-patch/roc-embed-library.patch
#     zig build roc-embed -Doptimize=ReleaseSafe
#     # -> zig-out/lib/libroc_embed.a
#
# Usage: ./build.sh [path/to/libroc_embed.a]
#        ROC_EMBED_LIB=/path/to/libroc_embed.a ./build.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
lib=${1:-${ROC_EMBED_LIB:-}}

if [ -z "$lib" ]; then
    for candidate in \
        "$here/libroc_embed.a" \
        "$HOME/.cache/roc-visidata/libroc_embed.a"
    do
        [ -f "$candidate" ] && { lib=$candidate; break; }
    done
fi

if [ -z "$lib" ] || [ ! -f "$lib" ]; then
    cat >&2 <<MSG
roc-visidata: could not find libroc_embed.a.

It comes from a Roc compiler built with the embedding patch applied:

    cd <roc checkout>
    git apply <roc-visidata>/../roc-vim/compiler-patch/roc-embed-library.patch
    zig build roc-embed -Doptimize=ReleaseSafe

Then pass it here:

    ./build.sh <roc checkout>/zig-out/lib/libroc_embed.a
MSG
    exit 1
fi

# The archive is Zig's output and may want Zig's compiler-rt; `zig cc` has it,
# and a library built with bundle_compiler_rt needs neither.
if [ -n "${ROC_VD_CC:-}" ]; then link="$ROC_VD_CC"
elif command -v zig >/dev/null 2>&1; then link="zig cc"
else link="${CC:-cc}"
fi

out=$here/libroc_vd_engine.so
$link -O2 -fPIC -shared -o "$out" "$here/engine.c" "$lib" \
    -I"$here" -I"$here/../../roc-vim/embed" -lm -lpthread

if command -v strip >/dev/null 2>&1; then strip "$out" || true; fi
echo "roc-visidata: built $out ($(du -h "$out" | cut -f1))"
