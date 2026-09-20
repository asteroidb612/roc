#!/usr/bin/env bash
#
# End-to-end test for examples-inprocess/vimrc.roc: the vimrc-as-a-plugin.
#
# Vim compiles the plugin from source in its own process, and this then checks
# that the options, variables and mappings it declares really did land, and
# that the things it implements itself — a GitHub link, the notebook block
# runner — do what the Vimscript versions did.
#
# The Roc compiler is deliberately unavailable as a command (g:roc_command
# points at something that always fails), so a plugin that runs at all proves
# it was compiled inside Vim.
#
# Needs a Vim with +roc (vim-patch/) and the engine library (embed/). It skips
# rather than fails when either is missing.
#
# Usage: VIM=/path/to/vim ROC_VIM_ENGINE=/path/to/libroc_vim_embed.so ./vimrc_test.sh

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
. "$repo/versions.sh"
vim_bin=$(roc_vim_find_vim "$repo")
engine=${ROC_VIM_ENGINE:-$repo/embed/libroc_vim_embed.so}

[ -n "$vim_bin" ] || { echo "SKIP: no vim (set VIM_BIN=...)"; exit 0; }
if ! "$vim_bin" --version | tr ' ' '\n' | grep -qx '+roc'; then
    echo "SKIP: this vim has no +roc; build one with vim-patch/build-vim.sh"
    exit 0
fi
if [ ! -f "$engine" ]; then
    echo "SKIP: no engine library at $engine; build one with embed/build.sh"
    exit 0
fi

work=$(mktemp -d)
trap '[ -n "${ROC_VIM_TEST_KEEP:-}" ] && echo "work directory: $work" || rm -rf "$work"' EXIT
mkdir -p "$work/plugins"

# The plugin under test, loaded from source. Its platform path is relative to
# the file, so it is rewritten for the copy.
sed "s#\"../platform-inprocess/main.roc\"#\"$repo/platform-inprocess/main.roc\"#" \
    "$repo/examples-inprocess/vimrc.roc" > "$work/plugins/vimrc.roc"

# A repository with a known remote and a known commit, so the GitHub link this
# plugin builds can be compared against one written out by hand.
mkdir -p "$work/project"
cd "$work/project"
git init -q .
git config user.email tester@example.com
git config user.name Tester
git remote add origin git@github.com:someone/some-repo.git
cat > notes.md <<'MD'
# notes

A block to run:

```
echo hello from the block
```

after the block
MD
git add notes.md
git -c commit.gpgsign=false commit -qm "notes"
ref=$(git rev-parse HEAD)

# Paths only: everything with Vimscript in it goes in steps.vim, unexpanded.
cat > "$work/vimrc" <<EOF
set nocompatible
set runtimepath^=$repo/vim
let g:roc_plugin_dir = '$work/plugins'
let g:roc_build_dir = '$work/build'
let g:roc_command = '/bin/false'
let g:roc_embed_library = '$engine'
let g:work = '$work'
source $work/steps.vim
EOF

cat > "$work/steps.vim" <<'VIM'
" No real terminal here, and nobody to answer a prompt. A hit-enter or a
" more-prompt would block Vim for good — timers included, so even the bail-out
" below would never fire. Truncate long messages, and never page.
set shortmess+=atT
set nomore
set cmdheight=2
let mapleader = ' '
let g:waited = 0
let g:errors = []

" Everything the plugin should have set, as name -> expression.
let g:checks = [
      \ ['shiftwidth', '&shiftwidth'],
      \ ['expandtab', '&expandtab'],
      \ ['swapfile', '&swapfile'],
      \ ['listchars', '&listchars'],
      \ ['includeexpr', '&includeexpr'],
      \ ['statusline', '&statusline'],
      \ ['leaderh', "maparg('<Leader>h', 'n')"],
      \ ['bracket', "maparg(']', 'n')"],
      \ ['termmap', "maparg('<c-b>', 't')"],
      \ ['visual', "maparg('//', 'v')"],
      \ ['nvpaths', "string(get(g:, 'nv_search_paths', []))"],
      \ ['aletsx', "string(get(get(g:, 'ale_pattern_options', {}), '.*\\.tsx$', {}))"],
      \ ['alehtml', "string(get(get(g:, 'ale_pattern_options', {}), '.*\\.html$', {}))"],
      \ ['nerdignore', "string(get(g:, 'NERDTreeIgnore', []))"],
      \ ['jsrunner', "get(g:, 'test#javascript#runner', '')"],
      \ ['gruvbox', "get(g:, 'gruvbox_contrast_dark', '')"],
      \ ]

function! Step1(timer) abort
  let g:waited += 1
  if !exists(':RocGithubUrl') && g:waited < 200
    call timer_start(300, 'Step1')
    return
  endif
  edit notes.md
  " Line 6 is the one inside the fenced block.
  call cursor(6, 1)
  try | silent! RocGithubUrl | catch | call add(g:errors, v:exception) | endtry
  call cursor(6, 1)
  try | silent! RocRunBlock | catch | call add(g:errors, v:exception) | endtry
  call timer_start(300, 'Step2')
endfunction

function! Step2(timer) abort
  let lines = []
  for check in g:checks
    call add(lines, check[0] . '=' . eval(check[1]))
  endfor
  call add(lines, 'url=' . getreg(has('clipboard') ? '+' : '"'))
  call add(lines, 'buffer=' . join(getline(1, '$'), '|'))
  call add(lines, 'errors=' . string(g:errors))
  call add(lines, 'built=' . (isdirectory(g:work . '/build')
        \ ? len(glob(g:work . '/build/*', 0, 1)) : 0))
  call writefile(lines, g:work . '/result.txt')
  qall!
endfunction

autocmd VimEnter * call timer_start(300, 'Step1')
autocmd VimEnter * call timer_start(180000, { t -> execute('qall!') })
VIM

echo "running vim (it compiles the vimrc plugin in its own process)..."
script -qec "$vim_bin -u '$work/vimrc' -i NONE" /dev/null >/dev/null || true

if [ ! -f "$work/result.txt" ]; then
    echo "FAIL: vim exited without writing a result"
    exit 1
fi

cat "$work/result.txt"
echo

failures=0
check() {
    if grep -q -- "$1" "$work/result.txt"; then
        echo "  ok   $2"
    else
        echo "  FAIL $2  (wanted /$1/)"
        failures=$((failures + 1))
    fi
}

check "^built=0$"                       "nothing was built: the plugin was compiled inside Vim"
check "^errors=\[\]$"                   "neither command raised an error"

check "^shiftwidth=2$"                  "options: shiftwidth"
check "^expandtab=1$"                   "options: expandtab"
check "^swapfile=0$"                    "options: noswapfile"
check "^listchars=tab:>-$"              "options: listchars keeps its escaped space"
check "^includeexpr=substitute(v:fname" "options: includeexpr"
check "^statusline=%f %m%r%h%w%{get(g:,'roc_ale_status','')}%=%l/%L col %c$" \
                                        "options: statusline built from three pieces"

check "^leaderh=:RocGithubUrl<CR>$"     "mappings: a key bound to one of the plugin's commands"
check "^bracket=:ALENext<CR>$"          "mappings: a plain Vimscript one"
check "^termmap=<Left>$"                "mappings: terminal-mode"
check "^visual=y/.V<C-R>=escape"        "mappings: visual-mode search for the selection"

check "nvpaths=.*BitTorrent Sync"       "variables: nv_search_paths built from notes_dir"
check "nvpaths=.*~/iio/tools/cli"       "variables: nv_search_paths built from iio_dir"
check "nerdignore=.*'Downloads'"        "variables: NERDTreeIgnore"
check "^jsrunner=mocha$"                "variables: one with # in its name"
check "^gruvbox=hard$"                  "colours: contrast set before the colorscheme"

check "aletsx=.*'ale_linters': \['eslint', 'tsserver'\]" "ale: linters for .tsx"
check "aletsx=.*'ale_fixers': \['eslint'\]"              "ale: fixers for .tsx"
check "aletsx=.*'ale_fix_on_save': 1"                    "ale: fix on save for .tsx"
check "alehtml=.*'ale_fixers': \['eslint'\]"             "ale: fixers for .html"
check "^alehtml={'ale_fixers': \['eslint'\]}$"           "ale: .html has no ale_fix_on_save key"

check "^url=https://github.com/someone/some-repo/blob/$ref/notes.md?plain=1#L6$" \
                                        "RocGithubUrl: ssh remote rewritten, .git dropped, line kept"
check "buffer=.*|\`\`\`|# <output from the block above.*|hello from the block|\`\`\`|" \
                                        "RocRunBlock: ran the block, wrote the output back in a closed fence"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
