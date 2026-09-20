# roc-vim

Write Vim plugins in [Roc](https://roc-lang.org). Drop a `.roc` file in
`~/.vim/roc/`, start Vim, and it is built if it changed and loaded as a running
plugin.

```roc
app [main!] { vim: platform "platform/main.roc" }

import vim.Vim

main! : () => Try({}, _)
main! = || {
    Vim.subscribe!(["BufWritePost"])
    Vim.add_command!("RocHello")
    loop!(0)
}

loop! : I64 => Try({}, _)
loop! = |writes|
    match Vim.receive!() {
        Closed => Ok({})
        Notify(event) =>
            if event.name == "BufWritePost" {
                Vim.echom!("that is ${I64.to_str(writes + 1)} write(s) today")
                loop!(writes + 1)
            } else {
                Vim.echo!("hello from Roc")
                loop!(writes)
            }
        _ => loop!(writes)
    }
```

## Three ways to run a plugin

|  | **Channel** (`platform/`) | **In-process, built** (`platform-inprocess/`) | **In-process, from source** (`embed/`) |
| --- | --- | --- | --- |
| The plugin is | a program Vim runs as a job | a shared library Vim loads with `dlopen()` | a `.roc` file Vim compiles in its own memory |
| Effects are | messages over a JSON channel | direct calls into Vim | direct calls into Vim |
| Runs as | compiled machine code | compiled machine code | Roc's interpreter |
| Build step | `roc build`, run by Vim | `roc build`, run by Vim | none at all |
| Needs | stock Vim 8+, released Roc | Vim with [`+roc`](vim-patch/), [patched Roc](compiler-patch/) | the same, plus the [engine library](embed/) |
| Slow work | fine, Vim carries on | freezes Vim while it runs | freezes Vim while it runs |
| A crash | kills the plugin only | is caught; the plugin stops | is caught; the plugin stops |
| Answering Vimscript | a round trip, with a timeout | a function call | a function call |

All three are in this repository and all three work; they share the API, the
Vim-side plugin manager, and the examples. **Channel is the default**: it works
with a Vim and a Roc you already have. The in-process ones are for plugins that
must answer Vim synchronously — a `completefunc`, an `'operatorfunc'`, an
expression mapping — and source mode additionally removes the build step, so
`:w` reloads a plugin with nothing in between.

roc-vim decides from a plugin's app header: `app [main!]` is a channel plugin,
`app [Model, plugin]` runs inside Vim. For an in-process plugin it loads the
source directly when the engine library is configured, and otherwise builds it.
The same file works either way.

## Getting started

You need Vim 8 or later with `+job` and `+channel` (`vim --version | grep
channel`), a [Roc compiler](https://roc-lang.org/install), and a C toolchain
that can build against the libc Roc links with — on Linux that means musl:

```sh
sudo apt install musl-tools     # Debian/Ubuntu
sudo dnf install musl-gcc       # Fedora
```

Then:

```sh
git clone <this repo>
cd roc-vim
./setup.sh
vim            # :RocHello
```

`setup.sh` builds the platforms' native hosts, links the Vim plugin into
`~/.vim/pack/roc/start/`, creates `~/.vim/roc/` for your plugins, and puts the
hello example there. Pass `--examples` to get all of them.

### Everything, from a fresh clone

The steps above want a Roc on your PATH, which is enough for channel plugins.
In-process plugins need the patched compiler, and running plugins from source
needs the embedding library built from it. Three scripts, in this order, and
nothing is installed outside the clone:

```sh
./compiler-patch/build-roc.sh    # roc + libroc_embed.a  (clones Roc; slow)
./embed/build.sh                 # the engine Vim loads plugins with
./vim-patch/build-vim.sh         # a Vim with +roc       (clones Vim; slow)
./setup.sh                       # hosts, the Vim package, a plugin directory
```

Each one finds what the one before it built, so none of them needs an
argument. `setup.sh` prints the two lines to paste into your vimrc at the end.

The versions all of this is pinned to live in one file, [`versions.sh`](versions.sh):
the Roc commit, the Zig it builds with, and the Vim tag the patch is made
against. That is the only place to change when moving to a newer compiler.

## How it works

### Channel plugins

Vim can run programs and talk to them, which is how plugins in other languages
usually work. A Roc plugin is a program; roc-vim starts one job per plugin when
Vim starts and gives each a JSON channel (`:help channel`).

```
   ~/.vim/roc/hello.roc  --(roc build)-->  ~/.cache/roc-vim/hello
                                                  |
   Vim  <-------------- JSON channel ------------ | (one job per plugin)
    |     ["ex", "echo 'hi'"]                     |
    |     ["expr", "line('$')", -1]  --> [-1, 42] |
    |     [7, {"event": "BufWritePost", ...}] --> |
```

The plugin keeps running for as long as Vim does, so its state is just a value
it passes to the next turn of its loop. It cannot crash Vim, and slow work in a
plugin does not block the editor.

### In-process plugins

A Vim built with the `+roc` patch has three more functions — `roc_load()`,
`roc_event()`, `roc_unload()` — which load a shared library into Vim's own
process and call it.

```
   ~/.vim/roc/hello.roc  --(roc build)-->  ~/.cache/roc-vim/hello.so
                                                  |
   Vim  ------------------ dlopen ----------------+
    |  roc_vim_plugin_init(&api, handle)   -> the plugin's init! runs
    |  roc_vim_plugin_event("{...}")       -> the plugin's handle! runs
    |     ^ the plugin calls back through `api`: ex(), eval_json(), message()
```

Vim owns the loop, so a plugin is a model and a handler: `init!` returns the
first model, `handle!` takes the model and an event and returns the next one.
`Vim.eval!` is a call into Vim's evaluator that returns right away, and
`Vim.reply!` answers `roc#ask()` the way a function does.

### Plugins from source

With the [engine library](embed/) configured, Vim skips the build entirely:

```
   ~/.vim/roc/hello.roc
          |
   Vim ---+--> libroc_vim_embed.so: the Roc compiler, in Vim's process
          |         |
          |         +-- compiles the plugin, runs it through the interpreter
          +<--------+-- the plugin's effects come straight back into Vim
```

The plugin is the same file; only the way it is run differs. `:RocPlugins`
shows `source` instead of `in-process`, and saving the file recompiles it in
place. Set `g:roc_prefer_source = 0` to build instead — worth doing for a
plugin that does heavy computation, since the interpreter is slower than
compiled code.

Everything crossing the boundary is still text: Vim's own syntax for commands
and expressions, JSON for values. The plugin library's ABI is four function
pointers wide ([roc_vim_api.h](platform-inprocess/roc_vim_api.h)), so a plugin
built by a different Roc still loads.

## Writing a plugin

### Channel

A plugin sets itself up and then loops. In the loop it waits for an event, does
something, and calls itself with the next state.

```roc
main! : () => Try({}, _)
main! = || {
    Vim.subscribe!(["CursorHold", "BufWritePost *.md"])
    Vim.add_mapping!("n", "<Leader>rr")
    Vim.add_command!("Ready")      # register commands last; see below
    loop!({ count: 0 })
}
```

The events it can get are `Notify({ name, data, reply_to })`, `Message({ id,
body })`, `Timeout` (from `receive_timeout!`) and `Closed` (Vim is exiting, so
return from `main!`).

### In-process

```roc
app [Model, plugin] { vim: platform "platform-inprocess/main.roc" }

import vim.Vim

Model : I64

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    Vim.subscribe!(["BufWritePost"])
    Vim.add_command!("RocHello")
    Ok(0)
}

handle! : Model, Vim.Event => Try(Model, _)
handle! = |writes, event|
    if event.name == "BufWritePost" {
        Ok(writes + 1)
    } else {
        Vim.echom!("seen ${I64.to_str(writes)} write(s)")
        Ok(writes)
    }
```

An event here is a record: `{ name, data }`. Returning `Err` from `handle!`
reports the error and keeps the model the event started with.

In both shapes, register commands and mappings **last**. A plugin sets itself
up in order, so `:Ready` existing tells you the subscriptions above it are in
place too.

> **A plugin has to use `?` somewhere.** The platform asks for
> `Try(model, [VimErr(Str), ..])`, and until something in the plugin propagates
> an error with `?`, the error type stays an unbound variable and the compiler
> says `platform requirement failed checking` — pointing at the platform rather
> than at your code. One `?` anywhere (`name = Vim.buffer_name!()?`) settles it.

### More than one file

A plugin can be a directory instead of a file: `main.roc` beside the modules it
imports. Vim treats the directory as one plugin, named after it, and saving any
file in it rebuilds and restarts the whole thing.

```
~/.vim/roc/vimrc/
  main.roc        app [Model, plugin] { vim: platform "..." }
  Settings.roc    module [options, mappings, ...]
  Notebook.roc    module [run_block!]
```

A module can `import vim.Vim` and do effects of its own, exactly as the app
does — it is not limited to pure helpers. Only `main.roc` is an `app`, which is
how Vim tells which file to build. This works in all three modes, source
loading included.

### Modules you can test

A module with **no platform in it** is just Roc, so `roc test` runs it on its
own — no Vim, no plugin, no build step:

```sh
./test/module_test.sh                                  # every module
roc test examples-inprocess/vimrc/Notebook.roc         # or just one
```

That is the reason to pull logic out of a plugin. The notebook in the vimrc
example is the case for it: deciding *which* fenced block the cursor means has
real edge cases — an unclosed fence, the cursor below the last block, fences
indented inside a list item — and each one is an `expect` line rather than
something to go and try in Vim.

```roc
Notebook := [].{
    find_block : List(Str), I64 -> Try(Block, [NoBlock])
    ...
}

expect code_at(two_blocks, 6) == ["echo one"]   # between blocks: the one above
expect !found(["```", "echo one"], 2)           # an unclosed fence is no block
```

So the split that pays is **pure logic into a module, effects left in the
app**. A module that imports `vim.Vim` cannot be tested on its own: `roc test`
has no platform to resolve `vim` against, and fails. In the vimrc example
`find_block` is in `Notebook.roc` with its tests, while `run_block!` — read the
buffer, run the code, write the output back — stays in `main.roc` and is thin.

Write modules in the **type-module** form (`Name := [].{ ... }`, no `module`
header), the way the platform's own `Vim.roc` and `Value.roc` do. The `module
[...]` header still works but is deprecated, and `roc test` exits non-zero on
the warning.

`data` is a [`Value`](platform/Value.roc) — the JSON-shaped type everything
crossing into Roc uses. For an autocommand event it holds the buffer number,
file name, filetype, cursor position and mode; for a command it also holds
`args`, `line1` and `line2`.

```roc
file = Value.str_or(Value.field_or_null(event.data, "file"), "")
```

### The API

Both platforms expose the same `Vim` module, with doc comments on each
function:

```roc
Vim.ex!("split ${Vim.quote(path)}")     # run any Ex command
Vim.echo!("hi")                         # and the usual shorthands
Vim.normal!("ggVG=")

count = Vim.eval_int!("line('$')")?     # ask Vim something
name = Vim.buffer_name!()?
lines = Vim.lines!()?

Vim.set_line!(3, "new text")            # change the buffer
Vim.append_lines!(0, ["at the top"])
Vim.set_var!("g:my_count", Value.Int(count))

_ = Vim.call!("complete", [Value.Int(col), Value.Array(items)])?
```

The channel platform adds `receive!`, `receive_timeout!` and `send!`; the
in-process platform has no `receive!` at all, because Vim calls the plugin
rather than the other way round.

### Answering Vim

Vimscript can ask a plugin a question and wait for the answer:

```vim
echo roc#ask('ticker', 'uptime', 0)
```

A channel plugin answers a `Notify` whose `reply_to` is not 0 with
`Vim.reply!(id, value)`; an in-process plugin calls `Vim.reply!(value)` while
handling the event.

### The edit-run loop

Saving a plugin's source rebuilds and restarts it, so `:w` is the whole loop.
`:RocLog` shows what channel plugins wrote with `Vim.log!` and any build
errors; in-process plugins log to `:messages`. `:RocPlugins` shows what is
running, and how. See `:help roc-vim` for the rest.

## Examples

| File | Shows |
| --- | --- |
| [examples/hello.roc](examples/hello.roc) | a command, an event, state between events |
| [examples/word_count.roc](examples/word_count.roc) | reading the buffer, setting a variable for the status line |
| [examples/uppercase.roc](examples/uppercase.roc) | changing the buffer, command ranges |
| [examples/ticker.roc](examples/ticker.roc) | doing work between events, answering `roc#ask()` |
| [examples-inprocess/hello.roc](examples-inprocess/hello.roc) | the same plugin, loaded into Vim |
| [examples-inprocess/complete.roc](examples-inprocess/complete.roc) | a `completefunc`: Vim waits for the answer, so only an in-process plugin can give it |
| [examples-inprocess/vimrc/](examples-inprocess/vimrc/) | a whole working vimrc as a plugin — options and mappings as data, the functions with types on them, and the notebook logic in a tested module |

## Layout

```
versions.sh        the one place naming the Roc commit, the Zig, the Vim tag
platform/          the channel platform (a plugin is a program)
  main.roc         what a plugin provides, what the host provides
  Vim.roc          the API plugins use
  Value.roc        JSON-shaped values, and parsing/encoding them
  Host.roc         the hosted effects, in Roc terms
  host.c           the native side: speaks Vim's channel protocol
  build.sh         builds targets/<target>/libhost.a
platform-inprocess/  the in-process platform (a plugin is a library)
  main.roc         init!/handle!, and the model boxed across events
  Vim.roc          the same API, as direct calls
  host.c           the native side: calls Vim through its function table
  roc_vim_api.h    the table Vim hands the plugin
vim/               the Vim side, installed as a package
  plugin/roc.vim   options, commands, and the VimEnter hook
  autoload/roc.vim finding, building, starting and talking to plugins
  doc/roc.txt      :help roc-vim
vim-patch/         the +roc feature for Vim, as a patch plus a build script
compiler-patch/    the Roc patches: a shared-library fix, and the embedding library
  build-roc.sh     clones Roc at the pinned commit, patches it, builds both
embed/             the engine: the compiler in a library, so Vim runs source directly
  roc_embed.h      the C API of the embedding library
  engine.c         load a .roc file, run its entrypoints, answer its effects
  build.sh         links libroc_vim_embed.so
examples/          channel plugins to copy from
examples-inprocess/  in-process plugins to copy from
  vimrc/           a real vimrc, rewritten as a plugin
    main.roc       the app: settings, mappings, and the handlers
    Notebook.roc   which fenced block the cursor means, and its tests
  vimrc.vim        the dozen lines of Vimscript it still needs
test/
  protocol_test.py   pretends to be Vim, checks a channel plugin end to end
  vim_test.sh        starts a real Vim and checks what channel plugins did
  vim_inprocess_test.sh  the same for a plugin loaded into Vim
  vim_source_test.sh     the same for a plugin Vim compiles itself
  vimrc_test.sh          checks the vimrc plugin's settings, mappings and commands
  vim_modules_test.sh    a plugin split across files: main.roc plus its modules
  module_test.sh         the `expect` tests inside modules, with no Vim at all
  embed_test.c       drives the engine without Vim
  inprocess_stub.c   a C plugin for testing Vim's +roc side on its own
```

## Testing

```sh
# The tests find the compiler and the Vim this repository built, so usually:
./test/module_test.sh              # no Vim, no plugin: just Roc
python3 test/protocol_test.py      # no Vim needed
./test/vim_test.sh                 # starts a real Vim

./test/vim_inprocess_test.sh       # finds the compiler and Vim it built
./test/vim_source_test.sh
VIM_BIN=/path/to/patched/vim ./test/vimrc_test.sh
VIM_BIN=/path/to/patched/vim ./test/vim_modules_test.sh

cc -o /tmp/embed_test test/embed_test.c -ldl   # the engine, without Vim
/tmp/embed_test embed/libroc_vim_embed.so examples-inprocess/hello.roc
```

The in-process tests skip themselves when the Vim they find has no `+roc`, and
the source test also skips without the engine library.
`protocol_test.py` is also the readable description of the channel protocol, if
you want to write a plugin in some other language.

## Notes on versions

Roc is pre-1.0 and its platform ABI still moves, so roc-vim pins one compiler
and uses it for everything: **roc-lang/roc at `1d982dca`** (2026-09-18) with
`compiler-patch/` applied, built with **Zig 0.16.0**. Vim 9.1 for channel
plugins, and 9.2.1119 for the `+roc` patch.

A released nightly would do for channel plugins, and one did for a while. But
in-process plugins need the shared-library fix and source loading needs the
embedding library, both of which come from `compiler-patch/` — so rather than
keep two compilers around and have to remember which one built what, there is
one, and it is a little behind the nightlies on purpose.

The pins are in [`versions.sh`](versions.sh), and `compiler-patch/build-roc.sh`
reads them.

If a newer compiler rejects the platform, the generated ABI header is the thing
to refresh — it is what maps the effects in `Host.roc` to C functions in
`host.c`:

```sh
roc glue "$ROC_C_GLUE" platform/generated platform/main.roc
cp platform/generated/roc_platform_abi.h platform/
platform/build.sh
```

`$ROC_C_GLUE` is `CGlue.roc` from your compiler's release (it also lives at
`src/glue/src/CGlue.roc` in the Roc repository — use the copy matching your
compiler's commit). If the hosted function signatures in the header change,
`host.c` needs the same change.

## Linking, and other libcs

Channel plugins are linked statically against musl by default, so
`platform/build.sh` builds that host with `musl-gcc` (or `zig cc`). In-process
plugins are loaded into Vim, so they are built against the system libc instead
(`x64glibc`), which `platform-inprocess/build.sh` and the Vim side do for you.
On a musl system such as Alpine, set `let g:roc_build_target = 'x64musl'`.

macOS works the same way for channel plugins (`platform/build.sh arm64mac`).
In-process plugins on macOS need the Mach-O half of `compiler-patch/` first.
