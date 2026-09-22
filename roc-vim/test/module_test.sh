#!/usr/bin/env sh
#
# Run every `expect` test in the repository, wherever it lives.
#
# `roc test` runs an `expect` line without needing a real Vim behind it, as
# long as the expression itself does not call a hosted effect - it does not
# matter whether the file is a plugin, an app, a module, or the platform
# itself. So this looks for every .roc file with a test in it, not just ones
# pulled out into their own module.
#
# Usage: ./module_test.sh [file.roc ...]   (default: every test it can find)

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
    # Everywhere but the vendored compiler build and the Vim build, which are
    # not this repository's code.
    modules=$(find "$repo" -name '*.roc' \
            -not -path "$repo/compiler-patch/build/*" \
            -not -path "$repo/vim-patch/build/*" \
        | xargs grep -l '^expect ' 2>/dev/null | sort)
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
