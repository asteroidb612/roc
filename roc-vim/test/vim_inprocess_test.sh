#!/usr/bin/env bash
#
# End-to-end test for in-process plugins: a Roc plugin loaded into Vim's own
# process with roc_load(), running its effects as direct calls.
#
# Needs a Vim built with +roc (see vim-patch/) and a Roc that can build shared
# libraries (see compiler-patch/). It skips rather than fails when either is
# missing, so it is safe to run anywhere.
#
# Usage: VIM=/path/to/patched/vim ROC=/path/to/roc ./vim_inprocess_test.sh

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
roc=${ROC:-roc}
vim_bin=${VIM:-vim}

command -v "$roc" >/dev/null || { echo "SKIP: no roc compiler (set ROC=...)"; exit 0; }
command -v "$vim_bin" >/dev/null || { echo "SKIP: no vim (set VIM=...)"; exit 0; }
if ! "$vim_bin" --version | tr ' ' '\n' | grep -qx '+roc'; then
    echo "SKIP: this vim has no +roc; build one with vim-patch/build-vim.sh"
    exit 0
fi

work=$(mktemp -d)
trap '[ -n "${ROC_VIM_TEST_KEEP:-}" ] && echo "work directory: $work" || rm -rf "$work"' EXIT
mkdir -p "$work/plugins" "$work/build"

# A plugin that answers a command, counts writes, and answers a question from
# Vimscript - all inside Vim's process.
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
        last_line = Vim.eval_int!("line('\$')")?
        Vim.set_var!("g:roc_test_saw", Value.Text("\${file}:\${I64.to_str(last_line)}"))
        # Changing the buffer from inside Vim is a direct call, not a message.
        Vim.set_line!(1, "changed by roc")
        Vim.ex!("let g:roc_test_done = 1")
        Ok(writes)
    } else if event.name == "BufWritePost" {
        Ok(writes + 1)
    } else if event.name == "writes" {
        # Whoever called roc#ask() is waiting for this.
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
let g:roc_command = '$roc'

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
        \\ 'status=' . substitute(join(split(execute('RocPlugins'), "\n")[1:], ' '), '\s\+', ' ', 'g'),
        \\ ], '$work/result.txt')
  qall!
endfunction

autocmd VimEnter * call timer_start(500, 'Step1')
autocmd VimEnter * call timer_start(180000, { t -> execute('qall!') })
EOF

echo "running vim (it builds the plugin as a shared library first)..."
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

check "status=.*in-process" "vim loaded the plugin into its own process"
check "saw=.*notes.txt:2" "plugin evaluated Vim expressions and set a variable"
check "line1=changed by roc" "plugin changed the buffer directly"
check "asked=1" "plugin answered a question, and had counted the write"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
