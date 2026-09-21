"""The compiled tier: the same plugin, as machine code.

Skipped with a message when no `roc` compiler is installed, because that is a
supported way to run roc-visidata — commands and config do not need one.

    python3 test/tier2_test.py
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from visidata import ItemColumn, Sheet, vd                  # noqa: E402

import visidata_roc                                         # noqa: E402,F401
from visidata_roc.tier2 import (CompiledPlugin, build,      # noqa: E402
                                find_compiler, native_target)


def check(condition, what):
    if not condition:
        raise AssertionError(what)
    print(f"  ok: {what}")


def main():
    compiler = find_compiler()
    if not compiler:
        print("tier2_test: no roc compiler on PATH, skipping.")
        print("  (this is a supported configuration: plugins run interpreted)")
        return 0

    print(f"compiler: {compiler}")
    print(f"target:   {native_target()}")

    rows = [{"name": f"row{i}", "amount": i * 1.5} for i in range(1000)]
    sheet = Sheet("sales.csv", rows=rows,
                  columns=[ItemColumn("name"), ItemColumn("amount", type=float)])
    sheet.rows = rows
    vd.sheets = [sheet]

    source = os.path.join(HERE, "..", "examples", "hello.roc")

    t0 = time.perf_counter()
    library = build(source)
    elapsed = time.perf_counter() - t0
    check(os.path.exists(library), f"hello.roc built to a shared library ({elapsed:.1f}s)")

    t0 = time.perf_counter()
    again = build(source)
    cached = time.perf_counter() - t0
    check(again == library and cached < 0.5,
          f"building it again is cached ({cached * 1000:.1f} ms)")

    plugin = CompiledPlugin(vd.rocEngine, source, library, 9001)
    check(plugin.transport == "compiled", "it reports itself as compiled")

    replied = plugin.event("command:roc-hello", vd.rocContext())
    said = " ".join(str(s) for s in vd.statuses)
    check("hello from Roc" in said, "the compiled plugin said hello")
    check("sales.csv" in said and "1000 rows" in said,
          "it read the real sheet through eval!, the same as interpreted")
    check(replied == 1, f"it replied with its model (got {replied!r})")

    plugin.event("command:roc-hello", vd.rocContext())
    said = " ".join(str(s) for s in vd.statuses)
    check("greeting 2" in said, "its model carried over between events")

    # The upgrade path: load interpreted, then swap.
    vd.options.roc_compile = True
    interpreted = vd.rocLoad(source)
    check(interpreted is not None, "the same plugin also loads interpreted")
    thread = vd.rocUpgrade(interpreted)
    if thread:
        thread.join(timeout=120)
    swapped = vd.rocPlugins.get(interpreted.handle)
    check(swapped is not None and swapped.transport == "compiled",
          f"the manager upgraded it in the background (now {getattr(swapped, 'transport', None)})")

    plugin.unload()
    vd.rocUnloadAll()
    print("\ntier2_test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
