"""What it costs to hand a VisiData column to native code and take it back.

The interpreter's speed is only half the bulk-path question. The other half is
that VisiData's rows are Python objects: a column's values have to be pulled
out of them one at a time before anything native can see them, and the results
have to become Python objects again. That work is pure Python no matter how
fast the callee is, so it sets a floor under the whole idea.
"""

import array, ctypes, sys, time

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
ITERS = int(sys.argv[2]) if len(sys.argv) > 2 else 5

# A sheet the way VisiData holds one: a list of row objects, one dict per row.
rows = [{"x": i * 0.5, "name": f"row{i}", "n": i} for i in range(N)]
values = [r["x"] for r in rows]
buf = array.array("d", values)


def bench(label, fn, n=N):
    samples = []
    for _ in range(ITERS):
        t0 = time.perf_counter()
        fn()
        samples.append((time.perf_counter() - t0) * 1000.0)
    best = min(samples)
    print(f"{label:<30} best {best:9.3f} ms   {best * 1e6 / n:8.1f} ns/element")
    return best


print(f"== marshalling   n={N} ==")
extract = bench("extract column from rows", lambda: [r["x"] for r in rows])
to_arr = bench("list -> array('d')", lambda: array.array("d", values))
buffer_ptr = bench("array -> C pointer", lambda: ctypes.cast(
    (ctypes.c_double * 0).from_buffer(array.array("d", [])), ctypes.c_void_p))
back = bench("C buffer -> python list", lambda: buf.tolist())
store = bench("write results back to rows",
              lambda: [r.__setitem__("y", v) for r, v in zip(rows, values)])

print()
print(f"{'floor: extract + convert + back':<30} "
      f"{(extract + to_arr + back) * 1e6 / N:8.1f} ns/element")
print(f"{'  (+ write back into rows)':<30} "
      f"{(extract + to_arr + back + store) * 1e6 / N:8.1f} ns/element")

try:
    import numpy as np
    print()
    arr = np.array(values)
    bench("numpy: list -> ndarray", lambda: np.array(values))
    bench("numpy: ndarray -> list", lambda: arr.tolist())
except ImportError:
    pass
