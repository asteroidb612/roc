# Benchmarks

Two questions from `../PLAN.md` decide whether the design survives, and both
are measurable rather than arguable:

1. **Startup compile latency.** Every plugin is compiled in-process when it
   loads. Ten plugins at half a second each would be an unacceptable startup
   for a tool people open to glance at a file.
2. **Does the interpreted bulk path actually beat Python?** If it does not,
   "plugins in Roc are fast" is false for tier 1 and the compiled tier has to
   become the default rather than an upgrade.

`RESULTS.md` has the numbers and what they mean.

## Running them

```sh
./build.sh /path/to/libroc_embed.a   # see roc-vim/compiler-patch/README.md
./run.sh
```

`libroc_embed.a` is the Roc compiler built as an embedding library. Building
it needs Zig 0.16 and the two patches in `roc-vim/compiler-patch/`.

## What is here

| File | What it measures |
| --- | --- |
| `bench.c` | Roc through `libroc_embed`: compile latency, one event, the bulk map, and a C loop as the native ceiling |
| `python_baseline.py` | The same column in Python: a list comprehension, a compiled expression per row, VisiData's own `evalExpr`, and numpy |
| `marshal_baseline.py` | The Python-side floor: getting a column out of row objects and the results back in |
| `platform/` | The smallest platform shaped like roc-visidata: an event handler and a bulk map |
| `platform-full/` | The same, plus roc-vim's 620-line `Value.roc`, which every real plugin imports |
| `apps/` | `tiny` (the floor), `map_light` (a derived column), `plugin` (a realistic plugin) |

The Python baselines run on their own and need no Roc:

```sh
python3 python_baseline.py 1000000 5
python3 marshal_baseline.py 1000000 5
```
