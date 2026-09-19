#!/usr/bin/env sh
#
# Build libroc_vim_embed.so: the Roc compiler plus the glue that lets Vim run
# plugins straight from their source.
#
# It needs libroc_embed.a, which is built from the Roc compiler:
#
#     cd <roc checkout>
#     git apply <roc-vim>/compiler-patch/*.patch
#     zig build roc-embed -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
#     # -> zig-out/lib/libroc_embed.a
#
# Usage: ./build.sh [path/to/libroc_embed.a]
#        ROC_EMBED_LIB=/path/to/libroc_embed.a ./build.sh

set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

lib=${1:-${ROC_EMBED_LIB:-}}
if [ -z "$lib" ]; then
    for candidate in \
        "$here/libroc_embed.a" \
        "$here/../../zig-out/lib/libroc_embed.a" \
        "$HOME/.cache/roc-vim/libroc_embed.a"
    do
        if [ -f "$candidate" ]; then
            lib=$candidate
            break
        fi
    done
fi

if [ -z "$lib" ] || [ ! -f "$lib" ]; then
    cat >&2 <<EOF
roc-vim: could not find libroc_embed.a.

It comes from a Roc compiler built with compiler-patch/ applied:

    cd <roc checkout>
    git apply <roc-vim>/compiler-patch/roc-embed-library.patch
    zig build roc-embed -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe

Then pass it here:

    ./build.sh <roc checkout>/zig-out/lib/libroc_embed.a
EOF
    exit 1
fi

# The library is Zig's output, so it may want Zig's compiler-rt. `zig cc`
# supplies it; a plain C compiler needs libquadmath for the same symbols, and
# a library built with `bundle_compiler_rt` needs neither.
if [ -n "${ROC_VIM_CC:-}" ]; then
    link="$ROC_VIM_CC"
elif command -v zig >/dev/null 2>&1; then
    link="zig cc -target $(uname -m)-linux-gnu"
else
    link="${CC:-cc}"
fi

echo "roc-vim: linking libroc_vim_embed.so against $(basename "$lib")"

# shellcheck disable=SC2086
if ! $link -std=c11 -O2 -fPIC -shared -o libroc_vim_embed.so engine.c "$lib" -lm 2>link.log; then
    if grep -q "roundq\|__zig_" link.log; then
        # Symbols from Zig's compiler-rt that a plain C link does not pull in.
        echo "roc-vim: retrying with libquadmath"
        # shellcheck disable=SC2086
        $link -std=c11 -O2 -fPIC -shared -o libroc_vim_embed.so engine.c "$lib" -lm -lquadmath 2>>link.log \
            || { tail -20 link.log >&2; exit 1; }
    else
        tail -20 link.log >&2
        exit 1
    fi
fi
rm -f link.log

echo "roc-vim: built $here/libroc_vim_embed.so"
echo "roc-vim: point Vim at it with:  let g:roc_embed_library = '$here/libroc_vim_embed.so'"
