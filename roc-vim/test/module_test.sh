#!/usr/bin/env sh
#
# Run the `expect` tests inside plugin modules.
#
# A module with no platform in it is just Roc, so `roc test` can run it: no
# Vim, no plugin, no build step. That is the reason to pull logic out of a
# plugin and into a module in the first place.
#
# Usage: ./module_test.sh [file.roc ...]   (default: every module it can find)

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
. "$repo/versions.sh"

roc=$(roc_vim_find_roc "$repo")
if [ -z "$roc" ]; then
    echo "SKIP: no roc compiler; build one with compiler-patch/build-roc.sh"
    exit 0
fi

if [ "$#" -gt 0 ]; then
    modules=$*
else
    # A plugin kept as a directory is main.roc plus the modules it imports.
    modules=$(find "$repo/examples-inprocess" "$repo/examples" -mindepth 2 -name '*.roc' 2>/dev/null \
        | grep -v '/main\.roc$' | sort)
fi

if [ -z "$modules" ]; then
    echo "no modules found"
    exit 0
fi

failures=0
for module in $modules; do
    printf '%s: ' "${module#"$repo/"}"
    if output=$("$roc" test "$module" 2>&1); then
        # Among the notes roc prints is one about type modules being preferred;
        # the line worth showing is the count.
        printf '%s\n' "$(printf '%s\n' "$output" | grep -E 'tests? passed|tests? failed' || echo 'passed')"
    else
        printf 'FAILED\n'
        printf '%s\n' "$output" | sed 's/^/    /'
        failures=$((failures + 1))
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures module(s) failed"
    exit 1
fi
echo "all module tests passed"
