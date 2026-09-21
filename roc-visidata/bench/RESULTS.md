# Results

Measured 2026-09-20 on 4 cores / 15 GB, Linux x86-64, against `roc-lang/roc`
at `1d982dca` with `roc-vim/compiler-patch/` applied, built
`-Doptimize=ReleaseSafe` with Zig 0.16. Python 3.11.15, numpy 2.4.6,
VisiData 3.4 for the API shapes being imitated.

Every number below is the best of 3–5 runs. Reproduce with `./run.sh`.

## The short version

| Question | Answer |
| --- | --- |
| Can a plugin be compiled in-process at startup? | Yes for one (154 ms), no for ten (~1.5 s). Compile lazily. |
| Does the interpreted bulk path beat Python? | **No.** It is 22× slower than VisiData's own expression column and 90× slower than a list comprehension. |
| Then where is the speed? | Only in the compiled tier. Roc owning the data is the right architecture, but interpreted it is 242× slower than VisiData's own loader, so tier 2 is a precondition rather than an optimization. |

## 1. Compile latency

What `roc_embed_open` costs: parse, canonicalize, type-check, lower to LIR,
materialize static data, and bind the hosted functions.

| Plugin | Cold | Warm |
| --- | --- | --- |
| imports nothing | 15.7 ms | — |
| realistic (imports the platform's 620-line `Value`) | 154 ms | 107–111 ms |

The compiler's on-disk cache is enabled (`enableDefaultCacheManager`; the
`false` in the embed library is verbosity, not a switch) and it is populated —
`~/.cache/roc` reaches 2.5 MB — but it only takes about 30% off. It does not
turn a 154 ms compile into a 15 ms one.

**What this means.** One plugin at startup is fine. Ten realistic plugins is
1.1–1.5 s added to `vd` opening a file, which is not acceptable for a tool
people reach for to glance at something. Compiling lazily on first dispatch is
therefore a requirement, not the optimization the plan listed it as. The
tier-2 artifact cache matters for the same reason: it skips this entirely on
the second run.

Dispatching one event, once the plugin is loaded:

| Plugin | Per event |
| --- | --- |
| trivial handler | 0.003 ms |
| handler that parses its event JSON with `Value` | 0.35 ms |

Sub-millisecond either way, so **commands, key bindings and config are
comfortably fast interpreted** — which is the half of the design that does not
depend on the next section.

## 2. The bulk path

One `map!` over a whole column: `x * 2.5 + 1.0` per element, F64 in and out.

| | 10k | 100k | 1M | ns/element |
| --- | --- | --- | --- | --- |
| C loop (native ceiling) | 0.002 ms | 0.025 ms | 0.649 ms | 0.2–0.6 |
| numpy | 0.006 ms | 0.133 ms | 1.806 ms | 0.6–1.8 |
| Python list comprehension | 0.253 ms | 3.483 ms | 37.1 ms | 25–37 |
| Python compiled expr, per row | 1.479 ms | 13.9 ms | 149 ms | 139–148 |
| VisiData's actual `evalExpr` | 7.611 ms | 155 ms | 3203 ms | 761–3203 |
| **Roc, interpreted** | **36.0 ms** | **381 ms** | **3234 ms** | **3234–3811** |

The interpreter costs about **3.2–3.8 µs per element**, and the figure is flat
across three orders of magnitude, so it is per-element cost and not startup.

Against each baseline, interpreted Roc is:

- **~90× slower** than a plain Python list comprehension
- **~22× slower** than a compiled Python expression evaluated per row
- **about even** with VisiData's real `evalExpr` at 1M rows — and that is not
  Roc doing well, it is VisiData doing badly (see below)
- **~5000× slower** than the C loop it would become if compiled

**The answer to the question the plan asked is no.** Tier 1 does not make
computation fast; it makes it much slower. The speed claim rests entirely on
tier 2, which makes the compiled tier a requirement for any computing plugin
rather than a background upgrade.

### Why VisiData's own number is so bad

`ExprColumn` goes through `Sheet.evalExpr` (`visidata/sheets.py:420`), which
builds a `LazyComputeRow` per row and caches it in `vd._evalcontexts` keyed by
`(sheet, rowid, col)`. The object is constructed on every call whether or not
the cache hits, and its `__getitem__` resolves a column name by scanning
`availColnames` linearly. Over a whole column the cache grows without bound,
and the cost per element climbs with it:

| rows | ns/element |
| --- | --- |
| 10k | 761 |
| 100k | 1545 |
| 1M | 3203 |

This is a real property of whole-column operations in VisiData today, and it
is the one place interpreted Roc is not worse. It is a weak thing to build a
claim on, so the tables above quote the linear 139–148 ns/element figure as
the bar instead.

## 3. The floor under any bulk path

Even with an infinitely fast callee, a column has to leave Python's row
objects and the results have to come back. That work is pure Python.

| Step | ns/element |
| --- | --- |
| extract the column from row objects | 48.5 |
| `list` → `array('d')` | 15.5 |
| `array` → C pointer | ~0 |
| C buffer → Python list | 21.2 |
| **floor: extract + convert + back** | **85.2** |
| write the results back into rows | 70.3 |
| **floor including write-back** | **155.6** |

Against a 149 ns/element bar, a perfect native callee behind that floor is
worth **about 1.7×**, and nothing if the results have to be written back into
row objects. Marshalling, not computation, is the binding constraint.

**What this means.** The speed story cannot be "write your derived columns in
Roc". It has to be **Roc owning the data**: a Roc loader that parses a file
into native columns, with Roc-side operations over them, and only the ~50
cells actually on screen ever crossing into Python. That is the architecture
where the C-loop column of the table above is reachable.

It also matters that VisiData's display path is already lazy — `getCell` runs
per *visible* cell (`visidata/sheets.py:945`), so a derived column that is
only being looked at costs ~50 evaluations per screen, not N. Eagerly mapping
a million rows to fill it would be a pessimization. The bulk path is for
whole-column work — sort, aggregate, select-by-expression, save — not for
display.

## 4. The loader: Roc owning the data

Section 3 argued the speed case belongs with a loader whose columns never cross
into Python per row. `examples/tsv_loader.roc` is that loader, and
`loader_bench.py` puts it against VisiData's own tsv loader on the same file
(50,000 rows, three columns).

| | VisiData's tsv loader | Roc, interpreted | |
| --- | --- | --- | --- |
| parse the file | 1,898 ns/row | 459,723 ns/row | **242× slower** |
| a screenful (50 rows × 3 cols) | 0.04 ms | 14.92 ms | **373× slower** |
| every value in one column | 211 ns/row | 400,921 ns/row | **1,900× slower** |

Before believing that, the loader was checked for a quadratic mistake — an
`append` that copies would make parsing O(n²) and would be a bug rather than a
cost:

| rows | ns/row |
| --- | --- |
| 5,000 | 226,990 |
| 10,000 | 244,682 |
| 20,000 | 238,756 |

Flat, so it is linear, and this is simply what the interpreter costs. It agrees
with §2: a trivial map costs ~3.4 µs per element, a parsed row is a split plus
a few appends — tens of operations — and tens times 3.4 µs is what shows up.

**So the architecture is right and the interpreted tier cannot carry it.** Even
the screenful, the case the design is built around, costs 15 ms interpreted,
which is felt on every keystroke. This is the third and clearest statement of
the same finding: the compiled tier is a precondition for everything except
commands, bindings, hooks and config — not an optimization for hot plugins.

## 5. Things found along the way

**The engine is 57 MB.** `libroc_embed.a` is 199 MB; linked into a binary and
stripped it is 57 MB (138 MB unstripped). That is what a wheel would carry.
Building it took 12 minutes on 4 cores and peaked around 8 GB of RAM.

**A plugin that imports a platform module the platform itself does not import
panics the compiler**, and the panic takes the host process with it:

```
thread panic: reached unreachable code
src/compile/coordinator.zig:593:35: in compileProgram
    const env = self.moduleEnv() orelse return null;
src/embed/main.zig:515:34: in roc_embed_open
```

Adding `import Value` to the platform's own `main.roc` fixes it. This is worth
reporting upstream, and it is a sharp edge for embedding generally: a panic
inside the compiler cannot be caught by the host the way a Roc `crash` can, so
a bad plugin can take VisiData down. The plan already says a compiler bug
lands in the host process; this is a live example of one.

**`Str.to_upper` does not exist** in this compiler; the builtin is
`Str.with_ascii_uppercased`. It type-checked as written and failed at the
first call with `runtime error`, which is worth knowing when writing plugins
against a compiler this new.

**Writing Roc against a compiler this new needs a probe harness.** Several
things type-check and then fail at the first call, so the working spellings
were found by compiling and running candidates rather than by reading docs:

| Wanted | Works | Does not |
| --- | --- | --- |
| widen an int to a float | `U64.to_f64(n)`, `I64.to_f64(n)`, `n.to_f64()` | `F64.from_int`, `Num.to_frac`, `F64.from` |
| narrow a float-width int | `n.to_i64_try()`, `n.to_u64_try()` (they return `Try`) | `n.to_i64()`, `U64.to_i64(n)`, `I64.from_u64(n)` |
| split a string | `Str.split_on(s, sep)`, `s.split_on(sep)` | `Str.split` |
| uppercase | `Str.with_ascii_uppercased` | `Str.to_upper` |
| boolean or | `or` | `||` |
| a range to loop over | `while`, `List.map_with_index` | `List.range`, `0..3` |

`List.sum`, `F64.sqrt`, `x.sqrt()`, `List.get`, list patterns with `.. as rest`
and nested `var`s inside `while` all work as written.

**An assignment inside a `match` branch needs braces**, and getting it wrong
inside a *platform module* panics the compiler on `unreachable` instead of
reporting a type error — a second way to abort the host, alongside the import
bug above. The same mistake in an app file reports cleanly.

**Releasing a `List(Str)` that Roc returns** needs ownership rules the harness
does not implement — freeing it as an ordinary list fails with `free():
invalid pointer`. The string benchmark is gated behind `BENCH_STRS=1` for
that reason and its numbers are not reported here. The float path answers the
question, and whatever strings cost, they cost more. A real engine will have
to get this right; `roc-vim/platform-inprocess/host.c` is the reference for
how.
