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

repo=$(dirname "$here")
. "$repo/versions.sh"

lib=${1:-${ROC_EMBED_LIB:-}}
if [ -z "$lib" ]; then
    for candidate in \
        "$repo/$ROC_VIM_ROC_BUILD/zig-out/lib/libroc_embed.a" \
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

It is built along with the compiler, by one script:

    $repo/compiler-patch/build-roc.sh

That leaves it at $repo/$ROC_VIM_ROC_BUILD/zig-out/lib/libroc_embed.a,
which is where this script looks. If yours is somewhere else, say so:

    ./build.sh /path/to/libroc_embed.a
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

# --no-undefined is load-bearing: without it a shared library links happily
# with symbols nobody defines, and the failure only shows up as a dlopen error
# inside Vim, long after this script has said it succeeded.
case "$(uname -s)" in
    Darwin) undefined_is_an_error="-Wl,-undefined,error" ;;
    *) undefined_is_an_error="-Wl,--no-undefined" ;;
esac

link_engine() {
    # shellcheck disable=SC2086
    $link -std=c11 -O2 -fPIC -shared $undefined_is_an_error \
        -o libroc_vim_embed.so engine.c "$lib" -lm "$@" 2>>link.log
}

: > link.log
if ! link_engine; then
    if grep -q "roundq\|__zig_\|quadmath" link.log; then
        # Zig's compiler-rt. A library built by build-roc.sh carries its own
        # (bundle_compiler_rt), so this is for older ones, where glibc's
        # libquadmath has the same long-double helpers.
        echo "roc-vim: retrying with libquadmath"
        if ! link_engine -lquadmath; then
            tail -20 link.log >&2
            echo "roc-vim: if this names Zig runtime symbols, link with zig instead:" >&2
            echo "roc-vim:     ROC_VIM_CC=\"zig cc -target \$(uname -m)-linux-gnu\" ./build.sh" >&2
            exit 1
        fi
    else
        tail -20 link.log >&2
        exit 1
    fi
fi
rm -f link.log

# Say it works only if it loads. A library that links but will not dlopen is
# worse than one that failed to build, because Vim is where you find out.
if command -v cc >/dev/null 2>&1; then
    check=$(mktemp -d)
    cat > "$check/check.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    return dlsym(handle, "roc_vim_source_load") == NULL ? 2 : 0;
}
EOF
    if cc -o "$check/check" "$check/check.c" -ldl 2>/dev/null; then
        if ! "$check/check" "$here/libroc_vim_embed.so"; then
            echo "roc-vim: the library was linked, but it does not load." >&2
            echo "roc-vim: try:  ROC_VIM_CC=\"zig cc -target \$(uname -m)-linux-gnu\" ./build.sh" >&2
            rm -rf "$check"
            exit 1
        fi
    fi
    rm -rf "$check"
fi

echo "roc-vim: built $here/libroc_vim_embed.so"
echo "roc-vim: point Vim at it with:  let g:roc_embed_library = '$here/libroc_vim_embed.so'"
