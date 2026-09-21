"""A Roc loader against VisiData's own, on the same file.

This is the measurement M4 exists to make. The plan's speed case rests on Roc
owning the data — a loader whose columns never cross into Python per row — and
this is the comparison that says whether that is worth anything.

Three things are timed, because they are three different claims:

  parse       reading the file into whatever the loader keeps
  screenful   the ~50 rows about to be drawn
  column      every value in one column, which is what sort and aggregate need

    python3 bench/loader_bench.py [rows]
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

N = int(sys.argv[1]) if len(sys.argv) > 1 else 200_000
ITERS = 3
PATH = f"/tmp/roc_loader_bench_{N}.tsv"


def make_file():
    if os.path.exists(PATH):
        return
    with open(PATH, "w") as f:
        f.write("name\tamount\tregion\n")
        for i in range(N):
            f.write(f"row{i}\t{i}.5\t{'east' if i % 2 else 'west'}\n")


def timed(label, fn, n=None, iters=ITERS):
    samples = []
    out = None
    for _ in range(iters):
        t0 = time.perf_counter()
        out = fn()
        samples.append((time.perf_counter() - t0) * 1000.0)
    best = min(samples)
    per = f"{best * 1e6 / n:9.1f} ns/row" if n else ""
    print(f"  {label:<34} best {best:9.2f} ms  {per}")
    return out, best


def main():
    make_file()
    print(f"== {PATH} ({N} rows) ==\n")

    from visidata import vd
    import visidata_roc                                    # noqa: F401
    from visidata.loaders.tsv import TsvSheet
    from visidata import Path

    # ---- VisiData's own TSV loader -------------------------------------
    print("VisiData's tsv loader:")

    def vd_parse():
        sheet = TsvSheet("bench", source=Path(PATH))
        sheet.rows = list(sheet.iterload())
        return sheet

    sheet, _ = timed("parse", vd_parse, N)

    # iterload yields the header as the first row and leaves column setup to
    # the sheet machinery, which a headless run skips; build the same
    # ItemColumns SequenceSheet would, so the access numbers are like for like.
    from visidata import ItemColumn

    header, sheet.rows = sheet.rows[0], sheet.rows[1:]
    cols = [ItemColumn(name, i) for i, name in enumerate(header)]
    for col in cols:
        col.sheet = sheet
    amount = cols[1]

    timed("screenful (50 rows x 3 cols)",
          lambda: [[c.getValue(r) for c in cols] for r in sheet.rows[:50]])
    timed("whole column",
          lambda: [amount.getValue(r) for r in sheet.rows], N)

    # ---- the Roc loader, interpreted ------------------------------------
    # Interpreted parsing is ~240 us/row, so a full-size run here would take
    # minutes and say nothing a smaller one does not. It is linear (see
    # RESULTS.md §4), so measure it on a slice and report ns/row.
    interp_n = min(N, 20_000)
    interp_path = PATH
    if interp_n != N:
        interp_path = f"/tmp/roc_loader_bench_interp_{interp_n}.tsv"
        if not os.path.exists(interp_path):
            with open(PATH) as src, open(interp_path, "w") as dst:
                for i, line in enumerate(src):
                    if i > interp_n:
                        break
                    dst.write(line)

    print(f"\nRoc loader, interpreted ({interp_n} rows; it is linear):")
    # Measure the interpreted tier as itself: with a compiler on PATH the
    # manager would upgrade this plugin to native in the background and swap
    # it out mid-benchmark.
    vd.options.roc_compile = False
    plugin = vd.rocLoad(os.path.join(HERE, "..", "examples", "tsv_loader.roc"))
    if plugin is None:
        print("  could not load tsv_loader.roc", file=sys.stderr)
        return 1

    answer, _ = timed("parse",
                      lambda: plugin.event("loader", {"q": "load", "path": interp_path}),
                      interp_n, iters=1)
    if not answer or not answer.get("ok"):
        print(f"  loader failed: {answer}", file=sys.stderr)
        return 1

    timed("screenful (50 rows x 3 cols)",
          lambda: plugin.event("loader", {"q": "rows", "from": 0, "to": 50}), iters=1)

    # ---- the same loader, compiled --------------------------------------
    from visidata_roc.tier2 import CompiledPlugin, build, find_compiler

    if not find_compiler():
        print("\nNo roc compiler on PATH, so the compiled tier is not measured.")
        return 0

    print(f"\nRoc loader, compiled ({N} rows):")
    source = os.path.join(HERE, "..", "examples", "tsv_loader.roc")
    t0 = time.perf_counter()
    library = build(source)
    print(f"  (built in {time.perf_counter() - t0:.1f}s, "
          f"{os.path.getsize(library) / 1024:.0f} KB)")

    compiled = CompiledPlugin(vd.rocEngine, source, library, 4242)
    answer, _ = timed("parse", lambda: compiled.event("loader", {"q": "load", "path": PATH}), N)
    if not answer or not answer.get("ok"):
        print(f"  compiled loader failed: {answer}", file=sys.stderr)
        return 1

    timed("screenful (50 rows x 3 cols)",
          lambda: compiled.event("loader", {"q": "rows", "from": 0, "to": 50}))
    timed("whole column, as JSON",
          lambda: compiled.event("loader", {"q": "rows", "from": 0, "to": N}), N, iters=1)

    def typed_column():
        compiled.event("loader", {"q": "col_f64", "col": 1})
        return compiled.take_floats()

    values, _ = timed("whole column, typed", typed_column, N)
    print(f"    ({len(values)} numbers, first {values[:3]})")

    print("\nThe JSON row is every field of every row encoded as text, which is "
          "what\nasking Roc for everything at once used to cost. The typed row "
          "is the same\ncolumn through reply_floats!, which hands the numbers "
          "over as bytes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
