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
- [Speed](#speed) — measured; see [`bench/RESULTS.md`](bench/RESULTS.md)
- [Threads, the GIL, and crashes](#threads-the-gil-and-crashes)
- [Packaging, and what "no build step" means](#packaging-and-what-no-build-step-means)
- [Milestones](#milestones)
- [Risks and open questions](#risks-and-open-questions)
- [File layout](#file-layout)

## What this is for

Three things, in the order they pay off:

1. **Plugins in Roc.** A `.roc` file in `~/.visidata/roc/` becomes a VisiData
   plugin: it adds commands, binds keys, adds columns, reacts to what you do.
2. **Computation in Roc.** Loaders, and operations over the columns they
   produce, run as Roc over data Roc owns — which is where a table of ten
   million rows spends its afternoon. This needs the compiled tier; the
   interpreter is 22× slower than the Python it would replace, and
   `bench/RESULTS.md` says so in detail.
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

Measured, not guessed: `bench/RESULTS.md` has the numbers and how they were
taken. The short version rearranges this section from what it was.

### What the interpreter costs

One `map!` over a column of F64, `x * 2.5 + 1.0` per element:

| | ns/element |
| --- | --- |
| C loop (what compiled Roc approaches) | 0.2–0.6 |
| numpy | 0.6–1.8 |
| Python list comprehension | 25–37 |
| Python compiled expression, per row | 139–148 |
| **Roc, interpreted** | **3234–3811** |

Interpreted Roc is **~22× slower than the Python it would replace** and ~90×
slower than a list comprehension, flat from 10k to 1M elements. The honest
conclusion is the one the plan was worried about: **tier 1 does not make
computation fast, it makes it much slower.** Any claim that plugins in Roc are
fast rests entirely on the compiled tier, which makes tier 2 a requirement for
a computing plugin rather than a background upgrade.

What tier 1 *is* fast enough for is everything else, and that is most of what a
plugin does:

| | per event |
| --- | --- |
| a trivial handler | 0.003 ms |
| a handler that parses its event JSON | 0.35 ms |

Sub-millisecond per dispatch. **Commands, key bindings, event handlers and
`.visidatarc.roc` are comfortably fast interpreted**, and none of them wait on
tier 2. That half of the design stands on its own.

### What marshalling costs, which turns out to matter more

Even with an infinitely fast callee, a column has to leave Python's row objects
and the results have to come back:

| Step | ns/element |
| --- | --- |
| extract the column from row objects | 48.5 |
| `list` → `array('d')` | 15.5 |
| C buffer → Python list | 21.2 |
| **floor** | **85.2** |
| (+ write results back into rows) | 155.6 |

Against a 149 ns/element bar, a *perfect* native callee behind that floor is
worth **about 1.7×** — and nothing at all if results are written back into row
objects. Marshalling, not computation, is the binding constraint on a bulk
path that reads VisiData's rows.

There is a second reason not to build the speed story there. VisiData's display
is already lazy: `getCell` runs per *visible* cell (`visidata/sheets.py:945`),
so a derived column that is merely being looked at costs about fifty
evaluations per screen, not N. Eagerly mapping a million rows to fill one would
be a pessimization. **The bulk path is for whole-column work** — sort,
aggregate, select-by-expression, save — not for display.

### So where the speed actually is

**Roc owning the data — but only compiled.** M4 built the loader and measured
it (`bench/RESULTS.md` §4): interpreted, a Roc TSV loader parses 242× slower
than VisiData's own, and even a single screenful costs 15 ms. The architecture
is right and the interpreted tier cannot carry it. Everything below is
therefore a statement about the compiled tier.

**Roc owning the data.** A Roc loader parses a file into native columns; Roc
operations run over those columns without ever touching a Python object; only
the cells actually on screen cross into Python. That is the architecture where
the C-loop row of the first table is reachable, because the 85 ns floor is
never paid per element — it is paid per visible cell, fifty at a time.

This reorders the plan. In descending order of how much they are worth:

1. **Roc loaders** (`bench/RESULTS.md` §3). A format VisiData has no loader
   for, parsed by Roc into columns Roc keeps. Nothing crosses per row. This is
   also the case where beating Python is easy rather than hard.
2. **Whole-column operations over Roc-owned columns** — sort, filter,
   aggregate, frequency — for the same reason.
3. **Commands, bindings, config, event handlers.** Fast enough interpreted,
   today, with no tier 2 and no bulk path.
4. **Derived columns over Python rows.** Capped at ~1.7× even compiled;
   worth having for the type checking and the language, not for the speed.

### The two tiers, revised

**Tier 1 — interpreted, instant.** No build step; 15.7 ms to compile a plugin
that imports nothing, 154 ms for a realistic one. This is the tier for
categories 3 above, and it is the one that makes the no-build-step promise
true.

**Tier 2 — compiled, native.** The same `.roc` file built against `libhost.a`
as a shared library, `dlopen`ed and called directly. A **precondition** for
categories 1 and 2, not an optimization: measured three separate ways — a
trivial map, a derived column, and a whole loader — the interpreter costs about
3.4 µs per basic operation, which is 22× slower than Python on a column and
242× slower on a loader. The automatic background build and hot swap described
earlier still applies, and the artifact cache still means the second run starts
native — but a plugin that does real computation with no compiler installed
should say so rather than quietly run 22× slower than Python.

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
and the host, in one file. Measured: **57 MB** stripped, from a 199 MB
`libroc_embed.a`, built in 12 minutes at ~8 GB peak RAM. That is the price of
the compiler being in-process. Per platform:

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

**M4 — Roc owning the data.**
A Roc loader for a format VisiData has none for: Roc parses the file into
columns it keeps, and only the cells on screen cross into Python. Then
whole-column operations over those columns — sort, filter, aggregate. This is
where the speed case lives (`bench/RESULTS.md` §3), so it is also where the
first end-to-end benchmark against VisiData's own loader belongs.
*Proves: the speed claim, on the architecture that can actually support it.*

**M5 — tier 2, and the bulk path over Python rows.**
`platform/targets/` and `libhost.a` for `output: Shared`; background compile
with `@asyncthread`; hot swap; artifact cache keyed by source hash; a plugin
that needs tier 2 saying so when no compiler is installed. Then `roc_vd_map`
and `RocColumn` for columns whose data is VisiData's — worth having for the
language and the type checking, at a measured ceiling of about 1.7×, and
documented as such.
*Proves: computation in Roc is fast when it is compiled, and honestly bounded
when the data belongs to Python.*

**M6 — packaging.**
Wheels for Linux x86-64 and arm64 with the engine inside; `roc-visidata
build-engine` for everyone else; README, install docs, and a straight account
of the limits above.

M0–M3 is the half that works interpreted, needs no tier 2, and is mostly
roc-vim with the Vim patch deleted. M4 is where the speed case has to be
earned.

## Risks and open questions

The first three were the open ones. They have been measured; `bench/RESULTS.md`
has the detail.

- ~~**Compile latency at startup.**~~ **Answered: compile lazily.** 15.7 ms for
  a plugin that imports nothing, 154 ms cold and ~110 ms warm for a realistic
  one. The compiler's on-disk cache is enabled and populated but only takes
  about 30% off. Ten realistic plugins compiled eagerly would add 1.1–1.5 s to
  starting `vd`, so compiling on first dispatch is a requirement rather than a
  mitigation, and the tier-2 artifact cache is what keeps the second run off
  the compiler entirely.
- ~~**The interpreter may be slower than hoped.**~~ **Answered: it is, by a
  lot.** 3.2–3.8 µs per element, ~22× slower than the Python expression column
  it would replace. Tier 1 is for commands, bindings, event handlers and
  config, where it is comfortably sub-millisecond; tier 2 is required for
  anything computational. The plan says so now rather than burying it.
- ~~**Engine size.**~~ **Answered: 57 MB** stripped (138 MB unstripped, from a
  199 MB `libroc_embed.a`), built in 12 minutes on 4 cores at ~8 GB peak RAM.
  Large but shippable in a wheel. If that is too much, the fallbacks are a
  separate `roc-visidata-engine` package or a download into
  `~/.cache/roc-visidata/` on first use.
- **A compiler panic takes VisiData with it.** Found while benchmarking: a
  plugin that imports a platform module the platform's own `main.roc` does not
  import panics on `unreachable` in `src/compile/coordinator.zig:593`, inside
  `roc_embed_open`. A Roc `crash` is caught and reported; a panic in the
  compiler cannot be, because it aborts the process. This is the cost of
  embedding stated concretely, and it argues for reporting it upstream and for
  compiling in a subprocess if embedding ever needs to be bulletproof — which
  would cost the in-process property the whole design is built on. For now:
  document it, and fix the upstream bug.
- **Patches against a moving compiler.** Both compiler patches are against
  `roc-lang/roc` commit `1d982dca` (2026-09-18) and both still apply cleanly
  there. They will drift. The embed patch adds files and changes nothing
  existing, so it should rebase easily; the static-data patch touches four
  files and will need attention. A second independent consumer is the best
  argument for proposing `roc-embed` upstream.
- **VisiData API stability.** Inspected against **visidata 3.4**. `addCommand`,
  `Column.getter`, `vd.aggregator`, `vd.option` and `loadConfigFile` are all
  long-standing; the execstr trampoline is the part most likely to move. Pin a
  minimum version and test against it in CI.
- **`Value` is JSON-shaped, and VisiData's cells are not always JSON.** Dates,
  `datetime` and custom types need a decided encoding. Start with ISO-8601
  strings plus a type tag; revisit if it turns out lossy in a way people hit.
- **Who owns returned memory.** Still open, and now known to be fiddly: the
  benchmark could not release a `List(Str)` that Roc returned without
  `free(): invalid pointer`, so its string case is gated off. Getting this
  right is engine work, with `roc-vim/platform-inprocess/host.c` as the
  reference. A leak per keystroke is the failure mode.
- **Is a Roc loader actually faster end to end?** The speed case now rests on
  Roc owning the data, and that has not been measured — only the pieces around
  it have. M4 should benchmark a Roc loader against VisiData's own on the same
  file before the README claims anything.

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
  bench/                     the numbers behind the Speed section
    RESULTS.md               what was measured, and what it means
    bench.c                  Roc through libroc_embed
    python_baseline.py       the same column in Python and numpy
    marshal_baseline.py      the Python-side floor
    platform/ platform-full/ apps/
```

`compiler-patch/` is deliberately absent: roc-visidata uses
`roc-vim/compiler-patch/` as-is. If the two ever need different compiler
changes, that is the moment to lift the directory to the repository root
rather than to fork it.
