# The engine: the Roc compiler, inside Vim

With this library, a Vim that has `+roc` runs plugins **from their source**.
There is no build step, no cached artifact, and no compiler process: Vim loads
the library once, hands it a `.roc` file, and it compiles the plugin in Vim's
own memory and runs it through the Roc interpreter. It is what the Roc
playground does in a browser tab, pointed at an editor instead.

```
   ~/.vim/roc/hello.roc
          |
          |  roc_load_source('...')        (a Vim function; see vim-patch/)
          v
   libroc_vim_embed.so ── the Roc compiler ── LIR ── interpreter
          |                                              |
          +-- the plugin's effects: ex(), eval_json(), message() ──> Vim
```

## Building it

Two pieces: the compiler as a library, then this engine around it.

```sh
./compiler-patch/build-roc.sh   # the compiler and libroc_embed.a
./embed/build.sh                # this engine, around it
```

Then tell Vim where it is:

```vim
let g:roc_embed_library = '/path/to/roc-vim/embed/libroc_vim_embed.so'
```

From then on, `:RocPlugins` shows in-process plugins as `source`, and saving a
plugin recompiles it in place.

The library is large (~140 MB: it is a compiler) and is loaded lazily — a Vim
that never starts a source plugin never maps it.

`build.sh` needs no argument: it looks where `compiler-patch/build-roc.sh`
leaves `libroc_embed.a`. An ordinary `cc` is enough, because that library
carries Zig's compiler-rt with it. The script links with `--no-undefined` and
then dlopens the result before reporting success — a shared library links
happily with symbols nobody defines, and the failure would otherwise turn up
as an error inside Vim long afterwards.

## How it fits together

| File | What it is |
| --- | --- |
| `roc_embed.h` | the C API of `libroc_embed.a`: open a `.roc` file, call its entrypoints |
| `engine.c` | the glue Vim looks up: load, event, unload — plus the hosted functions, shared with the compiled-plugin host |
| `build.sh` | links the two into `libroc_vim_embed.so` |

`roc_embed_open` compiles the app and asks the host to resolve each hosted
symbol (`roc_vim_host_ex`, `roc_vim_host_eval`, …) to a C function. Those are
the same functions a compiled plugin uses, in
[`platform-inprocess/host.c`](../platform-inprocess/host.c), so a plugin
behaves identically whether it was built or interpreted — which is why the
examples need no changes to run either way.

`roc_embed_call` then runs an entrypoint: `roc_vim_init` for the first model,
`roc_vim_handle` for each event. The model is a `Box` the engine holds between
calls, exactly as the compiled host does.

## What it costs

- **Interpreted, not compiled.** Roc's interpreter runs the plugin's LIR
  rather than machine code. For plugins that mostly call into Vim this is not
  noticeable; for one doing real computation per keystroke, build it instead
  (`let g:roc_prefer_source = 0`).
- **Compiling takes a moment.** It happens when the plugin starts and when you
  save it, in Vim's process, so Vim is busy while it runs. A small plugin is
  well under a second.
- **A crash is a crash in Vim's process.** The interpreter turns a Roc `crash`
  into a reported error and stops that plugin, as the compiled host does. A
  bug in the compiler itself, though, lands in Vim.

## Testing it without Vim

`test/embed_test.c` plays Vim's side of the API against the engine: it loads a
plugin from source, answers its calls, sends it events, and checks what it did.

```sh
cc -o /tmp/embed_test test/embed_test.c -ldl
/tmp/embed_test embed/libroc_vim_embed.so examples-inprocess/hello.roc
```
