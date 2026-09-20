#!/usr/bin/env sh
#
# Build the one Roc compiler roc-vim uses: roc-lang/roc at the pinned commit,
# with this directory's patches applied.
#
# It clones Roc, applies the patches, and builds two things:
#
#     zig-out/bin/roc          the compiler, for building plugins
#     zig-out/lib/libroc_embed.a   the embedding library, for embed/build.sh
#
# Nothing is installed; everything stays in a work directory. The rest of
# roc-vim looks for the results here, so `./setup.sh` and the tests find them
# without being told where they are.
#
# Usage: ./build-roc.sh [--dir DIR] [--debug] [--compiler-only] [--skip-build]
#   --dir DIR        where to clone and build (default: ./build)
#   --debug          build unoptimized: faster to build, and a ~3GB binary
#   --compiler-only  skip libroc_embed.a (no source-loading, much quicker)
#   --skip-build     clone and patch, but stop before compiling

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
. "$repo/versions.sh"

work="$here/build"
optimize=ReleaseSafe
compiler_only=0
skip_build=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir) shift; work=$1 ;;
        --debug) optimize=Debug ;;
        --compiler-only) compiler_only=1 ;;
        --skip-build) skip_build=1 ;;
        -h | --help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

say() { printf 'roc-vim: %s\n' "$1"; }

# ---------------------------------------------------------------------------
# What we need
# ---------------------------------------------------------------------------

command -v git >/dev/null 2>&1 || { echo "roc-vim: need git" >&2; exit 1; }

if [ "$skip_build" -eq 0 ]; then
    if ! command -v zig >/dev/null 2>&1; then
        cat >&2 <<EOF
roc-vim: the Roc compiler is written in Zig, and zig is not on your PATH.

It has to be exactly $ROC_VIM_ZIG_VERSION. The easiest way to get that one:

    pip install ziglang==$ROC_VIM_ZIG_VERSION
    export PATH="\$(python3 -c 'import ziglang,os;print(os.path.dirname(ziglang.__file__))'):\$PATH"

or download it from https://ziglang.org/download/
EOF
        exit 1
    fi
    have_zig=$(zig version)
    case "$have_zig" in
        "$ROC_VIM_ZIG_VERSION"*) ;;
        *)
            echo "roc-vim: this is Zig $have_zig, and Roc wants $ROC_VIM_ZIG_VERSION" >&2
            echo "roc-vim: set PATH to a $ROC_VIM_ZIG_VERSION, or pass --skip-build to stop after patching" >&2
            exit 1
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Clone, at the commit the patches are made against
# ---------------------------------------------------------------------------

mkdir -p "$work"
cd "$work"

if [ ! -d roc ]; then
    say "fetching roc-lang/roc at $ROC_VIM_ROC_COMMIT ($ROC_VIM_ROC_DATE)"
    mkdir roc
    (
        cd roc
        git init -q .
        git remote add origin https://github.com/roc-lang/roc.git
        # One commit, no history: the whole repository is a long download.
        git fetch -q --depth 1 origin "$ROC_VIM_ROC_COMMIT"
        git checkout -q FETCH_HEAD
    )
fi

cd roc
at=$(git rev-parse HEAD)
if [ "$at" != "$ROC_VIM_ROC_COMMIT" ]; then
    say "warning: this checkout is at $at, not the pinned $ROC_VIM_ROC_COMMIT"
    say "warning: the patches may not apply; remove $work/roc to start again"
fi

# ---------------------------------------------------------------------------
# Patch
# ---------------------------------------------------------------------------

for patch in roc-shared-library-static-data.patch roc-embed-library.patch; do
    if git apply --check "$here/$patch" 2>/dev/null; then
        say "applying $patch"
        git apply "$here/$patch"
    elif git apply --reverse --check "$here/$patch" 2>/dev/null; then
        say "$patch is already applied"
    else
        echo "roc-vim: $patch does not apply to this checkout" >&2
        echo "roc-vim: it is made against $ROC_VIM_ROC_COMMIT; see compiler-patch/README.md" >&2
        exit 1
    fi
done

if [ "$skip_build" -eq 1 ]; then
    say "cloned and patched: $work/roc (stopping before the build)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

say "building the compiler ($optimize; this takes a while)"
zig build roc -Doptimize="$optimize" >build-roc.log 2>&1 \
    || { tail -30 build-roc.log >&2; exit 1; }

if [ ! -x zig-out/bin/roc ]; then
    echo "roc-vim: the build finished but there is no zig-out/bin/roc" >&2
    exit 1
fi
say "built: $work/roc/zig-out/bin/roc ($(./zig-out/bin/roc --version))"

if [ "$compiler_only" -eq 1 ]; then
    say "skipping libroc_embed.a (--compiler-only)"
else
    say "building the embedding library (this takes a while too)"
    zig build roc-embed -Doptimize="$optimize" >build-embed.log 2>&1 \
        || { tail -30 build-embed.log >&2; exit 1; }
    if [ ! -f zig-out/lib/libroc_embed.a ]; then
        echo "roc-vim: the build finished but there is no zig-out/lib/libroc_embed.a" >&2
        exit 1
    fi
    say "built: $work/roc/zig-out/lib/libroc_embed.a"
fi

cat <<EOF

Done. Nothing was installed; $repo finds these on its own.

Next:
    $repo/embed/build.sh        # the engine, so Vim can run plugins from source
    $repo/vim-patch/build-vim.sh  # a Vim with +roc
    $repo/setup.sh              # the hosts, the Vim package, a plugin directory
EOF
