" roc-vim: run Roc plugins as Vim jobs.
"
" Each plugin is a program. Vim starts one job per plugin with a JSON channel,
" which is how the plugin sends Ex commands and expression requests, and how
" this file sends events back.

" Line continuations below need Vim's own 'cpoptions'.
let s:save_cpo = &cpo
set cpo&vim

let s:plugins = {}
let s:next_id = 1
let s:log_limit = 500
" Logs outlive the job they came from, so a plugin that died still has its last
" words in :RocLog. Keyed by plugin name.
let s:logs = {}
let s:names = {}

" ---------------------------------------------------------------------------
" Finding and building plugins
" ---------------------------------------------------------------------------

" Every Roc plugin source in the plugin directory: `foo.roc`, or `bar/main.roc`.
function! roc#sources() abort
  let dir = expand(g:roc_plugin_dir)
  if !isdirectory(dir)
    return []
  endif
  let sources = glob(dir . '/*.roc', 0, 1) + glob(dir . '/*/main.roc', 0, 1)
  return sort(filter(sources, 'filereadable(v:val) && s:is_app(v:val)'))
endfunction

" A plugin is an `app`. Anything else in the directory - a platform, a module a
" plugin imports - is not something to build and run on its own.
function! s:is_app(path) abort
  for line in readfile(a:path, '', 50)
    let trimmed = substitute(line, '^\s*', '', '')
    if empty(trimmed) || trimmed =~# '^#'
      continue
    endif
    return trimmed =~# '^app\>'
  endfor
  return 0
endfunction

" The name a plugin goes by: its file name, or its directory for `main.roc`.
function! roc#name_of(source) abort
  let name = fnamemodify(a:source, ':t:r')
  if name ==# 'main'
    return fnamemodify(fnamemodify(a:source, ':h'), ':t')
  endif
  return name
endfunction

function! roc#executable_for(source) abort
  return expand(g:roc_build_dir) . '/' . roc#name_of(a:source)
endfunction

function! s:is_stale(source, executable) abort
  if !filereadable(a:executable)
    return 1
  endif
  let built = getftime(a:executable)
  if getftime(a:source) > built
    return 1
  endif
  " A plugin in its own directory can import its own modules.
  for neighbour in glob(fnamemodify(a:source, ':h') . '/*.roc', 0, 1)
    if getftime(neighbour) > built
      return 1
    endif
  endfor
  return 0
endfunction

" Compile one source. Returns the executable's path, or '' if the build failed.
function! roc#build_source(source) abort
  let executable = roc#executable_for(a:source)
  let build_dir = fnamemodify(executable, ':h')
  if !isdirectory(build_dir)
    call mkdir(build_dir, 'p')
  endif

  if !executable(g:roc_command)
    call s:warn('cannot build ' . roc#name_of(a:source) . ': ' . g:roc_command . ' is not on your PATH')
    return ''
  endif

  let command = [g:roc_command, 'build', a:source, '--output=' . executable]
  if !empty(g:roc_build_target)
    call add(command, '--target=' . g:roc_build_target)
  endif

  redraw
  echo 'roc-vim: building ' . roc#name_of(a:source) . '...'
  let output = system(join(map(copy(command), 'shellescape(v:val)'), ' ') . ' 2>&1')
  redraw

  if v:shell_error
    let s:build_output[roc#name_of(a:source)] = output
    call s:warn('could not build ' . roc#name_of(a:source) . ' (:RocLog for details)')
    return ''
  endif

  if has_key(s:build_output, roc#name_of(a:source))
    call remove(s:build_output, roc#name_of(a:source))
  endif
  echo 'roc-vim: built ' . roc#name_of(a:source)
  return executable
endfunction

let s:build_output = {}

" `:RocBuild [source]` - build one plugin, or all of them.
function! roc#build(which) abort
  for source in s:sources_matching(a:which)
    call roc#build_source(source)
  endfor
endfunction

" ---------------------------------------------------------------------------
" Starting and stopping
" ---------------------------------------------------------------------------

function! s:sources_matching(which) abort
  if empty(a:which)
    return roc#sources()
  endif
  if filereadable(a:which)
    return [fnamemodify(a:which, ':p')]
  endif
  return filter(roc#sources(), 'roc#name_of(v:val) ==# a:which')
endfunction

function! roc#start(which) abort
  for source in s:sources_matching(a:which)
    call s:start_source(source)
  endfor
endfunction

function! s:running_id(name) abort
  for [id, plugin] in items(s:plugins)
    if plugin.name ==# a:name && s:is_running(plugin)
      return str2nr(id)
    endif
  endfor
  return 0
endfunction

function! s:is_running(plugin) abort
  return has_key(a:plugin, 'job') && job_status(a:plugin.job) ==# 'run'
endfunction

function! s:start_source(source) abort
  let name = roc#name_of(a:source)
  if s:running_id(name)
    return 0
  endif

  let executable = roc#executable_for(a:source)
  if s:is_stale(a:source, executable)
    if !g:roc_auto_build
      if !filereadable(executable)
        call s:warn(name . ' has not been built; run :RocBuild ' . name)
        return 0
      endif
    else
      let executable = roc#build_source(a:source)
      if empty(executable)
        return 0
      endif
    endif
  endif

  let id = s:next_id
  let s:next_id += 1

  " Each plugin owns an autocommand group, so stopping it takes its
  " subscriptions with it.
  execute 'augroup roc_plugin_' . id
    autocmd!
  augroup END

  let plugin = {
        \ 'id': id,
        \ 'name': name,
        \ 'source': a:source,
        \ 'executable': executable,
        \ 'started': localtime(),
        \ }
  let s:plugins[id] = plugin
  let s:names[id] = name

  let plugin.job = job_start([executable, '--roc-plugin-id', string(id)], {
        \ 'in_mode': 'json',
        \ 'out_mode': 'json',
        \ 'err_mode': 'nl',
        \ 'out_cb': function('s:on_message', [id]),
        \ 'err_cb': function('s:on_stderr', [id]),
        \ 'exit_cb': function('s:on_exit', [id]),
        \ 'stoponexit': 'term',
        \ })

  if job_status(plugin.job) !=# 'run'
    call s:warn('could not start ' . name)
    call remove(s:plugins, id)
    return 0
  endif

  let plugin.channel = job_getchannel(plugin.job)
  return id
endfunction

function! roc#stop(which) abort
  for [id, plugin] in items(s:plugins)
    if empty(a:which) || plugin.name ==# a:which
      call s:stop_plugin(str2nr(id))
    endif
  endfor
endfunction

function! s:stop_plugin(id) abort
  let plugin = get(s:plugins, a:id, {})
  if empty(plugin)
    return
  endif
  execute 'augroup roc_plugin_' . a:id
    autocmd!
  augroup END
  execute 'silent! augroup! roc_plugin_' . a:id
  if has_key(plugin, 'channel') && ch_status(plugin.channel) ==# 'open'
    " Closing the channel is the plugin's cue to shut down on its own.
    call ch_close(plugin.channel)
  endif
  if s:is_running(plugin)
    call job_stop(plugin.job)
  endif
  for command in keys(get(plugin, 'commands', {}))
    execute 'silent! delcommand ' . command
  endfor
  if has_key(s:plugins, a:id)
    call remove(s:plugins, a:id)
  endif
endfunction

function! roc#restart(which) abort
  call roc#stop(a:which)
  " Give the job a moment to let go of the channel before starting it again.
  sleep 50m
  call roc#start(a:which)
endfunction

function! roc#shutdown() abort
  for id in keys(s:plugins)
    call s:stop_plugin(str2nr(id))
  endfor
endfunction

" Rebuild and restart a plugin whose source was just saved.
function! roc#on_source_written(path) abort
  let name = roc#name_of(a:path)
  if empty(filter(roc#sources(), 'roc#name_of(v:val) ==# name'))
    return
  endif
  call roc#restart(name)
endfunction

" ---------------------------------------------------------------------------
" Talking to a running plugin
" ---------------------------------------------------------------------------

" Send an event. Does not wait for the plugin to deal with it.
function! roc#notify(id, name, data) abort
  let plugin = get(s:plugins, a:id, {})
  if empty(plugin) || !has_key(plugin, 'channel') || ch_status(plugin.channel) !=# 'open'
    return
  endif
  call ch_sendexpr(plugin.channel, {'event': a:name, 'data': a:data})
endfunction

" Send an event and wait for the plugin's answer. Returns the answer, or
" `a:default` if the plugin did not answer in time.
function! roc#request(id, name, data, ...) abort
  let timeout = a:0 > 0 ? a:1 : 2000
  let default = a:0 > 1 ? a:2 : ''
  let plugin = get(s:plugins, a:id, {})
  if empty(plugin) || !has_key(plugin, 'channel') || ch_status(plugin.channel) !=# 'open'
    return default
  endif
  let answer = ch_evalexpr(
        \ plugin.channel,
        \ {'event': a:name, 'data': a:data, 'reply': 1},
        \ {'timeout': timeout})
  return answer is# '' ? default : answer
endfunction

" The same, by plugin name rather than id, for use from your own Vimscript.
function! roc#send(name, event, data) abort
  let id = s:running_id(a:name)
  if id
    call roc#notify(id, a:event, a:data)
  endif
endfunction

function! roc#ask(name, event, data, ...) abort
  let id = s:running_id(a:name)
  if !id
    return a:0 > 1 ? a:2 : ''
  endif
  return call('roc#request', [id, a:event, a:data] + a:000)
endfunction

" What a plugin is told about whatever just happened.
function! roc#context() abort
  return {
        \ 'buffer': bufnr('%'),
        \ 'file': expand('%:p'),
        \ 'afile': expand('<afile>:p'),
        \ 'filetype': &filetype,
        \ 'line': line('.'),
        \ 'column': col('.'),
        \ 'mode': mode(),
        \ }
endfunction

" ---------------------------------------------------------------------------
" What plugins ask Vim to do for them
" ---------------------------------------------------------------------------

" Vim.subscribe! - one autocommand per event, in the plugin's own group.
function! roc#subscribe(id, events) abort
  let id = str2nr(a:id)
  for spec in a:events
    let parts = split(spec, ' ')
    if empty(parts)
      continue
    endif
    let event = parts[0]
    let pattern = len(parts) > 1 ? join(parts[1:], ' ') : '*'
    if !exists('##' . event)
      call s:warn('plugin ' . s:name_of_id(id) . ' asked for unknown event ' . event)
      continue
    endif
    execute printf('autocmd roc_plugin_%d %s %s call roc#notify(%d, %s, roc#context())',
          \ id, event, pattern, id, string(event))
  endfor
  return len(a:events)
endfunction

" Vim.add_command! - `:Name` sends the plugin a "command:Name" event.
function! roc#add_command(id, name) abort
  let id = str2nr(a:id)
  if a:name !~# '^[A-Z]'
    call s:warn('command ' . a:name . ' must start with an uppercase letter')
    return 0
  endif
  execute printf(
        \ 'command! -nargs=* -range %s call roc#notify(%d, %s, ' .
        \ 'extend(roc#context(), {"args": <q-args>, "line1": <line1>, "line2": <line2>}))',
        \ a:name, id, string('command:' . a:name))
  let plugin = get(s:plugins, id, {})
  if !empty(plugin)
    let plugin.commands = get(plugin, 'commands', {})
    let plugin.commands[a:name] = 1
  endif
  return 1
endfunction

" Vim.add_mapping! - a key sends the plugin a "mapping:<lhs>" event.
function! roc#add_mapping(id, mode, lhs) abort
  let id = str2nr(a:id)
  let call = printf('call roc#notify(%d, %s, roc#context())', id, string('mapping:' . a:lhs))
  if a:mode ==# 'i'
    execute printf('inoremap <silent> %s <C-o>:%s<CR>', a:lhs, call)
  else
    execute printf('%snoremap <silent> %s :<C-u>%s<CR>', a:mode, a:lhs, call)
  endif
  return 1
endfunction

" Vim.set_lines! - replace the buffer, keeping the view where it was.
function! roc#set_lines(lines) abort
  let view = winsaveview()
  silent! %delete _
  call setline(1, a:lines)
  call winrestview(view)
  return len(a:lines)
endfunction

" Vim.set_var!
function! roc#set_var(name, value) abort
  execute 'let ' . a:name . ' = a:value'
  return 1
endfunction

" ---------------------------------------------------------------------------
" Channel callbacks
" ---------------------------------------------------------------------------

function! s:on_message(id, channel, message) abort
  " Ex commands and expression requests are handled by Vim itself; anything
  " else a plugin sends lands here.
  call s:record(a:id, 'message: ' . string(a:message))
endfunction

function! s:on_stderr(id, channel, line) abort
  call s:record(a:id, a:line)
endfunction

function! s:on_exit(id, job, status) abort
  call s:record(a:id, 'exited with status ' . a:status)
  let name = s:name_of_id(a:id)
  if has_key(s:plugins, a:id)
    call remove(s:plugins, a:id)
  endif
  if a:status != 0
    call s:warn(name . ' exited with status ' . a:status . ' (:RocLog for details)')
  endif
endfunction

function! s:record(id, line) abort
  let name = s:name_of_id(a:id)
  let log = get(s:logs, name, [])
  call add(log, strftime('%H:%M:%S') . ' ' . a:line)
  if len(log) > s:log_limit
    call remove(log, 0, len(log) - s:log_limit - 1)
  endif
  let s:logs[name] = log
endfunction

function! s:name_of_id(id) abort
  return get(s:names, a:id, '#' . a:id)
endfunction

function! s:warn(message) abort
  echohl WarningMsg
  echomsg 'roc-vim: ' . a:message
  echohl None
endfunction

" ---------------------------------------------------------------------------
" User-facing commands
" ---------------------------------------------------------------------------

function! roc#status() abort
  let sources = roc#sources()
  if empty(sources) && empty(s:plugins)
    echo 'roc-vim: no plugins in ' . expand(g:roc_plugin_dir)
    return
  endif

  echo printf('%-20s %-9s %-7s %s', 'PLUGIN', 'STATUS', 'PID', 'SOURCE')
  let seen = {}
  for [id, plugin] in items(s:plugins)
    let seen[plugin.name] = 1
    let info = job_info(plugin.job)
    echo printf('%-20s %-9s %-7s %s',
          \ plugin.name,
          \ job_status(plugin.job),
          \ string(get(info, 'process', '-')),
          \ fnamemodify(plugin.source, ':~'))
  endfor
  for source in sources
    let name = roc#name_of(source)
    if !has_key(seen, name)
      echo printf('%-20s %-9s %-7s %s', name, 'stopped', '-', fnamemodify(source, ':~'))
    endif
  endfor
endfunction

" What each plugin has written to its log, by name. A plugin that has exited
" keeps its log until something with the same name starts and writes more.
function! roc#logs() abort
  return deepcopy(s:logs)
endfunction

function! roc#log() abort
  let lines = []
  for [name, entries] in items(s:logs)
    call add(lines, '=== ' . name)
    call extend(lines, empty(entries) ? ['  (nothing logged)'] : entries)
    call add(lines, '')
  endfor
  for [name, output] in items(s:build_output)
    call add(lines, '=== ' . name . ' (build failed)')
    call extend(lines, split(output, "\n"))
    call add(lines, '')
  endfor
  if empty(lines)
    echo 'roc-vim: nothing logged yet'
    return
  endif

  let existing = bufnr('roc-vim log')
  if existing != -1 && bufwinnr(existing) != -1
    execute bufwinnr(existing) . 'wincmd w'
  else
    new
    silent file roc-vim\ log
  endif
  setlocal buftype=nofile bufhidden=hide noswapfile modifiable
  silent! %delete _
  call setline(1, lines)
  setlocal nomodifiable
endfunction

function! roc#complete_names(arglead, cmdline, cursorpos) abort
  let names = map(roc#sources(), 'roc#name_of(v:val)')
  return filter(names, 'v:val =~# "^" . a:arglead')
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
