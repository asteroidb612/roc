" roc-vim: load plugins written in Roc when Vim starts.
"
" Drop a .roc file in g:roc_plugin_dir (~/.vim/roc by default) and it gets
" built if needed and started as a job when Vim starts.

if exists('g:loaded_roc_vim')
  finish
endif
let g:loaded_roc_vim = 1

if !has('job') || !has('channel')
  echohl WarningMsg
  echomsg 'roc-vim needs a Vim built with +job and +channel (Vim 8 or later)'
  echohl None
  finish
endif

" Line continuations below need Vim's own 'cpoptions'.
let s:save_cpo = &cpo
set cpo&vim

" Where your Roc plugins live: `~/.vim/roc/hello.roc`, or `~/.vim/roc/big/main.roc`.
let g:roc_plugin_dir = get(g:, 'roc_plugin_dir', '~/.vim/roc')
" Where the compiled plugins are kept.
let g:roc_build_dir = get(g:, 'roc_build_dir', '~/.cache/roc-vim')
" The Roc compiler to build with.
let g:roc_command = get(g:, 'roc_command', 'roc')
" Build a plugin when its source is newer than its executable. Turning this off
" means plugins are only built by :RocBuild.
let g:roc_auto_build = get(g:, 'roc_auto_build', 1)
" Start plugins when Vim starts.
let g:roc_auto_start = get(g:, 'roc_auto_start', 1)
" Rebuild and restart a plugin when you save its source.
let g:roc_reload_on_write = get(g:, 'roc_reload_on_write', 1)
" Pass a specific --target to `roc build`, e.g. 'x64glibc'. Empty means the
" default for this machine.
let g:roc_build_target = get(g:, 'roc_build_target', '')
" The engine library holding the Roc compiler. With it, a Vim that has +roc
" runs in-process plugins straight from their source: nothing is built and
" nothing is cached. See roc-vim/embed/.
let g:roc_embed_library = get(g:, 'roc_embed_library', '')
" Use the compiler in the engine library when it is available. Turning this
" off builds in-process plugins into shared libraries instead.
let g:roc_prefer_source = get(g:, 'roc_prefer_source', 1)

command! -bar RocPlugins call roc#status()
command! -bar RocLog call roc#log()
command! -bar -nargs=? -complete=customlist,roc#complete_names RocStart call roc#start(<q-args>)
command! -bar -nargs=? -complete=customlist,roc#complete_names RocStop call roc#stop(<q-args>)
command! -bar -nargs=? -complete=customlist,roc#complete_names RocRestart call roc#restart(<q-args>)
command! -bar -nargs=? -complete=customlist,roc#complete_names RocBuild call roc#build(<q-args>)

augroup roc_vim
  autocmd!
  if g:roc_auto_start
    autocmd VimEnter * call roc#start('')
  endif
  autocmd VimLeavePre * call roc#shutdown()
  if g:roc_reload_on_write
    " Both shapes a plugin can take: one file, or a directory of main.roc plus
    " the modules it imports.
    for s:pattern in ['/*.roc', '/*/*.roc']
      execute 'autocmd BufWritePost ' . expand(g:roc_plugin_dir) . s:pattern
            \ . ' call roc#on_source_written(expand("<afile>:p"))'
    endfor
    unlet! s:pattern
  endif
augroup END

let &cpo = s:save_cpo
unlet s:save_cpo
