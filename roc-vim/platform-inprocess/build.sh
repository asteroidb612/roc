#!/usr/bin/env sh
#
# Build the native host for the in-process platform.
#
# The host goes into the shared library that `roc build` produces, so it is
# compiled as position-independent code and left with undefined libc symbols:
# they resolve against Vim when the library is loaded.
#
# Usage: ./build.sh [target]

set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

arch=$(uname -m)
os=$(uname -s)

case "$arch" in
    x86_64 | amd64) roc_arch=x64 ;;
    aarch64 | arm64) roc_arch=arm64 ;;
    *)
        echo "roc-vim: unsupported architecture: $arch" >&2
        exit 1
        ;;
esac

if [ "$#" -ge 1 ]; then
    target=$1
elif [ "$os" = "Darwin" ]; then
    target="${roc_arch}mac"
else
    # A plugin is loaded into Vim, which brings its own libc, so build against
    # the system one rather than musl.
    target="${roc_arch}glibc"
fi

target_dir="targets/$target"
mkdir -p "$target_dir"

cc=${CC:-cc}
echo "roc-vim: building in-process host for $target"
$cc -std=c11 -O2 -fPIC -Wall -Wextra -fno-strict-aliasing -c host.c -o "$target_dir/host.o"
ar rcs "$target_dir/libhost.a" "$target_dir/host.o"
rm -f "$target_dir/host.o"
echo "roc-vim: host ready: $target_dir/libhost.a"
