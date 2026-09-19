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

For in-process plugins, also build the patched pieces:

```sh
vim-patch/build-vim.sh --install        # a Vim with +roc
# and a Roc with compiler-patch/ applied; see that directory's README

# and, to run plugins from source with no build step at all:
embed/build.sh <roc checkout>/zig-out/lib/libroc_embed.a
```

```vim
let g:roc_embed_library = '/path/to/roc-vim/embed/libroc_vim_embed.so'
```

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

## Layout

```
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
embed/             the engine: the compiler in a library, so Vim runs source directly
  roc_embed.h      the C API of the embedding library
  engine.c         load a .roc file, run its entrypoints, answer its effects
  build.sh         links libroc_vim_embed.so
examples/          channel plugins to copy from
examples-inprocess/  in-process plugins to copy from
test/
  protocol_test.py   pretends to be Vim, checks a channel plugin end to end
  vim_test.sh        starts a real Vim and checks what channel plugins did
  vim_inprocess_test.sh  the same for a plugin loaded into Vim
  vim_source_test.sh     the same for a plugin Vim compiles itself
  embed_test.c       drives the engine without Vim
  inprocess_stub.c   a C plugin for testing Vim's +roc side on its own
```

## Testing

```sh
cd examples && roc build hello.roc && cd ..
python3 test/protocol_test.py      # no Vim needed
./test/vim_test.sh                 # starts a real Vim

VIM=/path/to/patched/vim ROC=/path/to/patched/roc ./test/vim_inprocess_test.sh
VIM=/path/to/patched/vim ./test/vim_source_test.sh

cc -o /tmp/embed_test test/embed_test.c -ldl   # the engine, without Vim
/tmp/embed_test embed/libroc_vim_embed.so examples-inprocess/hello.roc
```

The in-process tests skip themselves when the Vim they find has no `+roc`, and
the source test also skips without the engine library.
`protocol_test.py` is also the readable description of the channel protocol, if
you want to write a plugin in some other language.

## Notes on versions

Roc is pre-1.0 and its platform ABI still moves. This was built and tested
against Roc **nightly-2026-09-04** (channel) and roc-lang/roc at
**1d982dca** with `compiler-patch/` applied (in-process and source), plus Vim
9.1 and 9.2.1119.

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
