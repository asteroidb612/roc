# roc-visidata: a plan

Roc plugins for [VisiData](https://visidata.org), written as `.roc` files that
VisiData runs the moment you point it at them — no `roc build`, no artifact to
keep in sync, and `~/.visidatarc` in Roc instead of Python.

This document is the design and the order to build it in. Nothing here is
implemented yet; `roc-vim/` next door is, and about two thirds of what is
described below is that code with the editor swapped out.

## Contents

- [What this is for](#what-this-is-for)
- [How the online REPL does it](#how-the-online-repl-does-it)
- [What carries over from roc-vim](#what-carries-over-from-roc-vim)
- [Architecture](#architecture)
- [The host surface](#the-host-surface)
- [What a plugin looks like](#what-a-plugin-looks-like)
- [Configuring VisiData in Roc](#configuring-visidata-in-roc)
- [Speed](#speed)
- [Threads, the GIL, and crashes](#threads-the-gil-and-crashes)
- [Packaging, and what "no build step" means](#packaging-and-what-no-build-step-means)
- [Milestones](#milestones)
- [Risks and open questions](#risks-and-open-questions)
- [File layout](#file-layout)

## What this is for

Three things, in the order they pay off:

1. **Plugins in Roc.** A `.roc` file in `~/.visidata/roc/` becomes a VisiData
   plugin: it adds commands, binds keys, adds columns, reacts to what you do.
2. **Computation in Roc.** Derived columns, filters, aggregators and loaders
   run as Roc over whole columns rather than as Python per cell — which is
   where a table of ten million rows spends its afternoon.
3. **Configuration in Roc.** `~/.visidatarc` is executed Python today
   (`visidata/settings.py:441`, `loadConfigFile`). A `.visidatarc.roc` beside
   it gets a type-checked config with no `exec()` of a file that can do
   anything.

The hard requirement is **no build step**. Editing a plugin and using it has to
be one action, the way editing `~/.visidatarc` is. That is what forces the
compiler inside the process, and that is what the online REPL already knows how
to do.

## How the online REPL does it

The question worth answering first: *how does roc-lang.org run Roc with no
linker, no `cc`, and no artifact on disk?* There are two answers in the history,
and the second one is the one to copy.

### The Rust-era web REPL (`crates/repl_wasm/`, in this tree)

The compiler is built to `roc_repl_wasm_bg.wasm` with `wasm-pack`. Per its
README:

- JS hands the input text to the compiler wasm module.
- The compiler parses, type-checks, monomorphizes, and generates **wasm** using
  the development backend (not LLVM).
- It returns a slice of bytes; JS builds a `WebAssembly.Instance` from them and
  runs it.
- JS copies the app's memory back and the compiler module decodes the result
  from the known return type.

The load-bearing idea is that the development backend emits bytes for an
in-memory module, so nothing is ever written out or linked. The browser's
`WebAssembly.Instance` plays the role of the linker and loader.

### The Zig-era playground (upstream `roc-lang/roc`, `src/`)

The current compiler does not generate code at all for this path. It
**interprets**. `src/echo_platform/runner.zig` is the shared compile-and-run
pipeline — its own doc comment says both the wasm export and the native CLI
drive this same function — and it goes:

```
BuildEnv.build(path)                     # parse, canonicalize, type-check
  -> collectImportedArtifactViews         # the modules it pulled in
  -> lowerCheckedModulesToLir             # LIR, with internal static data
  -> buildStaticDataForWidth              # materialize string literals etc.
  -> LirInterpreter.initWithBoxyTables    # an interpreter over that LIR
       against a RocOps the host supplies (alloc, dbg, crash, hosted fns)
  -> call an entrypoint
```

No machine code, no object file, no `ld`. The host supplies `RocOps` — its
allocator, its crash handler, and a table of **hosted functions** the
interpreter dispatches into by index.

One detail matters for us. Hosted functions are stored type-erased as
`HostedFn = *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void`
(`src/builtins/host_abi.zig:111`), but how they are *called* depends on the
target (`src/eval/interpreter.zig:5279`):

- **Native** (x86-64, arm64): through a fixed register-image trampoline, with
  the platform C ABI. A hosted function is an ordinary C function with the
  natural signature — `RocStr roc_vd_host_eval(RocStr)` — exactly as a linked
  platform would write it.
- **wasm32**: no dynamic-signature call can be synthesized, so hosted functions
  are called through a uniform `void (*)(u8 *args, u8 *ret)` ABI instead.

We are native, so we write ordinary C. If we ever want roc-visidata under
Pyodide, that is the line of code to remember.

### What we actually reuse

We do not need to re-derive any of it. `roc-vim/compiler-patch/roc-embed-library.patch`
already packages that pipeline behind a C API (`roc-vim/embed/roc_embed.h`):

```c
void *roc_embed_open(const char *path, size_t path_len,
                     void *resolver_ctx, roc_embed_resolve_fn resolver,
                     char **error_out);
int   roc_embed_entrypoint(void *program, const char *symbol, size_t len);
int   roc_embed_call(void *program, int ordinal, void *args, void *ret, char **error_out);
void  roc_embed_close(void *program);
```

`zig build roc-embed` produces `libroc_embed.a` — the whole compiler plus that
boundary — and the host answers a `resolver` callback with the C function
implementing each hosted symbol by name. Argument packing is described by the
library (`roc_embed_args_size`, `roc_embed_arg_offset`), so a caller never has
to know Roc's layout rules.

**The embedded compiler already exists. roc-visidata is a second consumer of
it, and needs no compiler changes of its own.**

## What carries over from roc-vim

| Piece | Status |
| --- | --- |
| `compiler-patch/roc-embed-library.patch` | reuse **unchanged** — shared, not copied |
| `compiler-patch/roc-shared-library-static-data.patch` | reuse unchanged (needed only for the compiled tier) |
| `embed/roc_embed.h`, the open/call/close sequence | reuse, re-pointed at our hosted functions |
| `platform/Value.roc` (JSON values, parser, encoder, structural `==`) | copy nearly verbatim — it is host-agnostic |
| model + handler plugin shape (`init!` / `handle!`, `Box(Model)`) | copy |
| the `enter_plugin` / crash-guard / reply-buffer machinery in `host.c` | copy |
| `Vim.roc` | **replaced** by `VisiData.roc` |
| the Vim `+roc` patch (`vim-patch/`) | **dropped entirely** |

That last row is the good news. Vim needed a 420-line C patch and a rebuilt
editor because Vim cannot `dlopen()`. Python can: `ctypes.CDLL` is in the
standard library, and `ctypes.CFUNCTYPE` produces real C function pointers a
callee cannot distinguish from compiled ones. **There is no VisiData fork in
this plan.** roc-visidata is an ordinary `pip install`-able VisiData plugin
that happens to carry a compiler in its wheel.

## Architecture

```
  ~/.visidata/roc/tally.roc                    a plugin, as source
          |
          |  vd.roc.load('tally.roc')          Python, in the visidata_roc package
          v
  ctypes.CDLL('libroc_vd_embed.so')
          |
          |  roc_vd_source_load(&api, path)    C, engine.c
          v
  libroc_embed.a ── BuildEnv ── LIR ── LirInterpreter
          |                                  |
          |                                  |  hosted calls (natural C ABI)
          |                                  v
          |                        host.c: roc_vd_host_exec / _eval / _reply / _rows
          |                                  |
          +----------------------------------+--> api->eval_json(...)   a C callback
                                                          |
                                                          v
                                             ctypes.CFUNCTYPE trampoline
                                                          |
                                                          v
                                             Python: eval(expr, vd.getGlobals())
```

Four components:

### 1. `platform/` — the Roc platform

Mirrors `roc-vim/platform-inprocess/`. VisiData owns the main loop, so a plugin
is a model and a handler:

```roc
platform ""
    requires {
        [Model : model] for plugin : {
            init! : () => Try(model, [VdErr(Str), ..]),
            handle! : model, VisiData.Event => Try(model, [VdErr(Str), ..]),
        }
    }
    exposes [VisiData, Value]
    provides {
        "roc_vd_init": init_for_host!,
        "roc_vd_handle": handle_for_host!,
        "roc_vd_map": map_for_host!,       # the bulk path; see Speed
    }
    hosted {
        "roc_vd_host_exec": Host.exec!,
        "roc_vd_host_eval": Host.eval!,
        "roc_vd_host_reply": Host.reply!,
        "roc_vd_host_id": Host.id!,
    }
```

The model lives boxed in C between events, so a plugin keeps state without a
mutable global, and an event that fails leaves the previous model intact.

### 2. `engine/` — the C engine

`engine.c` is `roc-vim/embed/engine.c` with the Vim api struct swapped for
`roc_vd_api_T`, plus `host.c` which implements the hosted functions against
that struct. Built two ways, from the same sources:

- `libroc_vd_embed.so` — engine.c + host.c + `libroc_embed.a`. This is the
  no-build-step path, and the only thing the Python package strictly needs.
- `libhost.a` — host.c alone, for plugins compiled to a shared library
  (the fast tier). Same hosted functions, so a plugin behaves identically
  whether interpreted or compiled; roc-vim proves this by running the same
  examples both ways.

### 3. `python/visidata_roc/` — the VisiData side

Pure Python, `ctypes` only, no C extension to build:

- `_ffi.py` — the `CDLL` handle, the `roc_vd_api_T` structure, and the
  `CFUNCTYPE` callbacks that make up VisiData's side of the api table.
- `engine.py` — `RocPlugin`: load, `event()`, `unload()`, the per-engine lock.
- `plugin.py` — discovery in `options.roc_plugin_dir`, `:RocPlugins` sheet,
  reload on save, the command trampoline.
- `columns.py` — `RocColumn`, the bulk `map` path, aggregators.
- `config.py` — `.visidatarc.roc`.

### 4. `examples/` and `test/`

roc-vim's testing shape is worth copying exactly: a C test that drives the
engine with no editor at all (`roc-vim/test/embed_test.c`), then an end-to-end
test that runs the real program. For us the first becomes a plain Python
script that loads the engine with a stub api table and asserts on what the
plugin asked for — no VisiData, no terminal, fast enough for CI.

## The host surface

roc-vim gets the entire Vim API out of two primitives: `ex!` runs a command,
`eval!` evaluates an expression and returns JSON. Everything in `Vim.roc` —
`echom!`, `call!`, buffer reads and writes — is built from those two.

The same trick works better in Python, because Python's `eval`/`exec` split is
the same split:

```roc
Host :: [].{
    ## Execute a Python statement in VisiData's globals. Fire and forget.
    exec! : Str => {}

    ## Evaluate a Python expression. Returns `{"ok": <value>}` or
    ## `{"err": "<reason>"}` as JSON text.
    eval! : Str => Str

    ## Set the answer this event returns to whoever dispatched it.
    reply! : Str => {}

    ## The handle this plugin was loaded under.
    id! : () => Str
}
```

On the Python side those are four `CFUNCTYPE` callbacks over `(const char *,
size_t)` — no structs by value, nothing that depends on Roc's layout — and
`eval_json` is the only one that returns anything:

```python
def _eval_json(expr, length, out_len):
    try:
        value = eval(expr[:length].decode(), vd.getGlobals(), _ctx())
        payload = json.dumps({'ok': _jsonable(value)})
    except Exception as e:
        payload = json.dumps({'err': f'{type(e).__name__}: {e}'})
    return _own(payload, out_len)
```

`VisiData.roc` then builds the ergonomic surface on top, so a plugin author
never writes a Python string:

```roc
VisiData.status!(message)          # exec!("vd.status(...)")
VisiData.warning!(message)
VisiData.add_command!(keystrokes, longname, help)
VisiData.bind_key!(keystrokes, longname)
VisiData.option!(name, default, description)
VisiData.cursor_value!()          # eval!("vd.sheet.cursorValue") -> Value
VisiData.column!(name)            # -> List(Value), one per row
VisiData.set_column!(name, values)
VisiData.select_rows!(indices)
VisiData.push_sheet!(name, rows)
VisiData.subscribe!(["rowSelected", "sheetLoaded"])
```

`Value.roc` — the JSON-shaped value type with a parser, an encoder and
structural equality — comes over from roc-vim with only its error tag renamed.
Keeping the boundary at JSON means nothing in the Python package depends on how
Roc lays out its types, which is the property that lets the compiled and
interpreted tiers share one host.

### Commands

`Sheet.addCommand` takes an **execstr**: a Python statement `exec()`'d when the
command runs (`visidata/settings.py:359`). So a Roc plugin's command registers
a trampoline:

```python
Sheet.addCommand('', 'roc-tally', 'vd.roc.dispatch("tally.roc", "command:roc-tally")', helpstr)
```

`vd.roc.dispatch` builds the event JSON, calls `roc_vd_source_event`, and
returns whatever the plugin passed to `reply!`. This is the same shape as
roc-vim's `roc#ask()`, and it means a Roc plugin can back anything VisiData
calls and waits on — including an input completer or a cell formatter.

## What a plugin looks like

```roc
app [Model, plugin] { vd: platform "../platform/main.roc" }

import vd.VisiData
import vd.Value

## How many rows we have selected for the user so far.
Model : I64

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    VisiData.add_command!("z#", "roc-select-outliers", "select rows more than 3 sigma from the mean")
    VisiData.subscribe!(["sheetLoaded"])
    Ok(0)
}

handle! : Model, VisiData.Event => Try(Model, _)
handle! = |total, event|
    if event.name == "command:roc-select-outliers" {
        values = VisiData.column_floats!(VisiData.cursor_column_name!()?)?
        mean = Num.sum(values) / Num.to_frac(List.len(values))
        sigma = std_dev(values, mean)
        outliers =
            values
            |> List.map_with_index(|value, index| (index, value))
            |> List.keep_if(|(_, value)| Num.abs(value - mean) > 3 * sigma)
            |> List.map(|(index, _)| index)

        VisiData.select_rows!(outliers)
        VisiData.status!("selected ${Num.to_str(List.len(outliers))} outliers")
        Ok(total + List.len(outliers))
    } else {
        Ok(total)
    }
```

Drop that in `~/.visidata/roc/`, press `z#`, and it runs. Save the file and it
recompiles in place, the way roc-vim's `source` transport does.

## Configuring VisiData in Roc

`~/.visidatarc` is `exec()`'d Python. A `.visidatarc.roc` is loaded by the same
engine, with one entrypoint and no model:

```roc
app [config] { vd: platform "…/platform/config.roc" }

import vd.VisiData

config! : () => Try({}, _)
config! = || {
    VisiData.set_option!("disp_float_fmt", Value.Text("{:.3f}"))
    VisiData.set_option!("quitguard", Value.Bool(True))
    VisiData.bind_key!("gw", "sysopen-row")
    VisiData.set_theme!("light")
    Ok({})
}
```

Two reasons this is worth having beyond taste. It is type-checked, so a typo in
an option name is an error before VisiData starts rather than a traceback on a
black screen. And it is not arbitrary code: a config that can only reach
`VisiData.roc` cannot open a socket, which is not true of the Python one.

Load order: `.visidatarc` first (so existing configs win on conflict), then
`.visidatarc.roc`, then Roc plugins. Both files existing is fine and expected
during a migration.

## Speed

The honest version, because this is the part where a plan can quietly promise
something it cannot deliver.

**The interpreter is not fast.** roc-vim's own docs say it: "for one doing real
computation per keystroke, build it instead". Roc running as LIR in an
interpreter is not going to beat CPython by a wide margin on a tight numeric
loop, and it will lose badly to NumPy. If roc-visidata shipped only the
interpreted tier, "plugins in Roc are fast" would be false.

So the plan is two tiers with an automatic upgrade, plus a data path that keeps
per-row costs off the FFI boundary entirely.

### Tier 1 — interpreted, instant

What is described above. Load time is the compiler running in-process (well
under a second for a small plugin, per roc-vim), and every event after that is
interpreted. This is the right tier for plugins that mostly call into VisiData:
commands, key bindings, sheet pushes, config.

### Tier 2 — compiled, native

The same `.roc` file, built to a shared library against `libhost.a` (`output:
Shared` in the platform's `targets:`, which is what
`roc-shared-library-static-data.patch` makes work). Python `dlopen`s it and
calls `roc_vd_plugin_event` directly — real machine code, no interpreter.

**The upgrade is automatic and invisible.** On load, roc-visidata starts the
plugin interpreted, and if a `roc` compiler is on `PATH` it kicks off a build
in a background thread (VisiData already has `@asyncthread` for exactly this
kind of work). When the build lands, the next event goes to the compiled
library instead; the model is re-initialized and the plugin reports
`transport=compiled` in `:RocPlugins`. Artifacts are cached under
`~/.cache/roc-visidata/` keyed by source hash, so the second run of a plugin is
native from the first keystroke. If no compiler is installed, nothing happens
and the plugin stays interpreted — the feature degrades rather than failing.

This is what makes "no build step" true without it also meaning "slow". The
user never runs a build; a build sometimes runs for them.

### The bulk path, which matters more than the tier

Neither tier helps if every row costs an FFI crossing and a GIL acquisition.
VisiData's `Column.getter` is called per cell (`visidata/column.py:312`), and
`ExprColumn` compiles a Python expression per column and evaluates it per row
(`visidata/expr.py`). Copying that shape into Roc would give us the worst of
both.

So the third entrypoint, `roc_vd_map`, takes a whole column and returns a whole
column:

```roc
map! : List(Value) -> List(Value)
```

`RocColumn` calls it **once** per recalculation, caches the result list, and
serves `getter` out of the cache. One boundary crossing, one GIL round trip,
N rows of Roc. The same entrypoint backs:

- **Derived columns** — `=` with a Roc expression instead of a Python one.
- **Filters and selection** — `List(Value) -> List(Bool)`.
- **Aggregators** — `vd.aggregator(name, func)` where `func` is a Roc fold
  (`visidata/aggregators.py:130`).
- **Loaders** — a Roc parser for a format VisiData has no loader for, which is
  the case where beating Python is easy rather than hard.

Concretely: a 10M-row `float` column through a Roc `map!` in tier 2 should be
one crossing and a native loop, against 10M interpreted Python frames today.
That is the speed claim this design can actually stand behind, and it holds
even in tier 1, where the win comes from deleting 10M Python frames rather than
from the interpreter being quick.

Benchmarks belong in milestone M5, not in this paragraph.

## Threads, the GIL, and crashes

Four hazards, all of them known:

**VisiData is threaded.** Commands routinely run under `@asyncthread`
(`visidata/threads.py:253` spawns a daemon `threading.Thread`). Two threads can
therefore reach one plugin at once. roc-vim's `host.c` keeps the current api
table and plugin id in file-scope state and swaps it on entry (`enter_plugin`),
which is fine for a single-threaded editor and is not fine here. Fix: a
`threading.Lock` per plugin held across every `event()` call, and thread-local
rather than file-scope current-plugin state in `host.c`. The lock is honest —
a plugin is a model and a handler, so its events are sequential by definition.

**The GIL.** A `ctypes` callback acquires the GIL before running Python and
releases it after; a `CDLL` call releases the GIL for the duration unless the
library is opened with `PYDLL`. That is the behaviour we want: a long Roc `map!`
does not block VisiData's UI thread, and a hosted call back into Python
serializes correctly. It does mean a hosted call from Roc can block on the GIL,
so `VisiData.roc`'s docs should steer bulk work toward `map!` and away from
per-row `eval!`.

**Reentrancy.** Roc calls `eval!`, Python evaluates an expression, that
expression triggers a VisiData command, that command dispatches to the same
plugin. roc-vim can mostly ignore this; we cannot. The per-plugin lock must be
non-reentrant and the dispatcher must detect the recursive case and fail the
inner call with a clear error rather than deadlocking.

**Crashes.** A Roc `crash` becomes a reported error and stops that plugin —
the interpreter has a crash boundary (`enterCrashBoundary`/`setjmp`), and
roc-vim's host adds its own guard. Both carry over. What neither can catch is a
bug in the compiler itself, which lands in the VisiData process; that is a real
cost of embedding and belongs in the README, not hidden here.

## Packaging, and what "no build step" means

Precisely: **no per-plugin build step, ever.** Editing a `.roc` file and using
it is one action. That is the property being bought.

What the user installs:

```
pip install roc-visidata
```

The wheel carries `libroc_vd_embed.so` prebuilt — the Roc compiler, the engine,
and the host, in one file. It is large (the whole compiler; expect tens of MB)
and that is the price of the compiler being in-process. Per platform:

| Platform | Tier 1 (interpreted) | Tier 2 (compiled) |
| --- | --- | --- |
| Linux x86-64 / arm64 | prebuilt wheel | works (ELF; the static-data patch is ELF-only) |
| macOS arm64 / x86-64 | prebuilt wheel | **needs work** — `object/macho.zig` needs the same writable-static-data treatment |
| Windows | build from source | **needs work** — same, in `object/coff.zig` |

So tier 1 is portable and tier 2 is Linux-first, exactly as roc-vim documents.
A `roc-visidata build-engine` subcommand covers the no-wheel case: clone the
compiler, apply `roc-vim/compiler-patch/*.patch`, `zig build roc-embed`, then
link the engine — the same sequence `roc-vim/embed/build.sh` runs today.

Version skew is handled the way the C code already does it: the engine exports
`roc_vd_source_abi_version()`, Python checks it on load, and a mismatch is a
clear message rather than a crash through the wrong offsets.

## Milestones

Each one ends with something that runs and a test that proves it.

**M0 — engine builds and answers (no VisiData).**
`engine/` with `host.c` and `engine.c`, linked against `libroc_embed.a` into
`libroc_vd_embed.so`. `test/engine_test.py` opens it with `ctypes`, hands it a
stub api table, loads `examples/hello.roc`, and asserts that the plugin asked
to run the statement it was supposed to. No VisiData, no terminal.
*Proves: the embedded compiler works from Python.*

**M1 — the platform.**
`platform/` with `main.roc`, `Host.roc`, `VisiData.roc`, `Value.roc`
(from roc-vim). `init!`/`handle!`, boxed model, JSON events. `examples/hello.roc`
adds a command and reports the cursor value.
*Proves: a plugin can be written.*

**M2 — inside VisiData.**
`python/visidata_roc/`: discovery in `options.roc_plugin_dir`, load at startup,
command trampolines, `:RocPlugins` sheet with transport and status, reload on
save, `vd.roc.dispatch`. Tested by driving a real `vd` under a pty and asserting
on the status line, mirroring `roc-vim/test/vim_test.sh`.
*Proves: the headline feature. Ship-able on its own.*

**M3 — `.visidatarc.roc`.**
`platform/config.roc`, option and keybinding setters, load ordering, an example
config that a person would actually use.
*Proves: configuration in Roc.*

**M4 — the bulk path.**
`roc_vd_map`, `RocColumn`, Roc expression columns bound to `=`, Roc
aggregators, Roc row filters. Cached per recalculation.
*Proves: one crossing per column, not per cell.*

**M5 — tier 2 and benchmarks.**
`platform/targets/` and `libhost.a` for `output: Shared`; background compile
with `@asyncthread`; hot swap; artifact cache keyed by source hash; graceful
absence of a compiler. Then benchmarks, published in the README: Roc
interpreted vs. Roc compiled vs. Python `ExprColumn` vs. NumPy where it
applies, over 10^4 / 10^6 / 10^7 rows.
*Proves: the speed claim, with numbers.*

**M6 — packaging.**
Wheels for Linux x86-64 and arm64 with the engine inside; `roc-visidata
build-engine` for everyone else; README, install docs, and a straight account
of the limits above.

M0–M2 is the interesting half and is mostly roc-vim with the Vim patch deleted.

## Risks and open questions

- **Engine size.** The wheel carries a compiler. If tens of MB is unacceptable,
  the fallback is a separate `roc-visidata-engine` package, or downloading the
  engine on first use into `~/.cache/roc-visidata/`. Decide at M6, measure at M0.
- **Compile latency at startup.** Every plugin compiles when VisiData starts.
  Ten plugins at 0.5s each is a five-second startup, which is not acceptable for
  a tool people open on a file to look at it. Mitigations, in order: compile
  lazily on first dispatch rather than at startup; cache the tier-2 artifact so
  a warm plugin never touches the compiler; compile off the UI thread. Needs a
  real measurement at M2 before choosing.
- **The interpreter may be slower than hoped even on the bulk path.** M5's
  benchmarks are the gate. If tier 1 loses to plain Python on `map!`, the
  answer is to make tier 2 the default whenever a compiler is present and say
  so plainly, not to bury the number.
- **Patches against a moving compiler.** Both compiler patches are against
  `roc-lang/roc` commit `1d982dca` (2026-09-18). They will drift. The embed
  patch adds files and changes nothing existing, so it should rebase cleanly;
  the static-data patch touches four files and will need attention. Worth
  proposing `roc-embed` upstream — a second independent consumer is the best
  argument for it.
- **VisiData API stability.** Inspected against **visidata 3.4**. `addCommand`,
  `Column.getter`, `vd.aggregator`, `vd.option` and `loadConfigFile` are all
  long-standing, but the execstr trampoline is the part most likely to move.
  Pin a minimum version and test against it in CI.
- **`Value` is JSON-shaped, and VisiData's cells are not always JSON.** Dates,
  `datetime`, and custom types need a decided encoding at the boundary. Start
  with ISO-8601 strings plus a type tag; revisit if it becomes lossy in a way
  people hit.
- **Who owns returned memory.** `eval_json` returns a buffer Python allocated
  and C frees, matching `roc_vim_api_T.free_result`. Getting this wrong is a
  leak per keystroke. `test/engine_test.py` should run under a leak check.

## File layout

```
roc-visidata/
  PLAN.md                    this document
  README.md                  (M6) install, use, and the limits
  platform/
    main.roc                 init!/handle!/map! entrypoints, boxed model
    config.roc               the .visidatarc.roc entrypoint
    Host.roc                 exec! eval! reply! id!
    VisiData.roc             the API a plugin writes against
    Value.roc                JSON-shaped values (from roc-vim)
    host.c                   hosted functions over roc_vd_api_T
    roc_vd_api.h             the Python<->C contract, versioned
    build.sh                 libhost.a, for the compiled tier
  engine/
    engine.c                 roc_vd_source_{load,event,unload} over libroc_embed
    build.sh                 libroc_vd_embed.so
    README.md
  python/
    pyproject.toml
    visidata_roc/
      __init__.py            registers everything with vd
      _ffi.py                ctypes: CDLL, the api struct, the callbacks
      engine.py              RocPlugin: load/event/unload, the lock
      plugin.py              discovery, :RocPlugins, reload-on-save, dispatch
      columns.py             RocColumn, the map path, aggregators
      config.py              .visidatarc.roc
  examples/
    hello.roc                a command and the cursor value
    outliers.roc             selection over a whole column
    visidatarc.roc           configuration
  test/
    engine_test.py           the engine with a stub api, no VisiData
    visidata_test.py         a real vd under a pty
    bench/                   (M5)
```

`compiler-patch/` is deliberately absent: roc-visidata uses
`roc-vim/compiler-patch/` as-is. If the two ever need different compiler
changes, that is the moment to lift the directory to the repository root
rather than to fork it.
