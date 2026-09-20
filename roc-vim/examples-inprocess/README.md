# In-process examples

Plugins that run inside Vim, built on [`../platform-inprocess`](../platform-inprocess).
A Vim with `+roc` loads them either from a built shared library or, with the
engine in [`../embed`](../embed), straight from the `.roc` source.

| File | What it shows |
| --- | --- |
| `hello.roc` | the shape of a plugin: a model, `init!`, `handle!` |
| `complete.roc` | the thing a plugin beside Vim cannot do — answer a `completefunc` while Vim waits |
| `vimrc/` | a real vimrc, rewritten as a plugin: `main.roc` plus `Notebook.roc` |
| `vimrc.vim` | the dozen lines of Vimscript the vimrc plugin still needs |

## vimrc/

A configuration file is two things wearing one hat. Most of it is data —
options, variables, mappings, colours — and the rest is a program: build a URL,
run the block under the cursor, count what the linter found. Vimscript writes
both the same way, which is why the data ends up in backslash continuations and
the program ends up with no types on it.

Here they are separated. The data is Roc lists you can read top to bottom:

```roc
ale_rules : List(AleRule)
ale_rules = [
    { suffix: "rs", linters: ["cargo"], fixers: ["rustfmt"], fix_on_save: True },
    { suffix: "css", linters: [], fixers: ["prettier"], fix_on_save: True },
    ...
]
```

and the program is functions with types on them:

```roc
github_url! : () => Try({}, _)
github_url! = || {
    remote = Str.trim(Vim.system!("git config --get remote.origin.url")?)
    ...
}
```

`vimrc.vim` is what is left over: the plugin manager, `mapleader`, and
`exrc`/`secure`, all of which have to run before Vim loads a plugin.

### Trying it

```sh
cp -r examples-inprocess/vimrc ~/.vim/roc/
vim -u examples-inprocess/vimrc.vim
```

Vim treats the directory as one plugin named `vimrc`, and saving any file in
it — `main.roc` or `Notebook.roc` — rebuilds and restarts the whole thing.

With `g:roc_embed_library` set, Vim compiles it at startup and recompiles it
whenever you save it. A file this size takes long enough to compile that you
will notice it at startup — see the note in [`../embed/README.md`](../embed/README.md);
building it once (`g:roc_prefer_source = 0`) makes startup instant again.

### The part with its own tests

`Notebook.roc` holds the question "which fenced block does the cursor mean?",
which turns out to have more edge cases than it looks: an unclosed fence, the
cursor sitting below the last block, fences indented inside a list item. It
imports no platform, so it is ordinary Roc and `roc test` runs it:

```sh
roc test examples-inprocess/vimrc/Notebook.roc      # 19 tests
../test/module_test.sh                              # or every module
```

The Vim half — read the buffer, run the code, write the output back — stays in
`main.roc` as `run_block!`, and is thin. That division is the general rule: a
module that imports `vim.Vim` cannot be tested on its own, because `roc test`
has no platform to resolve `vim` against.

### What it changed on the way

The rewrite kept the original's behaviour, except where the original was not
doing what it looked like it was doing:

- `g:gruvbox_contrast_dark` is set **before** `:colorscheme gruvbox`. The
  colorscheme reads it as it loads, so setting it afterwards did nothing.
- One `FileType` handler covers `typescript` and `typescriptreact`. The
  original had two `augroup typescript_folding` blocks, and the second one's
  `au!` threw away the first, so plain TypeScript never got syntax folding.
- The note highlights are re-applied on `BufWinEnter`. `matchadd()` belongs to
  a window, not a buffer, which is why they used to follow you into an
  unrelated `.js` file — the reason the original had that autocmd commented
  out.
- `.roc` files get `setlocal syntax=ruby` rather than `set`, so the syntax does
  not leak into the next buffer in that window.
- The GitHub URL drops a **trailing** `.git` instead of the first `.git`
  anywhere in the remote.
- `:RocRunBlock` closes the fence it opens, so a second run does not nest
  inside the first run's output.
- The status line asks for `g:roc_ale_status`, which is recomputed on
  `ALELintPost`, rather than calling a function on every redraw.

And two things were left alone on purpose: `<leader>m` was mapped twice in the
original and the second one won, so `:make` still has no key; and
`ShowCalendarIfNoFile` was defined but never called, so it is a command
(`:RocCalendar`) rather than something that runs at startup.
