#!/usr/bin/env bash
#
# End-to-end test: start a real Vim, let it discover, build and run Roc plugins,
# poke them, and check that what they did reached Vim.
#
# Usage: ./vim_test.sh          (uses `roc` and `vim` from PATH)
#        ROC=/path/to/roc ./vim_test.sh

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
. "$repo/versions.sh"
roc=$(roc_vim_find_roc "$repo")
vim_bin=$(roc_vim_find_vim "$repo")

if [ -z "$roc" ]; then
    echo "no roc compiler found. Build the one roc-vim uses:"
    echo "    $repo/compiler-patch/build-roc.sh"
    echo "or point this run at one: ROC=/path/to/roc $0"
    exit 2
fi
[ -n "$vim_bin" ] || { echo "no vim found"; exit 2; }
"$vim_bin" --version | grep -q '+channel' || { echo "this vim has no +channel"; exit 2; }

work=$(mktemp -d)
# Set ROC_VIM_TEST_KEEP=1 to look at the work directory afterwards.
trap '[ -n "${ROC_VIM_TEST_KEEP:-}" ] && echo "work directory: $work" || rm -rf "$work"' EXIT

mkdir -p "$work/plugins" "$work/build"

# A plugin that reports what it saw, so the test can check it from outside Vim.
cat > "$work/plugins/tester.roc" <<EOF
app [main!] { vim: platform "$repo/platform/main.roc" }

import vim.Vim
import vim.Value

main! : () => Try({}, _)
main! = || {
    Vim.subscribe!(["BufWritePost"])
    # Registered last, so that :RocTest existing means everything above it is
    # in place too.
    Vim.add_command!("RocTest")
    loop!({})
}

loop! : {} => Try({}, _)
loop! = |state|
    match Vim.receive!() {
        Closed => Ok({})
        Notify(event) =>
            if event.name == "command:RocTest" {
                file = Vim.buffer_name!()?
                line_count = Vim.eval_int!("line('\$')")?
                Vim.set_var!("g:roc_test_saw", Value.Text("\${file}:\${I64.to_str(line_count)}"))
                Vim.ex!("let g:roc_test_done = 1")
                loop!(state)
            } else if event.name == "BufWritePost" {
                Vim.ex!("let g:roc_test_writes = get(g:, 'roc_test_writes', 0) + 1")
                loop!(state)
            } else {
                loop!(state)
            }
        _ => loop!(state)
    }
EOF

# The examples get tested too, since they are what people copy from.
for example in uppercase word_count; do
    sed "s|\"../platform/main.roc\"|\"$repo/platform/main.roc\"|" \
        "$repo/examples/$example.roc" > "$work/plugins/$example.roc"
done

cat > "$work/vimrc" <<EOF
set nocompatible
set runtimepath^=$repo/vim
let g:roc_plugin_dir = '$work/plugins'
let g:roc_build_dir = '$work/build'
let g:roc_command = '$roc'

function! s:log_lines() abort
  let lines = []
  for [name, entries] in items(roc#logs())
    for entry in entries
      call add(lines, 'log[' . name . '] ' . entry)
    endfor
  endfor
  return lines
endfunction

let g:roc_waited = 0

" Every plugin has started once all three commands exist.
function! RocTestStep1(timer) abort
  let g:roc_waited += 1
  if !(exists(':RocTest') && exists(':RocUpper') && exists(':RocWords')) && g:roc_waited < 100
    call timer_start(300, 'RocTestStep1')
    return
  endif
  call setline(1, ['hello world', 'second line'])
  write
  RocTest
  %RocUpper
  let g:roc_waited = 0
  call timer_start(300, 'RocTestStep2')
endfunction

" Wait for the plugins to do their work.
function! RocTestStep2(timer) abort
  let g:roc_waited += 1
  let done = exists('g:roc_test_done') && getline(1) ==# 'HELLO WORLD'
  if !done && g:roc_waited < 100
    call timer_start(300, 'RocTestStep2')
    return
  endif
  call writefile([
        \\ 'saw=' . get(g:, 'roc_test_saw', ''),
        \\ 'writes=' . get(g:, 'roc_test_writes', 0),
        \\ 'words=' . get(g:, 'roc_words', 0),
        \\ 'line1=' . getline(1),
        \\ 'line2=' . getline(2),
        \\ 'plugins=' . string(sort(map(roc#sources(), 'roc#name_of(v:val)'))),
        \\ ] + s:log_lines(), '$work/result.txt')
  qall!
endfunction

autocmd VimEnter * call timer_start(500, 'RocTestStep1')
" Never hang: give up after two minutes no matter what.
autocmd VimEnter * call timer_start(120000, { t -> execute('qall!') })
EOF

echo "running vim (it builds three plugins first, so give it a moment)..."
cd "$work"
# Vim wants a terminal; `script` gives it one without showing us the screen.
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

check "plugins=\['tester', 'uppercase', 'word_count'\]" "vim found every plugin source"
check "saw=.*notes.txt:2" "plugin answered a command using what it asked Vim"
check "writes=1" "plugin was told about the write"
check "words=4" "plugin read the whole buffer"
check "line1=HELLO WORLD" "plugin changed the buffer, over a range"
check "line2=SECOND LINE" "plugin changed every line of the range"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
