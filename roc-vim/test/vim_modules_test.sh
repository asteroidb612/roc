#!/usr/bin/env bash
#
# A plugin can be one .roc file, or a directory of main.roc plus the modules it
# imports. This checks the second shape end to end: Vim finds it, builds it,
# runs it, the module's own effects reach Vim, and saving a *module* rebuilds
# and restarts the plugin — the same edit-run loop a single file gets.
#
# Needs a Vim with +roc (vim-patch/) and the engine library (embed/). It skips
# rather than fails when either is missing.

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
mkdir -p "$work/plugins/tester"

# The module: a pure function and an effectful one, both used by main.roc.
cat > "$work/plugins/tester/Report.roc" <<ROC
module [describe, announce!]

import vim.Vim
import vim.Value

describe : I64 -> Str
describe = |count| "count is \${I64.to_str(count)}"

announce! : Str => Try({}, [VimErr(Str), ..])
announce! = |text| {
    file = Vim.buffer_name!()?
    Vim.set_var!("g:module_said", Value.Text("\${text} in \${file}"))
    Ok({})
}
ROC

# ...and the app beside it.
cat > "$work/plugins/tester/main.roc" <<ROC
app [Model, plugin] { vim: platform "$repo/platform-inprocess/main.roc" }

import vim.Vim
import Report

Model : I64

plugin = { init!, handle! }

init! : () => Try(Model, _)
init! = || {
    Vim.add_command!("RocModuleTest")
    Ok(0)
}

handle! : Model, Vim.Event => Try(Model, _)
handle! = |count, event|
    if event.name == "command:RocModuleTest" {
        next = count + 1
        Report.announce!(Report.describe(next))?
        Ok(next)
    } else {
        Ok(count)
    }
ROC

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
set shortmess+=atT
set nomore
let g:waited = 0
let g:seen = []

function! Step1(timer) abort
  let g:waited += 1
  if !exists(':RocModuleTest') && g:waited < 200
    call timer_start(300, 'Step1')
    return
  endif
  edit notes.txt
  silent! RocModuleTest
  call add(g:seen, 'first=' . get(g:, 'module_said', ''))

  " Now change only the MODULE, and save it. The plugin should rebuild.
  let module = g:work . '/plugins/tester/Report.roc'
  call writefile(map(readfile(module),
        \ 'substitute(v:val, ''"count is '', ''"changed count is '', "")'), module)
  execute 'split' module
  write
  quit
  let g:waited = 0
  call timer_start(500, 'Step2')
endfunction

function! Step2(timer) abort
  let g:waited += 1
  silent! RocModuleTest
  " The restarted plugin counts from zero again, so wait for the new text.
  if get(g:, 'module_said', '') !~# 'changed' && g:waited < 60
    call timer_start(500, 'Step2')
    return
  endif
  call add(g:seen, 'second=' . get(g:, 'module_said', ''))
  call add(g:seen, 'status=' . substitute(join(split(execute('RocPlugins'), "\n")[1:], ' '), '\s\+', ' ', 'g'))
  call add(g:seen, 'built=' . (isdirectory(g:work . '/build')
        \ ? len(glob(g:work . '/build/*', 0, 1)) : 0))
  call writefile(g:seen, g:work . '/result.txt')
  qall!
endfunction

autocmd VimEnter * call timer_start(300, 'Step1')
autocmd VimEnter * call timer_start(180000, { t -> execute('qall!') })
VIM

echo "running vim (a plugin made of main.roc plus a module)..."
cd "$work"
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

check "^status=tester"                  "vim found the directory as one plugin named for it"
check "^built=0$"                       "nothing was built: it was compiled in-process"
check "^first=count is 1 in notes.txt$" "the module's pure and effectful halves both ran"
check "^second=changed count is 1"      "saving the module rebuilt and restarted the plugin"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
