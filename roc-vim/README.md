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

`setup.sh` builds the platform's native host, links the Vim plugin into
`~/.vim/pack/roc/start/`, creates `~/.vim/roc/` for your plugins, and puts the
hello example there. Pass `--examples` to get all of them.

## How it works

Vim has no way to load a shared library into its own process, but it can run
programs and talk to them, which is how plugins in other languages usually work.
A Roc plugin is a program; roc-vim starts one job per plugin when Vim starts and
gives each a JSON channel (`:help channel`).

```
   ~/.vim/roc/hello.roc  --(roc build)-->  ~/.cache/roc-vim/hello
                                                  |
   Vim  <-------------- JSON channel ------------ | (one job per plugin)
    |     ["ex", "echo 'hi'"]                     |
    |     ["expr", "line('$')", -1]  --> [-1, 42]  |
    |     [7, {"event": "BufWritePost", ...}] --> |
```

Which means:

- **Plugins are loaded when Vim starts**, and stopped when it exits. Dropping a
  new `.roc` file in the directory is all it takes to add one.
- **A plugin keeps its own state.** It is a program that runs for as long as
  Vim does, so a counter is just a number you pass to the next loop.
- **A plugin cannot crash Vim.** It is a separate process; if it dies, Vim says
  so and carries on.
- **Anything Vim can do, a plugin can ask for**, because `Vim.ex!` and
  `Vim.call!` reach the whole of Vimscript.

The cost is that the channel is asynchronous: `Vim.ex!` does not wait for Vim,
and events arrive when they arrive. When a plugin needs an answer (`Vim.eval!`,
`Vim.call!`) it waits for it, and the host matches the answer to the request.

## Writing a plugin

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

Register commands and mappings **last**. A plugin sets itself up in order, so
`:Ready` existing tells you the subscriptions above it are in place too.

The events a plugin can get are:

| Event | When |
| --- | --- |
| `Notify({ name, data, reply_to })` | a subscribed autocommand, a command, a mapping, or `roc#send()` |
| `Message({ id, body })` | a message that did not follow the `roc#notify()` shape |
| `Timeout` | `receive_timeout!` ran out of time |
| `Closed` | Vim closed the channel; return from `main!` |

`data` is a [`Value`](platform/Value.roc) — the JSON-shaped type everything
crossing the channel uses. For an autocommand event it holds the buffer number,
file name, filetype, cursor position and mode; for a command it also holds
`args`, `line1` and `line2`.

```roc
Notify(event) => {
    file = Value.str_or(Value.field_or_null(event.data, "file"), "")
    ...
}
```

### The API

Everything lives in [`platform/Vim.roc`](platform/Vim.roc), which has doc
comments for each function:

```roc
Vim.ex!("split ${Vim.quote(path)}")     # run any Ex command
Vim.echo!("hi")                         # and the usual shorthands
Vim.normal!("ggVG=")

count = Vim.eval_int!("line('$')")?     # ask Vim something, wait for it
name = Vim.buffer_name!()?
text = Vim.line!(3)?
lines = Vim.lines!()?

Vim.set_line!(3, "new text")            # change the buffer
Vim.append_lines!(0, ["at the top"])
Vim.set_var!("g:my_count", Value.Int(count))

_ = Vim.call!("complete", [Value.Int(col), Value.Array(items)])?
```

### Answering Vim

Vimscript can ask a plugin a question and wait for the answer:

```vim
echo roc#ask('ticker', 'uptime', 0)
```

The plugin gets a `Notify` whose `reply_to` is not 0:

```roc
Notify(event) =>
    if event.reply_to != 0 {
        Vim.reply!(event.reply_to, Value.Int(seconds))
        loop!(seconds)
    } else { ... }
```

### The edit-run loop

Saving a plugin's source rebuilds and restarts it, so `:w` is the whole loop.
`:RocLog` shows what your plugins wrote with `Vim.log!` and any build errors;
`:RocPlugins` shows what is running. See `:help roc-vim` for the rest.

## Examples

| File | Shows |
| --- | --- |
| [hello.roc](examples/hello.roc) | a command, an event, state between events |
| [word_count.roc](examples/word_count.roc) | reading the buffer, setting a variable for the status line |
| [uppercase.roc](examples/uppercase.roc) | changing the buffer, command ranges |
| [ticker.roc](examples/ticker.roc) | doing work between events, answering `roc#ask()` |

## Layout

```
platform/          the Roc platform
  main.roc         what a plugin provides, what the host provides
  Vim.roc          the API plugins use
  Value.roc        JSON-shaped values, and parsing/encoding them
  Host.roc         the hosted effects, in Roc terms
  host.c           the native side: speaks Vim's channel protocol
  roc_platform_abi.h   generated by `roc glue` from main.roc
  build.sh         builds targets/<target>/libhost.a
vim/               the Vim side, installed as a package
  plugin/roc.vim   options, commands, and the VimEnter hook
  autoload/roc.vim finding, building, starting and talking to plugins
  doc/roc.txt      :help roc-vim
examples/          plugins to copy from
test/
  protocol_test.py pretends to be Vim, checks a plugin end to end
  vim_test.sh      starts a real Vim and checks what the plugins did
```

## Testing

```sh
cd examples && roc build hello.roc && cd ..
python3 test/protocol_test.py      # no Vim needed
./test/vim_test.sh                 # starts a real Vim
```

`protocol_test.py` is also the readable description of the wire protocol, if
you want to write a plugin in some other language.

## Notes on versions

Roc is pre-1.0 and its platform ABI still moves. This platform was built and
tested against Roc **nightly-2026-09-04** and Vim 9.1.

If a newer compiler rejects it, the generated ABI header is the thing to
refresh — it is what maps the effects in `Host.roc` to C functions in `host.c`:

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

Roc links plugins statically against musl by default, so `platform/build.sh`
builds the host with `musl-gcc` (or `zig cc` if that is what you have). To use
glibc instead:

```sh
platform/build.sh x64glibc
# and in your vimrc:
let g:roc_build_target = 'x64glibc'
```

macOS works the same way with `platform/build.sh arm64mac` (or `x64mac`), where
the system libc needs no extra pieces.
