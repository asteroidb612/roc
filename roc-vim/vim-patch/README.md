# A Vim that loads Roc plugins into its own process

`vim-roc-interface.patch` adds a `+roc` feature to Vim: `src/if_roc.c`, plus one
entry each in `evalfunc.c`, `feature.h`, `proto.h`, `version.c`, `errors.h` and
the `Makefile`. It was made against Vim **9.2.1119**.

```sh
./build-vim.sh              # clone, patch, build (nothing installed)
./build-vim.sh --install    # ...and install it to ~/.local
```

Check it took:

```sh
vim --version | tr ' ' '\n' | grep roc      # +roc
```

## What it adds

Three functions, and `has('roc')`:

```vim
let handle = roc_load('/path/to/plugin.so')     " load a plugin
let answer = roc_event(handle, 'BufWritePost', {'file': 'x.md'})
call roc_unload(handle)
```

`roc_load()` opens the shared library with `dlopen()`, checks that it was built
against the same ABI version, hands it a table of Vim functions, and calls its
`init`. `roc_event()` calls into the plugin and hands back whatever it answers,
decoded from JSON. `roc_unload()` lets it clean up and closes the library.

roc-vim's Vimscript layer uses these; you should not need to call them
directly.

## What crosses the boundary

Only text. Vim gives the plugin four functions:

| Function | What it does |
| --- | --- |
| `ex(cmd, len)` | run an Ex command (`do_cmdline_cmd`) |
| `eval_json(expr, len, &len)` | evaluate an expression, return its value as JSON |
| `free_result(ptr)` | free what `eval_json` returned |
| `message(text, len, is_error)` | show a message, or an error |

and calls the plugin with one JSON string per event. Nothing in this interface
depends on how the Roc compiler lays out its types, so a plugin built by a
different Roc version still loads — the ABI version in
`platform-inprocess/roc_vim_api.h` is what has to match, and it only changes
when this table does.

## What it costs

A plugin in Vim's process is not sandboxed from Vim:

- **It blocks Vim while it runs.** An event handler that takes a second freezes
  the editor for a second. The channel platform (`platform/`) is the one to use
  for work that takes time.
- **A crash is caught, but not cleanly.** The host in the plugin library sets a
  landing point before each call, so a Roc `crash` reports and stops that
  plugin rather than killing Vim — but whatever the plugin had allocated at
  that moment is leaked, and the plugin takes no further events.
- **Re-entry is refused.** If an event handler runs an Ex command that fires an
  autocommand the same plugin subscribed to, the second call is refused with an
  error rather than handing the plugin state it is in the middle of using.

## Upstreaming

This is a patch, not a pull request to Vim. If it were one, the parts that
would need work first: Windows support (`LoadLibrary` instead of `dlopen`),
a `:rocdo`-style command set matching the other `if_*` interfaces, tests under
`src/testdir/`, and documentation in `runtime/doc/`.
