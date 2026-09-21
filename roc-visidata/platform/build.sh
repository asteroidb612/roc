#!/usr/bin/env sh
#
# Build targets/libhost.a: what a *compiled* Roc plugin links against.
#
# The interpreted tier needs none of this — the engine carries the same hosted
# functions. This is only for the compiled tier, where a plugin is built into a
# shared library that VisiData dlopens.
#
#     ./build.sh            # for this machine
#
# Then a plugin is built with the Roc compiler:
#
#     roc build --output-type shared my_plugin.roc
set -eu

here=$(cd "$(dirname "$0")" && pwd)

# Roc looks for each target's inputs in its own directory under targets/.
# Build for this machine unless told otherwise.
if [ -n "${ROC_VD_TARGET:-}" ]; then
    target=$ROC_VD_TARGET
else
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64)  target=x64glibc ;;
        Linux-aarch64) target=arm64glibc ;;
        Darwin-x86_64) target=x64mac ;;
        Darwin-arm64)  target=arm64mac ;;
        *) echo "build.sh: unknown platform $(uname -s)-$(uname -m); set ROC_VD_TARGET" >&2
           exit 1 ;;
    esac
fi

out="$here/targets/$target"
mkdir -p "$out"

cc=${ROC_VD_CC:-${CC:-cc}}
$cc -c -O2 -fPIC -o "$out/host.o" "$here/host.c" -I"$here"
ar rcs "$out/libhost.a" "$out/host.o"
rm -f "$out/host.o"

echo "roc-visidata: built $out/libhost.a"
