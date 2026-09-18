#!/usr/bin/env sh
#
# Build a Vim with the +roc feature: Roc plugins loaded into Vim's own process.
#
# This clones Vim, applies vim-roc-interface.patch, and builds it. Nothing is
# installed unless you pass --install, and the build stays inside a work
# directory you choose.
#
# Usage: ./build-vim.sh [--dir DIR] [--prefix PREFIX] [--install]
#   --dir DIR        where to clone and build (default: ./build)
#   --prefix PREFIX  where an --install would put it (default: ~/.local)
#   --install        run `make install` at the end

set -eu

here=$(cd "$(dirname "$0")" && pwd)
work="$here/build"
prefix="$HOME/.local"
do_install=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir) shift; work=$1 ;;
        --prefix) shift; prefix=$1 ;;
        --install) do_install=1 ;;
        -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

say() { printf 'roc-vim: %s\n' "$1"; }

for tool in git make cc; do
    command -v "$tool" >/dev/null 2>&1 || { echo "roc-vim: need $tool to build Vim" >&2; exit 1; }
done

mkdir -p "$work"
cd "$work"

if [ ! -d vim ]; then
    say "cloning Vim"
    git clone --depth 1 https://github.com/vim/vim.git vim
fi

cd vim
if git apply --check "$here/vim-roc-interface.patch" 2>/dev/null; then
    say "applying the +roc patch"
    git apply "$here/vim-roc-interface.patch"
elif git apply --reverse --check "$here/vim-roc-interface.patch" 2>/dev/null; then
    say "the +roc patch is already applied"
else
    cat >&2 <<EOF
roc-vim: the patch does not apply to this Vim.

It was made against Vim 9.2.1119. Vim moves fast, and the patch touches files
that change often (evalfunc.c, Makefile). Either check out that version:

    git -C "$work/vim" fetch --depth 1 origin v9.2.1119 && git -C "$work/vim" checkout FETCH_HEAD

or apply the pieces by hand: src/if_roc.c is new, and the rest is one entry
each in evalfunc.c, feature.h, proto.h, version.c, errors.h and the Makefile.
EOF
    exit 1
fi

say "configuring"
./configure --prefix="$prefix" \
    --with-features=huge \
    --enable-multibyte \
    --disable-gui \
    --without-x \
    --disable-netbeans \
    >configure.log 2>&1 || { tail -20 configure.log >&2; exit 1; }

say "building (this takes a few minutes)"
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" >build.log 2>&1 \
    || { tail -30 build.log >&2; exit 1; }

if ! ./src/vim --version | tr ' ' '\n' | grep -qx '+roc'; then
    echo "roc-vim: the build finished but has no +roc; see $work/vim/build.log" >&2
    exit 1
fi

say "built: $work/vim/src/vim (+roc)"

if [ "$do_install" -eq 1 ]; then
    make install
    say "installed to $prefix/bin/vim"
else
    cat <<EOF

Try it without installing:

    $work/vim/src/vim --version | grep roc

To install it: $0 --install --prefix $prefix
EOF
fi
