#!/usr/bin/env sh
#
# Every number in RESULTS.md, in the order it appears there.
#
#   ./build.sh /path/to/libroc_embed.a && ./run.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
[ -x ./bench ] || { echo "run ./build.sh first" >&2; exit 1; }

echo "########## 1. Compile latency: what starting a plugin costs ##########"
echo
echo "--- a plugin importing nothing, cold ---"
rm -rf "${HOME}/.cache/roc" 2>/dev/null || true
./bench apps/tiny.roc 1000 2 1 | head -3
echo
echo "--- a realistic plugin (imports the platform's 620-line Value), cold ---"
rm -rf "${HOME}/.cache/roc" 2>/dev/null || true
./bench apps/plugin.roc 1000 3 1 | head -3
echo
echo "--- the same plugin, warm (compiler cache populated) ---"
./bench apps/plugin.roc 1000 3 3 | head -3
echo
echo "########## 2. The bulk path: one call over a whole column ##########"
for n in 10000 100000 1000000; do
    echo
    ./bench apps/map_light.roc "$n" 5 1 | grep -E "^== |C loop|marshal|map \("
    echo
    python3 python_baseline.py "$n" 3 | grep -vE "^== "
done
echo
echo "########## 3. The Python-side floor the bulk path cannot avoid ##########"
echo
python3 marshal_baseline.py 1000000 3
