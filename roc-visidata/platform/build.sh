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
targets="$here/targets"
mkdir -p "$targets"

cc=${ROC_VD_CC:-${CC:-cc}}
$cc -c -O2 -fPIC -o "$targets/host.o" "$here/host.c" -I"$here"
ar rcs "$targets/libhost.a" "$targets/host.o"
rm -f "$targets/host.o"

echo "roc-visidata: built $targets/libhost.a"
