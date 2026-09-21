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

    # ---- the Roc loader -------------------------------------------------
    print("\nRoc loader (the table stays in Roc):")
    plugin = vd.rocLoad(os.path.join(HERE, "..", "examples", "tsv_loader.roc"))
    if plugin is None:
        print("  could not load tsv_loader.roc", file=sys.stderr)
        return 1

    answer, _ = timed("parse", lambda: plugin.event("loader", {"q": "load", "path": PATH}), N)
    if not answer or not answer.get("ok"):
        print(f"  loader failed: {answer}", file=sys.stderr)
        return 1
    print(f"    (loaded {answer['nrows']} rows, columns {answer['columns']})")

    timed("screenful (50 rows x 3 cols)",
          lambda: plugin.event("loader", {"q": "rows", "from": 0, "to": 50}))
    timed("whole column",
          lambda: plugin.event("loader", {"q": "rows", "from": 0, "to": N}), N, iters=1)

    print("\nNote: the Roc 'whole column' request returns every field of every "
          "row as JSON,\nwhich is the honest cost of asking Roc for everything "
          "at once today.\nThe screenful is the case the design is actually "
          "built around.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
