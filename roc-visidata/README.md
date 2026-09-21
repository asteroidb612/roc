# roc-visidata

Write [VisiData](https://visidata.org) plugins in Roc, and configure VisiData in
Roc, with no build step. Drop a `.roc` file in `~/.visidata/roc/` and it works;
save it and it recompiles in place.

```roc
app [Model, plugin] { vd: platform "platform/main.roc" }

import vd.VisiData

Model : I64

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    VisiData.add_command!("z#", "roc-hello", "say hello from Roc")
    Ok(0)
}

handle! : Model, VisiData.Event => Try(Model, _)
handle! = |greetings, event|
    if event.name == "command:roc-hello" {
        sheet = VisiData.sheet_name!()?
        rows = VisiData.nrows!()?
        VisiData.status!("hello from Roc! ${sheet} has ${I64.to_str(rows)} rows")
        Ok(greetings + 1)
    } else {
        Ok(greetings)
    }
```

Press `z#`. Nothing was built.

## How it works

The Roc compiler runs *inside* VisiData. A `.roc` file is compiled in the
editor's own process and run through Roc's interpreter — the pipeline the
[Roc playground](https://roc-lang.org) runs in a browser tab, pointed at a
spreadsheet instead of a text box.

```
  ~/.visidata/roc/hello.roc
         |
         |  vd.rocLoad('hello.roc')          Python, in the visidata_roc package
         v
  ctypes.CDLL('libroc_vd_engine.so')
         |
         |  roc_vd_load(&api, path)          C, engine/engine.c
         v
  libroc_embed ── BuildEnv ── LIR ── interpreter
         |                               |
         |                               |  hosted calls
         |                               v
         |                    host.c: exec / eval / reply / id
         |                               |
         +-------------------------------+--> ctypes callback --> Python
```

There is no fork of VisiData. Vim needed a patched binary for this because it
cannot `dlopen`; Python has `ctypes`, and a `ctypes` callback is a real C
function pointer, so roc-visidata is an ordinary pip-installable plugin that
happens to carry a compiler.

The whole VisiData API is reachable through two primitives — `exec!` runs a
Python statement, `eval!` evaluates a Python expression and returns JSON — and
`VisiData.roc` is written in terms of them. Only text crosses the boundary, so
nothing in the Python package depends on how Roc lays out its types.

## Installing

```sh
pip install roc-visidata
```

and in `~/.visidatarc`:

```python
import visidata_roc
```

From a source checkout you need the engine built once:

```sh
# 1. A Roc compiler with the embedding patch, which needs Zig 0.16.
git clone https://github.com/roc-lang/roc.git && cd roc
git apply /path/to/roc-vim/compiler-patch/roc-embed-library.patch
zig build roc-embed -Doptimize=ReleaseSafe

# 2. The engine.
cd /path/to/roc-visidata/engine
./build.sh /path/to/roc/zig-out/lib/libroc_embed.a

# 3. Point VisiData at the package.
PYTHONPATH=/path/to/roc-visidata/python vd data.csv
```

## Writing a plugin

VisiData owns the main loop, so a plugin is a model and a handler. `init!`
builds the first model and registers whatever the plugin wants; `handle!` gets
the model and one event and returns the next model. The model lives boxed in
the host between events, so a plugin keeps state without a mutable global, and
an event that fails leaves the previous model intact.

Three kinds of file, told apart by the platform in the app header:

| Platform | What it is | Entrypoints |
| --- | --- | --- |
| `platform/main.roc` | a plugin | `init!`, `handle!` |
| `platform/config.roc` | `~/.visidatarc.roc` | `main!` |
| `platform/column.roc` | a computed column | `map_floats`, `map_strs` |

`VisiData.roc` has the API: `status!`, `add_command!`, `bind_key!`,
`subscribe!`, `set_option!`, `sheet_name!`, `nrows!`, `column!`,
`column_floats!`, `select_rows!`, `add_column!`, `push_sheet!`, and `exec!` /
`eval!` for anything it does not cover. `Value.roc` is the JSON-shaped value
type that crosses the boundary.

See [`examples/`](examples): `hello.roc`, `outliers.roc` (reads a whole column,
does the arithmetic in Roc, selects rows), `zscore.roc` (a computed column), and
`visidatarc.roc` (configuration).

## Commands

| Command | What it does |
| --- | --- |
| `roc-plugins` | what is loaded, what kind it is, and what failed to compile |
| `roc-load` | compile and load one plugin |
| `roc-reload-all` | recompile everything |
| `roc-addcol` | add a column computed by a Roc column plugin |
| `roc-status` | one line about what Roc has loaded |

Options: `roc_plugin_dir` (default `~/.visidata/roc`), `roc_engine`,
`roc_autoload`, `roc_reload_on_save`.

## Speed, honestly

[`bench/RESULTS.md`](bench/RESULTS.md) has the measurements. The short version:

- **Commands, bindings, hooks and config are fast.** 0.003–0.35 ms per event
  interpreted. This is most of what a plugin does, and it needs nothing else.
- **Computation interpreted is slow.** About 3.2–3.8 µs per element, which is
  ~22× slower than the Python expression column it would replace. Do not write
  a hot loop against the interpreted tier.
- **Marshalling is the real ceiling.** Getting a column out of VisiData's row
  objects and the results back costs ~85 ns/element before the callee runs at
  all, against a ~149 ns/element bar. Even a perfect native callee is worth
  about 1.7× there.
- So the speed case belongs with **Roc owning the data** — a loader whose
  columns never cross per row — rather than with Roc expression columns over
  Python rows. Compiled, that pays: a Roc TSV loader parses **1.44× faster
  than VisiData's own at 50k rows and 1.81× faster at 200k**, and 648× faster
  than the same loader interpreted.

Startup: 15.7 ms to compile a plugin that imports nothing, ~154 ms for a real
one. Plugins are compiled when first needed rather than all at startup, because
ten of them eagerly would be over a second.

The compiled tier is automatic when a `roc` compiler is on PATH: a plugin loads
interpreted, a native build runs on a background thread, and the next event goes
to the compiled library. Building costs ~2.9 s once and 0.1 ms thereafter,
cached by the hash of the source. With no compiler installed nothing happens and
the plugin stays interpreted, which is fine for everything but computation.

## Limits, honestly

- **A compiler panic takes VisiData with it.** A Roc `crash` is caught and
  reported, but a panic inside the compiler aborts the process. Two ways to
  provoke one are known and written up in `bench/RESULTS.md`: a plugin that
  imports a platform module the platform itself does not import, and a type
  error inside a platform module.
- **A type error in a plugin may not be reported until its first call**, as
  `platform requirement failed checking` rather than something useful. The
  embedding library only hands back diagnostics when the build fails outright.
- **Linux first.** The interpreted tier is portable; the compiled tier needs
  the shared-library patch, which is ELF-only today.
- **The engine is ~55 MB**, because it is the whole Roc compiler.

## Testing

```sh
./test/run.sh
```

`engine_test.py` drives the engine with a stub in place of VisiData, so it needs
no terminal and no sheet. `visidata_test.py` runs against the real thing.
`tier2_test.py` needs a `roc` compiler and skips cleanly without one.

## Layout

```
platform/   the Roc side: main.roc, config.roc, column.roc, VisiData.roc, Value.roc,
            host.c (the hosted functions), roc_vd_api.h (the contract)
engine/     engine.c — compile a .roc file and call its entrypoints
python/     visidata_roc: ctypes only, no C extension to build
examples/   plugins, a column, and a config
test/       run.sh, and: engine_test.py (no VisiData at all), visidata_test.py
            (the real thing), tier2_test.py (the compiled tier)
bench/      the numbers behind the speed claims
PLAN.md     the design, and what measuring it changed
```
