#!/usr/bin/env sh
#
# Build the native host for this platform.
#
# Roc links a plugin against `targets/<target>/libhost.a` plus the C runtime
# pieces for that target, so this script compiles host.c and puts everything
# where the platform's `targets:` section says to look.
#
# Usage: ./build.sh [target]
#   target defaults to the one Roc uses for this machine (musl on Linux).

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
    target="${roc_arch}musl"
fi

target_dir="targets/$target"
mkdir -p "$target_dir"

say() { printf 'roc-vim: %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Pick a C compiler that produces objects for the target's libc
# ---------------------------------------------------------------------------

case "$target" in
    *musl)
        if command -v musl-gcc >/dev/null 2>&1; then
            cc="musl-gcc"
            sysroot_cc="musl-gcc"
        elif command -v zig >/dev/null 2>&1; then
            cc="zig cc -target ${arch}-linux-musl"
            sysroot_cc="zig cc -target ${arch}-linux-musl"
        else
            cat >&2 <<'EOF'
roc-vim: no musl C compiler found.

Roc links plugins against musl by default, so the host has to be built against
musl too. Install one of these:

    Debian/Ubuntu:  sudo apt install musl-tools
    Alpine:         apk add musl-dev gcc
    Fedora:         sudo dnf install musl-gcc
    anywhere:       install Zig (this script will use `zig cc`)

Or build for glibc instead, and pass --target=x64glibc when building plugins:

    ./build.sh x64glibc
EOF
            exit 1
        fi
        ;;
    *glibc)
        cc="${CC:-cc}"
        sysroot_cc="${CC:-cc}"
        ;;
    *mac)
        cc="${CC:-cc}"
        sysroot_cc=""
        ;;
    *)
        echo "roc-vim: don't know how to build a host for $target" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------

say "building host for $target"
# shellcheck disable=SC2086
$cc -std=c11 -O2 -Wall -Wextra -fno-strict-aliasing -c host.c -o "$target_dir/host.o"
ar rcs "$target_dir/libhost.a" "$target_dir/host.o"
rm -f "$target_dir/host.o"

# ---------------------------------------------------------------------------
# Collect the C runtime pieces Roc links alongside the host
# ---------------------------------------------------------------------------

case "$target" in
    *musl)
        # Look in musl's own directories first. `musl-gcc -print-file-name` is a
        # wrapper around the system gcc and happily answers with glibc's copy,
        # which links but then wants half of libgcc.
        search_dirs="/usr/lib/$arch-linux-musl /usr/lib/musl/lib /usr/local/musl/lib /usr/lib/musl"
        ;;
    *)
        search_dirs="/usr/lib/$arch-linux-gnu /usr/lib /lib"
        ;;
esac

copy_runtime_file() {
    # copy_runtime_file <file>: find a C runtime file for this target, copy it
    found=""
    for dir in $search_dirs; do
        if [ -f "$dir/$1" ]; then
            found="$dir/$1"
            break
        fi
    done
    if [ -z "$found" ] && [ -n "$sysroot_cc" ]; then
        candidate=$($sysroot_cc -print-file-name="$1" 2>/dev/null || true)
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            found="$candidate"
        fi
    fi
    if [ -z "$found" ]; then
        echo "roc-vim: could not find $1 for $target" >&2
        exit 1
    fi
    cp -f "$found" "$target_dir/$1"
}

case "$target" in
    *musl)
        copy_runtime_file crt1.o
        copy_runtime_file crti.o
        copy_runtime_file crtn.o
        copy_runtime_file libc.a
        ;;
    *glibc)
        copy_runtime_file Scrt1.o
        copy_runtime_file crti.o
        copy_runtime_file crtn.o
        # libc.so is a linker script on many distributions; the real shared
        # object is what Roc's linker wants.
        if [ -f /usr/lib/"$arch"-linux-gnu/libc.so.6 ]; then
            cp -f /usr/lib/"$arch"-linux-gnu/libc.so.6 "$target_dir/libc.so"
        elif [ -f /lib/"$arch"-linux-gnu/libc.so.6 ]; then
            cp -f /lib/"$arch"-linux-gnu/libc.so.6 "$target_dir/libc.so"
        else
            copy_runtime_file libc.so
        fi
        ;;
    *mac) ;; # macOS links against the system libc without any extra inputs
esac

say "host ready: $target_dir/libhost.a"
