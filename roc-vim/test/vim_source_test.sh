#!/usr/bin/env bash
#
# End-to-end test for source-loaded plugins: Vim compiles the plugin itself,
# with the Roc compiler loaded into its own process, and runs it from there.
#
# The Roc compiler is deliberately unavailable as a command during this test
# (g:roc_command points at something that always fails), so a plugin that runs
# at all proves it was compiled inside Vim.
#
# Needs a Vim with +roc (vim-patch/) and the engine library (embed/). It skips
# rather than fails when either is missing.
#
# Usage: VIM=/path/to/vim ROC_VIM_ENGINE=/path/to/libroc_vim_embed.so ./vim_source_test.sh

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

cat > "$work/plugins/tester.roc" <<EOF
app [Model, plugin] { vim: platform "$repo/platform-inprocess/main.roc" }

import vim.Vim
import vim.Value

Model : I64

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    Vim.subscribe!(["BufWritePost"])
    Vim.add_command!("RocTest")
    Ok(0)
}

handle! : Model, Vim.Event => Try(Model, _)
handle! = |writes, event|
    if event.name == "command:RocTest" {
        file = Vim.buffer_name!()?
        Vim.set_var!("g:roc_test_saw", Value.Text(file))
        Vim.set_line!(1, "written by an interpreted plugin")
        Vim.ex!("let g:roc_test_done = 1")
        Ok(writes)
    } else if event.name == "BufWritePost" {
        Ok(writes + 1)
    } else if event.name == "writes" {
        Vim.reply!(Value.Int(writes))
        Ok(writes)
    } else {
        Ok(writes)
    }
EOF

cat > "$work/vimrc" <<EOF
set nocompatible
set runtimepath^=$repo/vim
let g:roc_plugin_dir = '$work/plugins'
let g:roc_build_dir = '$work/build'
" Nothing may be built: if the plugin runs, it was compiled inside Vim.
let g:roc_command = '/bin/false'
let g:roc_embed_library = '$engine'

let g:waited = 0
function! Step1(timer) abort
  let g:waited += 1
  if !exists(':RocTest') && g:waited < 120
    call timer_start(500, 'Step1')
    return
  endif
  call setline(1, ['first line', 'second line'])
  write
  RocTest
  let g:waited = 0
  call timer_start(300, 'Step2')
endfunction

function! Step2(timer) abort
  let g:waited += 1
  if !exists('g:roc_test_done') && g:waited < 60
    call timer_start(300, 'Step2')
    return
  endif
  call writefile([
        \\ 'saw=' . get(g:, 'roc_test_saw', ''),
        \\ 'line1=' . getline(1),
        \\ 'asked=' . string(roc#ask('tester', 'writes', 0)),
        \\ 'built=' . (isdirectory('$work/build') ? len(glob('$work/build/*', 0, 1)) : 0),
        \\ 'status=' . substitute(join(split(execute('RocPlugins'), "\n")[1:], ' '), '\s\+', ' ', 'g'),
        \\ ], '$work/result.txt')
  qall!
endfunction

autocmd VimEnter * call timer_start(500, 'Step1')
autocmd VimEnter * call timer_start(180000, { t -> execute('qall!') })
EOF

echo "running vim (it compiles the plugin in its own process)..."
cd "$work"
script -qec "$vim_bin -u '$work/vimrc' -i NONE '$work/notes.txt'" /dev/null >/dev/null || true

if [ ! -f "$work/result.txt" ]; then
    echo "FAIL: vim exited without writing a result"
    exit 1
fi

cat "$work/result.txt"
echo

failures=0
check() {
    if grep -q "$1" "$work/result.txt"; then
        echo "  ok   $2"
    else
        echo "  FAIL $2"
        failures=$((failures + 1))
    fi
}

check "status=.*source" "vim compiled the plugin itself and loaded it"
check "built=0" "nothing was built: no compiler ran as a command"
check "saw=.*notes.txt" "plugin evaluated a Vim expression"
check "line1=written by an interpreted plugin" "plugin changed the buffer"
check "asked=1" "plugin answered a question, and had counted the write"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
