#!/usr/bin/env sh
#
# Everything, in the order it gets harder to run.
#
#   ./test/run.sh
#
# engine_test needs the engine (engine/build.sh). visidata_test needs VisiData
# installed. tier2_test needs a roc compiler on PATH, and says so and passes if
# there is none, because running interpreted is a supported configuration.
set -eu
here=$(cd "$(dirname "$0")" && pwd)

echo "== engine (no VisiData) =="
python3 "$here/engine_test.py"
echo
echo "== inside VisiData =="
python3 "$here/visidata_test.py"
echo
echo "== the compiled tier =="
python3 "$here/tier2_test.py"
echo
echo "== Roc loaders =="
python3 "$here/loader_test.py"
echo
echo "== the real vd, in a pty =="
python3 "$here/vd_pty_test.py"
