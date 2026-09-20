#!/usr/bin/env sh
#
# Every number in RESULTS.md, in the order it appears there.
#
#   ./build.sh /path/to/libroc_embed.a && ./run.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

if [ ! -x ./bench ]; then echo "run ./build.sh first" >&2; exit 1; fi

echo "###############################################################"
echo "# 1. Compile latency: what starting a plugin costs"
echo "###############################################################"
echo
echo "--- cold (compiler cache cleared) ---"
rm -rf "${HOME}/.cache/roc" 2>/dev/null || true
./bench apps/plugin.roc 1000 1 1
echo
echo "--- warm (same plugin, cache populated) ---"
./bench apps/plugin.roc 1000 1 3
echo
echo "--- floor: a plugin importing nothing ---"
rm -rf "${HOME}/.cache/roc" 2>/dev/null || true
./bench apps/tiny.roc 1000 1 1
echo

echo "###############################################################"
echo "# 2. The bulk path: one call over a whole column"
echo "###############################################################"
for n in 10000 1000000 10000000; do
    echo
    ./bench apps/map_light.roc "$n" 5 1
    echo
    python3 python_baseline.py "$n" 5
done
echo
echo "###############################################################"
echo "# 3. The Python-side floor the bulk path cannot avoid"
echo "###############################################################"
echo
python3 marshal_baseline.py 1000000 5
