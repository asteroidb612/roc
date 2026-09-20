"""What the same derived column costs in Python today.

Three baselines, because they are three different claims:

  listcomp  - the fastest way to write it in plain Python
  evalExpr  - what VisiData actually does for an `=` column: a compiled
              expression evaluated once per row against that row's scope
              (visidata/expr.py, ExprColumn.calcValue -> sheet.evalExpr)
  numpy     - for context, where the data happens to be numeric and dense
"""

import sys, time

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
ITERS = int(sys.argv[2]) if len(sys.argv) > 2 else 5

xs = [i * 0.5 for i in range(N)]


def bench(label, fn, n=N):
    samples = []
    for _ in range(ITERS):
        t0 = time.perf_counter()
        out = fn()
        samples.append((time.perf_counter() - t0) * 1000.0)
    best, mean = min(samples), sum(samples) / len(samples)
    print(f"{label:<22} best {best:9.3f} ms   mean {mean:9.3f} ms"
          f"   {best * 1e6 / n:8.1f} ns/element (best)")
    return out


print(f"== python   n={N} ==")

bench("listcomp", lambda: [x * 2.5 + 1.0 for x in xs])

code = compile("x * 2.5 + 1.0", "<expr>", "eval")
g = {}
def evalexpr():
    # VisiData evaluates the compiled expression per row, with the row's
    # columns supplying the names. One dict build + one eval per row.
    return [eval(code, g, {"x": x}) for x in xs]
bench("evalExpr (per row)", evalexpr)


# What VisiData actually runs for an `=` column over a whole sheet, kept close
# to the real thing: a per-row context object (visidata/sheets.py,
# LazyComputeRow) cached by (sheet, rowid, col), whose __getitem__ resolves a
# name by scanning availColnames and then calls the column's getter.
class LazyRowLike:
    __slots__ = ("row", "colnames", "getters", "_used")

    def __init__(self, row, colnames, getters):
        self.row = row
        self.colnames = colnames
        self.getters = getters
        self._used = set()

    def __getitem__(self, name):
        i = self.colnames.index(name)      # a linear scan, as VisiData does
        self._used.add(name)
        return self.getters[i](self.row)

    def keys(self):
        return self.colnames


colnames = ["name", "n", "x"]
getters = [lambda r: r[0], lambda r: r[1], lambda r: r[2]]
rows = [(f"row{i}", i, i * 0.5) for i in range(N)]


def evalexpr_faithful():
    contexts = {}
    out = []
    for row in rows:
        ctx = contexts.setdefault((id(row),), LazyRowLike(row, colnames, getters))
        out.append(eval(code, g, ctx))
    return out


bench("evalExpr (VisiData)", evalexpr_faithful)

# The same column, as text. VisiData columns are more often strings than
# floats, and this is the shape a cleanup plugin works on.
texts = [f"row{i % 100000}" for i in range(min(N, 1_000_000))]
sn = len(texts)
bench("str listcomp (upper)", lambda: [s.upper() for s in texts], n=sn)
scode = compile("s.upper()", "<expr>", "eval")
bench("str evalExpr (per row)",
      lambda: [eval(scode, g, {"s": s}) for s in texts], n=sn)

try:
    import numpy as np
    arr = np.array(xs)
    bench("numpy", lambda: arr * 2.5 + 1.0)
except ImportError:
    print("numpy                  not installed")
