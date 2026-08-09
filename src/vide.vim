" vide: a small project explorer hosted inside unmodified Vim.
if exists('g:loaded_vide_runtime')
  finish
endif
let g:loaded_vide_runtime = 1

let s:module_dir = expand('<sfile>:p:h') . '/vide'
for s:module in ['core.vim', 'tree.vim', 'watch.vim', 'fs.vim', 'settings.vim', 'ui.vim', 'ignore.vim']
  execute 'silent source ' . fnameescape(s:module_dir . '/' . s:module)
endfor

set nocompatible
set mouse=a
filetype plugin indent on
syntax enable

let s:root = substitute(resolve(fnamemodify(getcwd(), ':p')), '/\+$', '', '')
let s:tree_buf = -1
let s:tree_win = -1
let s:editor_win = -1
let s:watching = 0
let s:expanded = {s:root: 1}
let s:watch = {'baseline': {}, 'signatures': {}, 'hashes': {}, 'contents': {}, 'snapshot_sizes': {}, 'diffs': {}}
let s:content_limit = 262144
let s:snapshot_budget = 8388608
let s:snapshot_bytes = 0
let s:snapshot_order = []
let s:changed_path = ''
let s:changed_line = 1
let s:selected_path = ''
let s:watch_job = 0
let s:watcher_stopping = 0
let s:watch_error = 0
let s:stopped_watch_jobs = {}
let s:watch_buffer = ''
let s:pending_events = []
" Performance: renders are deferred to the end of an event batch so a burst of
" writes triggers one tree refresh, not one per event.  s:watch_queue buffers
" channel chunks so re-entrant callbacks never drop events.
let s:render_dirty = 0
let s:structural_change = 0
let s:watch_queue = []
let s:batch_last_path = ''
let s:batch_last_line = 1
let s:has_open_candidate = 0
let s:last_message = ''
let s:initializing = 0
" Populated by the one startup walk so rendering does not repeat readdir/stat.
let s:children_cache = {}
let s:node_types = {}
let s:baseline_timer = -1
let s:baseline_state = {}
let s:workspace_ready = 0
let s:event_timer = -1
let s:exe_suffix = has('win32') ? '.exe' : ''
let s:watcher_path = get(g:, 'vide_watcher', expand('<sfile>:p:h:h') . '/bin/vide-watch' . s:exe_suffix)
let s:fs_path = get(g:, 'vide_fs', expand('<sfile>:p:h:h') . '/bin/vide-fs' . s:exe_suffix)
let s:notice = ''
let s:ignore_patterns = ['^\.git\%(/\|$\)', '^node_modules\%(/\|$\)', '^__pycache__\%(/\|$\)']
let g:vide_ignore_patterns = []

" Enhanced conflict handling and change tracking
let s:conflicts = {}
let s:recent_changes = {}
" Per-path change frequency, keyed by path: {'first': time, 'count': n, 'kinds': []}
let s:change_stats = {}
" Chronological change log, newest last, capped at s:change_log_limit entries
let s:change_log = []
let s:change_log_limit = 50
let s:priority_paths = []
let s:snapshot_priorities = {}
let s:recent_timer = -1
let g:vide_last_change = ''

let g:vide_notice = ''
let s:interrupt_armed = 0
let s:interrupt_timer = -1
let s:interrupt_popup = -1
let s:settings_popup = -1

" Settings with defaults.  Keep this as the single declaration: a second
" 'let s:settings = {...}' would silently discard values loaded before it.
let s:settings = {
      \ 'sidebar_percent': 34,
      \ 'content_limit_kb': 256,
      \ 'snapshot_budget_kb': 8192,
      \ 'marker_style': 'auto',
      \ 'watch_mode': 'aggressive',
      \ 'auto_reload': 1,
      \ 'conflict_strategy': 'ask',
      \ 'verbose_changes': 1,
      \ 'auto_jump': 1,
      \ 'snapshot_mode': 'content'}

" Allowed values and numeric ranges, used by both the loader and the settings
" menu so a hand-edited settings file cannot push VIDE into a broken state.
let s:setting_choices = {
      \ 'watch_mode': ['aggressive', 'normal', 'minimal'],
      \ 'conflict_strategy': ['ask', 'use', 'reload'],
      \ 'marker_style': ['auto', 'unicode', 'ascii'],
      \ 'snapshot_mode': ['content', 'stat']}
let s:setting_ranges = {
      \ 'sidebar_percent': [20, 60],
      \ 'content_limit_kb': [64, 4096],
      \ 'snapshot_budget_kb': [1024, 65536]}

function! s:ValidateSettings() abort
  for [l:key, l:allowed] in items(s:setting_choices)
    if index(l:allowed, get(s:settings, l:key, '')) < 0
      let s:settings[l:key] = l:allowed[0]
    endif
  endfor
  for [l:key, l:bounds] in items(s:setting_ranges)
    let l:value = get(s:settings, l:key, l:bounds[0])
    if type(l:value) != v:t_number
      let l:value = str2nr(l:value)
    endif
    let s:settings[l:key] = min([l:bounds[1], max([l:bounds[0], l:value])])
  endfor
  for l:key in ['auto_reload', 'verbose_changes']
    let s:settings[l:key] = empty(get(s:settings, l:key, 1)) ? 0 : 1
  endfor
  " Keep the snapshot limits in sync with the values actually used at runtime.
  let s:content_limit = s:settings.content_limit_kb * 1024
  let s:snapshot_budget = s:settings.snapshot_budget_kb * 1024
endfunction

call s:ValidateSettings()
let g:vide_watch_backend = 'OFF'

highlight default VideChanged cterm=bold ctermfg=Black ctermbg=DarkYellow gui=bold guifg=Black guibg=DarkYellow
highlight default VideConflict cterm=bold ctermfg=Black ctermbg=Red gui=bold guifg=Black guibg=Red
highlight default VideRecentChange cterm=bold ctermfg=Yellow gui=bold guifg=Yellow
highlight default VideTreeRoot cterm=bold ctermfg=Cyan gui=bold guifg=Cyan
highlight default VideTreeDirectory cterm=bold ctermfg=LightCyan gui=bold guifg=LightCyan
highlight default VideTreeMarker cterm=bold ctermfg=Yellow gui=bold guifg=Yellow
highlight default VideStatus cterm=bold ctermfg=Black ctermbg=DarkCyan gui=bold guifg=Black guibg=DarkCyan
highlight default VideStatusMeta cterm=NONE ctermfg=LightCyan ctermbg=Black gui=NONE guifg=LightCyan guibg=Black
highlight default VideExplorerNormal cterm=NONE ctermfg=LightGray ctermbg=Black gui=NONE guifg=LightGray guibg=Black
highlight default VideExplorerCursor cterm=bold ctermfg=Black ctermbg=DarkCyan gui=bold guifg=Black guibg=DarkCyan
highlight default VideSplash cterm=bold ctermfg=Cyan ctermbg=Black gui=bold guifg=Cyan guibg=Black
highlight default VideSplashText ctermfg=LightGray ctermbg=Black guifg=LightGray guibg=Black
highlight default VideDivider cterm=NONE ctermfg=DarkCyan ctermbg=Black gui=NONE guifg=DarkCyan guibg=Black
highlight default VideStatusLine cterm=bold ctermfg=Black ctermbg=DarkCyan gui=bold guifg=Black guibg=DarkCyan
highlight default VideStatusLineNC cterm=NONE ctermfg=DarkGray ctermbg=Black gui=NONE guifg=DarkGray guibg=Black
highlight default VideInterruptWarning cterm=bold ctermfg=Black ctermbg=DarkYellow gui=bold guifg=Black guibg=DarkYellow
highlight default VideInterruptBorder cterm=bold ctermfg=DarkCyan ctermbg=Black gui=bold guifg=DarkCyan guibg=Black
highlight PmenuSel cterm=bold ctermfg=Black ctermbg=DarkCyan gui=bold guifg=Black guibg=DarkCyan

function! s:IsTreeBuffer() abort
  return bufnr('%') == s:tree_buf
endfunction

function! s:ClearInterruptWarning(timer) abort
  let s:interrupt_armed = 0
  let s:interrupt_timer = -1
  if s:interrupt_popup > 0
    silent! call popup_close(s:interrupt_popup)
  endif
  let s:interrupt_popup = -1
endfunction

function! s:Interrupt() abort
  if s:interrupt_armed
    if s:interrupt_timer > 0
      call timer_stop(s:interrupt_timer)
    endif
    call s:ClearInterruptWarning(-1)
    qa!
    return
  endif

  let s:interrupt_armed = 1
  if &columns < 54 || &lines < 8
    echohl WarningMsg
    echomsg 'VIDE: press Ctrl-C again within 3 seconds to force quit'
    echohl None
  else
    try
      let s:interrupt_popup = popup_create(
          \ ['Force quit?', 'Press Ctrl-C again within 3 seconds.'],
          \ {'pos': 'center', 'minwidth': 44, 'padding': [1, 2, 1, 2],
          \  'border': [1, 1, 1, 1],
          \  'highlight': 'VideInterruptWarning',
          \  'borderhighlight': ['VideInterruptBorder'], 'zindex': 300})
    catch /^Vim\%((\a\+)\)\=:E/
      echohl WarningMsg
      echomsg 'VIDE: press Ctrl-C again within 3 seconds to force quit'
      echohl None
    endtry
  endif
  let s:interrupt_timer = timer_start(3000, function('s:ClearInterruptWarning'))
endfunction

function! s:IsDirectory(path) abort
  if has_key(s:node_types, a:path)
    return s:node_types[a:path]
  endif
  let l:result = isdirectory(a:path) && getftype(a:path) !=# 'link'
  let s:node_types[a:path] = l:result
  return l:result
endfunction

function! s:InvalidateTreeCache() abort
  let s:children_cache = {}
  let s:node_types = {}
endfunction

function! s:NormalizePath(path) abort
  return substitute(fnamemodify(a:path, ':p'), '/\+$', '', '')
endfunction

function! s:DisplayName(path) abort
  return substitute(fnamemodify(a:path, ':t'), '[[:cntrl:]]', '?', 'g')
endfunction

function! s:TreeMarker(path) abort
  let l:style = get(s:settings, 'marker_style', 'auto')
  let l:locale = tolower($LC_ALL . ' ' . $LC_CTYPE . ' ' . $LANG . ' ' . &termencoding)
  let l:unicode = l:style ==# 'unicode' ||
        \ (l:style ==# 'auto' && has('multi_byte') &&
        \ l:locale =~# 'utf[-_]\?8')
  if l:unicode
    return has_key(s:expanded, a:path) ? '▼' : '▶'
  endif
  return has_key(s:expanded, a:path) ? 'v' : '>'
endfunction

function! s:FitTreeLabel(text, width) abort
  if a:width <= 0
    return ''
  endif
  if strdisplaywidth(a:text) <= a:width
    return a:text
  endif
  if a:width <= 3
    let l:short = ''
    for l:index in range(0, strchars(a:text) - 1)
      let l:char = strcharpart(a:text, l:index, 1)
      if strdisplaywidth(l:short . l:char) > a:width
        break
      endif
      let l:short .= l:char
    endfor
    return l:short
  endif
  let l:limit = max([1, a:width - 3])
  let l:result = ''
  for l:index in range(0, strchars(a:text) - 1)
    let l:char = strcharpart(a:text, l:index, 1)
    if strdisplaywidth(l:result . l:char) > l:limit
      break
    endif
    let l:result .= l:char
  endfor
  return l:result . '...'
endfunction

function! s:SettingsFile() abort
  if exists('*stdpath')
    return stdpath('config') . '/vide/settings.vim'
  endif
  return expand('~/.config/vide/settings.vim')
endfunction

function! s:ValidateSettings() abort
  let s:settings.sidebar_percent = min([60, max([20, str2nr(string(get(s:settings, 'sidebar_percent', 34)))])])
  let s:settings.content_limit_kb = min([4096, max([64, str2nr(string(get(s:settings, 'content_limit_kb', 256)))])])
  let s:settings.snapshot_budget_kb = min([65536, max([1024, str2nr(string(get(s:settings, 'snapshot_budget_kb', 8192)))])])
  if index(['auto', 'unicode', 'ascii'], get(s:settings, 'marker_style', 'auto')) < 0
    let s:settings.marker_style = 'auto'
  endif
  if index(['aggressive', 'normal', 'minimal'], get(s:settings, 'watch_mode', 'aggressive')) < 0
    let s:settings.watch_mode = 'aggressive'
  endif
  if index(['ask', 'keep-local', 'keep-external'], get(s:settings, 'conflict_strategy', 'ask')) < 0
    let s:settings.conflict_strategy = 'ask'
  endif
  if index(['content', 'stat'], get(s:settings, 'snapshot_mode', 'content')) < 0
    let s:settings.snapshot_mode = 'content'
  endif
  let s:settings.auto_reload = get(s:settings, 'auto_reload', 1) ? 1 : 0
  let s:settings.verbose_changes = get(s:settings, 'verbose_changes', 1) ? 1 : 0
  let s:settings.auto_jump = get(s:settings, 'auto_jump', 1) ? 1 : 0
  let s:content_limit = s:settings.content_limit_kb * 1024
  let s:snapshot_budget = s:settings.snapshot_budget_kb * 1024
  let g:vide_settings = deepcopy(s:settings)
endfunction

function! s:LoadSettings() abort
  let l:provided = deepcopy(get(g:, 'vide_settings', {}))
  let l:file = s:SettingsFile()
  if filereadable(l:file)
    try
      execute 'silent source ' . fnameescape(l:file)
    catch /^Vim\%((\a\+)\)\=:E/
      " A damaged optional settings file must not stop VIDE from starting.
    endtry
  endif
  let s:settings = extend(s:settings, deepcopy(get(g:, 'vide_settings', {})), 'force')
  let s:settings = extend(s:settings, l:provided, 'force')
  call s:ValidateSettings()
endfunction

function! s:SaveSettings() abort
  let l:file = s:SettingsFile()
  try
    call mkdir(fnamemodify(l:file, ':h'), 'p')
    call writefile(['let g:vide_settings = ' . string(s:settings)], l:file)
  catch /^Vim\%((\a\+)\)\=:E/
    " The selected values remain active for this session when persistence is
    " unavailable (for example, in a restricted runtime).
  endtry
endfunction

function! s:IsTransient(path) abort
  let l:name = fnamemodify(a:path, ':t')
  " Ignore files Vim itself creates while editing.  The repeated suffix also
  " prevents a damaged session from recursively opening swap files.
  return l:name ==# '4913' || l:name =~# '\.sw[a-z]\%(\.sw[a-z]\)*$'
endfunction

function! s:IsWithinRoot(path) abort
  let l:path = s:NormalizePath(a:path)
  return l:path ==# s:root || stridx(l:path, s:root . '/') ==# 0
endfunction

function! s:HasSymlinkComponent(path) abort
  let l:path = s:NormalizePath(a:path)
  if !s:IsWithinRoot(l:path)
    return 1
  endif
  let l:relative = strpart(l:path, strlen(s:root))
  let l:current = s:root
  for l:part in split(l:relative, '/', 1)
    if empty(l:part)
      continue
    endif
    let l:current .= '/' . l:part
    if getftype(l:current) ==# 'link'
      return 1
    endif
  endfor
  return 0
endfunction

function! s:TreeMessage(message) abort
  let s:notice = a:message
  let g:vide_notice = s:notice
  redrawstatus
endfunction

function! s:TreeError(message) abort
  let s:notice = 'ERROR: ' . a:message
  let g:vide_notice = s:notice
  redrawstatus
endfunction

function! s:GetConflictTempPath(path) abort
  let l:hash = sha256(a:path)[:8]
  if exists('*stdpath')
    let l:cache_dir = stdpath('cache') . '/vide/conflicts'
  else
    let l:cache_dir = expand('~/.cache/vide/conflicts')
  endif
  return l:cache_dir . '/' . l:hash . '_' . fnamemodify(a:path, ':t')
endfunction

function! s:SaveExternalVersion(path) abort
  let l:temp_path = s:GetConflictTempPath(a:path)
  try
    call mkdir(fnamemodify(l:temp_path, ':h'), 'p')
    call writefile(readfile(a:path, 'b'), l:temp_path, 'b')
  catch /^Vim\%((\a\+)\)\=:E/
    " If we cannot save the temp file, log but continue
  endtry
endfunction

function! s:CompareConflict() abort
  let l:path = expand('%:p')
  if !has_key(s:conflicts, l:path)
    echomsg 'No conflict for this file'
    return
  endif
  let l:temp_path = s:GetConflictTempPath(l:path)
  if !filereadable(l:temp_path)
    echomsg 'External version not available'
    return
  endif
  " Use vertical split to compare
  execute 'vertical diffsplit ' . fnameescape(l:temp_path)
  setlocal readonly
  setlocal buftype=nofile
  setlocal bufhidden=wipe
  execute 'file [External] ' . fnamemodify(l:path, ':t')
  wincmd p
endfunction

function! s:TrackRecentChange(path, kind) abort
  " Track for recent change highlighting
  let s:recent_changes[a:path] = localtime()

  " Track per-path frequency for priority calculation
  let l:now = localtime()
  if !has_key(s:change_stats, a:path)
    let s:change_stats[a:path] = {'first': l:now, 'count': 0, 'kinds': []}
  elseif l:now - s:change_stats[a:path].first >= 60
    " Restart the window so old bursts don't keep a path prioritised forever
    let s:change_stats[a:path] = {'first': l:now, 'count': 0, 'kinds': []}
  endif
  let s:change_stats[a:path].count += 1
  call add(s:change_stats[a:path].kinds, a:kind)
  if len(s:change_stats[a:path].kinds) > 10
    call remove(s:change_stats[a:path].kinds, 0)
  endif

  " Append to the chronological change log
  let l:display_path = fnamemodify(a:path, ':~:.')
  let l:message = printf('[%s] %s', a:kind, l:display_path)
  call add(s:change_log, {
        \ 'time': l:now,
        \ 'path': a:path,
        \ 'kind': a:kind,
        \ 'message': l:message
        \ })

  if len(s:change_log) > s:change_log_limit
    call remove(s:change_log, 0, len(s:change_log) - s:change_log_limit - 1)
  endif

  let g:vide_last_change = l:message
  " The message is surfaced once per event batch by s:FlushChangedEvents, so a
  " burst of writes does not flood the message area with echomsgs.
  let s:last_message = l:message

  " One shared expiry timer, not one per event: a busy agent can emit hundreds
  " of writes per second, and a timer each would pile up unbounded.
  call s:ScheduleRecentExpiry()
endfunction

function! s:ScheduleRecentExpiry() abort
  if s:recent_timer >= 0 || !exists('*timer_start')
    return
  endif
  let s:recent_timer = timer_start(1000, function('<SID>ExpireRecentChanges'))
endfunction

function! s:ExpireRecentChanges(timer) abort
  let s:recent_timer = -1
  let l:now = localtime()
  let l:expired = 0
  for [l:path, l:stamp] in items(s:recent_changes)
    if l:now - l:stamp >= 5
      call remove(s:recent_changes, l:path)
      let l:expired = 1
    endif
  endfor
  if l:expired
    call s:Render()
  endif
  " Keep polling only while something is still pending.
  if !empty(s:recent_changes)
    call s:ScheduleRecentExpiry()
  endif
endfunction

function! s:UpdatePriorityPaths() abort
  " Detect frequently modified files (3+ changes in 60 seconds)
  let l:now = localtime()
  let s:priority_paths = []

  for [l:path, l:info] in items(s:change_stats)
    if l:now - l:info.first < 60 && l:info.count >= 3
      call add(s:priority_paths, l:path)
    endif
  endfor
endfunction

function! s:ShowChangeHistory() abort
  let l:lines = ['Recent file changes:', '']
  for l:notif in reverse(copy(s:change_log))
    let l:time_str = strftime('%H:%M:%S', l:notif.time)
    call add(l:lines, printf('%s  %s', l:time_str, l:notif.message))
  endfor

  if len(l:lines) <= 2
    call add(l:lines, 'No recent changes')
  endif

  " Reuse the history window when it is already open, otherwise repeated
  " presses stack a new split each time.
  let l:name = '[VIDE] Change History'
  let l:existing = bufnr(l:name)
  let l:winnr = l:existing > 0 ? bufwinnr(l:existing) : -1
  if l:winnr > 0
    execute l:winnr . 'wincmd w'
  else
    rightbelow new
    setlocal buftype=nofile bufhidden=hide noswapfile nowrap nonumber
    silent! execute 'file ' . fnameescape(l:name)
    resize 15
  endif

  setlocal modifiable
  silent %delete _
  call setline(1, l:lines)
  setlocal nomodifiable
  call cursor(1, 1)
  nnoremap <silent><buffer> q :<C-U>close<CR>
endfunction

function! s:ForceRefreshAll() abort
  call s:TreeMessage('Refreshing all files...')
  let l:count = 0
  for l:path in keys(s:watch.contents)
    if !filereadable(l:path)
      continue
    endif
    let l:snapshot = s:ReadSnapshot(l:path)
    let l:old_hash = get(s:watch.hashes, l:path, '')
    if l:snapshot.hash !=# l:old_hash && !empty(l:snapshot.hash)
      call s:HandleChangedPath(l:path, 'WRITE')
      let l:count += 1
    endif
  endfor
  call s:TreeMessage(printf('Refreshed: %d file(s) changed', l:count))
endfunction

function! s:PruneWatch(path) abort
  let l:path = s:NormalizePath(a:path)
  if !has_key(s:watch, 'snapshot_sizes')
    let s:watch.snapshot_sizes = {}
  endif
  for l:store in [s:watch.baseline, s:watch.signatures, s:watch.hashes, s:watch.contents, s:watch.snapshot_sizes, s:watch.diffs]
    for l:key in keys(l:store)
      if l:key ==# l:path || stridx(l:key, l:path . '/') ==# 0
        call remove(l:store, l:key)
      endif
    endfor
  endfor
  let s:snapshot_bytes = 0
  for l:size in values(get(s:watch, 'snapshot_sizes', {}))
    let s:snapshot_bytes += l:size
  endfor
  call filter(s:snapshot_order, 'v:val !=# l:path && stridx(v:val, l:path . "/") !=# 0')
  for l:key in keys(s:expanded)
    if l:key ==# l:path || stridx(l:key, l:path . '/') ==# 0
      call remove(s:expanded, l:key)
    endif
  endfor
  if s:selected_path ==# l:path || stridx(s:selected_path, l:path . '/') ==# 0
    let s:selected_path = ''
  endif
  if s:changed_path ==# l:path || stridx(s:changed_path, l:path . '/') ==# 0
    let s:changed_path = ''
  endif
endfunction

function! s:RemapPaths(store, old, new) abort
  for l:key in keys(a:store)
    if l:key ==# a:old || stridx(l:key, a:old . '/') ==# 0
      let l:value = remove(a:store, l:key)
      let a:store[a:new . strpart(l:key, strlen(a:old))] = l:value
    endif
  endfor
endfunction

function! s:SafeChildPath(parent, name) abort
  let l:name = a:name
  if empty(l:name) || l:name =~# '^/'
    return ''
  endif
  for l:part in split(l:name, '/', 1)
    if empty(l:part) || l:part ==# '.' || l:part ==# '..'
      return ''
    endif
  endfor
  let l:parent = s:NormalizePath(a:parent)
  let l:path = s:NormalizePath(l:parent . '/' . l:name)
  if !s:IsWithinRoot(l:path) || s:HasSymlinkComponent(l:parent)
    return ''
  endif
  " The target may not exist yet, so validate its existing parent chain.
  return s:HasSymlinkComponent(fnamemodify(l:path, ':h')) ? '' : l:path
endfunction

function! s:RelativePath(path) abort
  let l:path = s:NormalizePath(a:path)
  return l:path ==# s:root ? '' : strpart(l:path, strlen(s:root) + 1)
endfunction

function! s:LoadIgnorePatterns() abort
  let s:ignore_patterns = ['^\.git\%(/\|$\)', '^node_modules\%(/\|$\)', '^__pycache__\%(/\|$\)']
  let l:file = s:root . '/.videignore'
  if filereadable(l:file)
    for l:line in readfile(l:file)
      let l:line = trim(l:line)
      if empty(l:line) || l:line[0] ==# '#'
        continue
      endif
      " Patterns are relative to the project root; accept plain globs and
      " regular expressions without allowing them to escape the root.
      let l:pattern = substitute(l:line, '/\*$', '', '')
      let l:pattern = escape(l:pattern, '\.^$~[]')
      let l:pattern = substitute(l:pattern, '\*', '.*', 'g')
      call add(s:ignore_patterns, '^' . l:pattern . '\%(/\|$\)')
    endfor
  endif
  let g:vide_ignore_patterns = deepcopy(s:ignore_patterns)
endfunction

function! s:ShouldIgnore(path) abort
  let l:relative = s:RelativePath(a:path)
  if empty(l:relative)
    return 0
  endif
  for l:pattern in s:ignore_patterns
    if l:relative =~# l:pattern
      return 1
    endif
  endfor
  return 0
endfunction

function! s:FsCall(operation, paths) abort
  if !executable(s:fs_path)
    call s:TreeError('file operation helper is unavailable; run make fs')
    return 0
  endif
  let l:parts = [shellescape(s:fs_path), shellescape(s:root), shellescape(a:operation)]
  for l:path in a:paths
    call add(l:parts, shellescape(s:RelativePath(l:path)))
  endfor
  let l:output = system(join(l:parts, ' '))
  if v:shell_error != 0 || l:output !~# '^OK\%($\|\n\)'
    let l:message = substitute(l:output, '\n\+$', '', '')
    call s:TreeError(empty(l:message) ? 'secure filesystem operation failed' : l:message)
    return 0
  endif
  return 1
endfunction

function! s:ComparePaths(left, right) abort
  let l:left_dir = s:IsDirectory(a:left)
  let l:right_dir = s:IsDirectory(a:right)
  if l:left_dir != l:right_dir
    return l:left_dir ? -1 : 1
  endif
  let l:left_name = tolower(fnamemodify(a:left, ':t'))
  let l:right_name = tolower(fnamemodify(a:right, ':t'))
  return l:left_name ==# l:right_name ? 0 : (l:left_name ># l:right_name ? 1 : -1)
endfunction

" readdir() is ~1500x faster than readdirex() on the bundled Vim build (the
" latter does a full stat per entry internally), so both the explorer and the
" startup walk read directories with readdir().  Each entry's dir/file type is
" resolved once and cached in s:node_types; the sort comparator then hits the
" cache instead of stat'ing once per comparison.
" Classify one directory entry: returns '' for ignored/transient entries,
" otherwise the normalized path with its type cached.
function! s:ClassifyEntry(parent, name) abort
  if a:name ==# '.' || a:name ==# '..'
    return ''
  endif
  let l:normalized = s:NormalizePath(a:parent . '/' . a:name)
  if l:normalized ==# s:root || l:normalized ==# fnamemodify(s:root, ':h') || s:IsTransient(l:normalized) || s:ShouldIgnore(l:normalized)
    return ''
  endif
  let s:node_types[l:normalized] = s:IsDirectory(l:normalized)
  return l:normalized
endfunction

function! s:RawChildren(path) abort
  let l:result = []
  try
    for l:name in readdir(a:path)
      let l:normalized = s:ClassifyEntry(a:path, l:name)
      if !empty(l:normalized)
        call add(l:result, l:normalized)
      endif
    endfor
  catch /^Vim\%((\a\+))\=:E/
    return []
  endtry
  return l:result
endfunction

function! s:Children(path) abort
  if has_key(s:children_cache, a:path)
    return copy(s:children_cache[a:path])
  endif
  let l:result = s:RawChildren(a:path)
  let l:result = sort(l:result, function('s:ComparePaths'))
  let s:children_cache[a:path] = copy(l:result)
  return l:result
endfunction

" Build the display text for one tree node.  Extracted from AddNode so an
" incremental refresh can rewrite a single changed line without rebuilding the
" whole tree.
function! s:NodeLine(path, depth) abort
  let l:is_dir = s:IsDirectory(a:path)
  let l:name = a:path ==# s:root ? s:DisplayName(s:root) : s:DisplayName(a:path)
  let l:indent = repeat('  ', a:depth)
  if l:is_dir
    let l:prefix = l:indent . s:TreeMarker(a:path) . ' '
    return l:prefix . s:FitTreeLabel(l:name, winwidth(0) - strdisplaywidth(l:prefix))
  endif
  let l:prefix = l:indent . '  '
  return l:prefix . s:FitTreeLabel(l:name, winwidth(0) - strdisplaywidth(l:prefix))
endfunction

function! s:AddNode(path, depth, lines, nodes) abort
  let l:is_dir = s:IsDirectory(a:path)
  call add(a:lines, s:NodeLine(a:path, a:depth))
  call add(a:nodes, {'path': a:path, 'dir': l:is_dir, 'line': len(a:lines), 'depth': a:depth})

  if l:is_dir && has_key(s:expanded, a:path)
    for l:child in s:Children(a:path)
      call s:AddNode(l:child, a:depth + 1, a:lines, a:nodes)
    endfor
  endif
endfunction

" Matches belong to a window, not a buffer, so the ids are tracked in a
" window-local variable.  Keeping them in b: leaves stale ids behind whenever
" the tree buffer is shown in a different window.
function! s:ApplyChangedHighlight() abort
  for l:id in get(w:, 'vide_matches', [])
    silent! call matchdelete(l:id)
  endfor
  let w:vide_matches = []

  let l:nodes = get(b:, 'vide_nodes', [])
  if empty(l:nodes)
    return
  endif
  let l:now = localtime()

  for l:node in l:nodes
    " Highest priority first: a conflict matters more than a plain change.
    if has_key(s:conflicts, l:node.path)
      call add(w:vide_matches,
            \ matchaddpos('VideConflict', [[l:node.line, 1, -1]], 25))
    elseif l:node.path ==# s:changed_path
      call add(w:vide_matches,
            \ matchaddpos('VideChanged', [[l:node.line, 1, -1]], 20))
    elseif has_key(s:recent_changes, l:node.path)
          \ && l:now - s:recent_changes[l:node.path] < 5
      call add(w:vide_matches,
            \ matchaddpos('VideRecentChange', [[l:node.line, 1, -1]], 15))
    endif
  endfor
endfunction

function! s:BuildTree() abort
  let l:lines = []
  let l:nodes = []
  call s:AddNode(s:root, 0, l:lines, l:nodes)
  return [l:lines, l:nodes]
endfunction

function! s:DrawTree(lines, nodes) abort
  setlocal modifiable
  silent %delete _
  call setline(1, a:lines)
  if line('$') > len(a:lines)
    call deletebufline('%', len(a:lines) + 1, '$')
  endif
  let b:vide_lines = a:lines
  let b:vide_nodes = a:nodes
  setlocal nomodifiable
  " Conflict count for the statusline (0 means no marker)
  let b:vide_conflict_count = len(s:conflicts)
  call s:ApplyChangedHighlight()
  if !empty(s:selected_path)
    for l:node in a:nodes
      if l:node.path ==# s:selected_path
        call cursor(l:node.line, 1)
        break
      endif
    endfor
  endif
endfunction

function! s:Render() abort
  if !bufexists(s:tree_buf)
    return
  endif
  let l:origin_win = win_getid()
  if !win_gotoid(s:tree_win)
    return
  endif
  let [l:lines, l:nodes] = s:BuildTree()
  call s:DrawTree(l:lines, l:nodes)
  if win_getid() != l:origin_win && win_id2win(l:origin_win) > 0
    call win_gotoid(l:origin_win)
  endif
endfunction

" Refresh the tree after an external content change.  When the changed path is
" already a visible node we update only that line plus the highlights (a few
" ms); otherwise we fall back to a full rebuild (needed to reveal newly
" expanded ancestors or reflect a structural change).
function! s:RenderChangedPath(path) abort
  if !bufexists(s:tree_buf)
    return
  endif
  let l:origin_win = win_getid()
  if !win_gotoid(s:tree_win)
    return
  endif
  let l:node = {}
  for l:cand in get(b:, 'vide_nodes', [])
    if l:cand.path ==# a:path
      let l:node = l:cand
      break
    endif
  endfor
  if empty(l:node)
    call s:Render()
  else
    setlocal modifiable
    call setline(l:node.line, s:NodeLine(a:path, l:node.depth))
    setlocal nomodifiable
    call s:ApplyChangedHighlight()
    if !empty(s:selected_path)
      for l:cand in get(b:, 'vide_nodes', [])
        if l:cand.path ==# s:selected_path
          call cursor(l:cand.line, 1)
          break
        endif
      endfor
    endif
  endif
  if win_getid() != l:origin_win && win_id2win(l:origin_win) > 0
    call win_gotoid(l:origin_win)
  endif
endfunction

function! s:SelectPath(path) abort
  let l:path = s:NormalizePath(a:path)
  let s:selected_path = l:path
  if !bufexists(s:tree_buf) || win_id2win(s:tree_win) == 0
    return
  endif
  let l:origin_win = win_getid()
  if !win_gotoid(s:tree_win)
    return
  endif
  for l:node in get(b:, 'vide_nodes', [])
    if l:node.path ==# l:path
      call cursor(l:node.line, 1)
      normal! zv
      break
    endif
  endfor
  if win_getid() != l:origin_win && win_id2win(l:origin_win) > 0
    call win_gotoid(l:origin_win)
  endif
endfunction

function! s:Reveal(path) abort
  let l:parent = fnamemodify(a:path, ':h')
  while l:parent !=# s:root && stridx(l:parent, s:root . '/') ==# 0
    let s:expanded[l:parent] = 1
    let l:parent = fnamemodify(l:parent, ':h')
  endwhile
  let s:expanded[s:root] = 1
endfunction

function! s:EditorWindow() abort
  if win_id2win(s:editor_win) > 0
    return s:editor_win
  endif
  for l:info in getwininfo()
    if l:info.bufnr != s:tree_buf
      let s:editor_win = l:info.winid
      return s:editor_win
    endif
  endfor
  return -1
endfunction

" Record that a file changed externally while the user had unsaved edits, and
" stash the external text so <F5> can diff the two versions.
function! s:RegisterConflict(path) abort
  let l:path = s:NormalizePath(a:path)
  if empty(l:path)
    return
  endif
  let l:known = has_key(s:conflicts, l:path)
  let s:conflicts[l:path] = {
        \ 'time': localtime(),
        \ 'user_modified': 1,
        \ 'need_review': 1}
  call s:SaveExternalVersion(l:path)
  call s:Render()
  if !l:known
    echohl WarningMsg
    echomsg 'CONFLICT: ' . fnamemodify(l:path, ':t')
          \ . ' - external change detected, your edits kept (<F5> to compare)'
    echohl None
  endif
endfunction

function! s:FileChangedShell() abort
  " An agent may replace a file while it is visible in Vim.  Do not stop on
  " Vim's interactive "file changed" prompt: reload clean buffers and keep
  " unsaved buffers exactly as the user left them.
  let l:path = expand('<afile>:p')
  if &modified
    let v:fcs_choice = 'use'
    call s:RegisterConflict(l:path)
  else
    let v:fcs_choice = 'reload'
    if has_key(s:conflicts, l:path)
      call remove(s:conflicts, l:path)
      call s:Render()
    endif
  endif
endfunction

function! s:OpenFile(path, line) abort
  let l:winid = s:EditorWindow()
  if l:winid < 0 || !win_gotoid(l:winid)
    return
  endif
  if &modified && expand('%:p') ==# a:path
    " Never issue :edit on the active unsaved buffer: that would trigger an
    " interactive E37 prompt from the asynchronous watcher callback.
    " Record the conflict here too -- FileChangedShell only runs when Vim
    " itself notices the change, which this watcher-driven path pre-empts.
    call s:RegisterConflict(a:path)
    call s:TreeError('external change detected; unsaved buffer preserved')
    return
  endif
  if expand('%:p') ==# a:path && !&modified
    " Reload the existing buffer without opening a second instance or
    " re-entering Vim's swap-file warning path.
    silent! noautocmd keepalt edit!
    call cursor(max([1, a:line]), 1)
    return
  endif
  let l:existing = bufnr(a:path)
  if l:existing > 0 && bufloaded(l:existing)
    execute 'buffer ' . l:existing
    call cursor(max([1, a:line]), 1)
    normal! zv
    return
  endif
  if &modified && expand('%:p') !=# a:path
    " Preserve local work while still honoring an external-change jump.
    rightbelow new
    let s:editor_win = win_getid()
    call s:StyleEditorWindow()
  endif
  execute 'edit ' . fnameescape(a:path)
  call cursor(max([1, a:line]), 1)
  normal! zv
  call s:RememberPath(a:path)
endfunction

function! s:MouseActivate() abort
  if line('.') < 1
    return
  endif
  call s:Activate()
endfunction

function! s:NodeAtCursor() abort
  return get(get(b:, 'vide_nodes', []), line('.') - 1, {})
endfunction

function! s:Activate() abort
  let l:node = s:NodeAtCursor()
  if empty(l:node)
    return
  endif
  if l:node.dir
    let s:selected_path = l:node.path
    if has_key(s:expanded, l:node.path)
      call remove(s:expanded, l:node.path)
    else
      let s:expanded[l:node.path] = 1
    endif
    call s:Render()
    if win_gotoid(s:tree_win)
      call cursor(l:node.line, 1)
    endif
  else
    let s:selected_path = l:node.path
    call s:OpenFile(l:node.path, 1)
  endif
endfunction

function! s:Collapse() abort
  let l:node = s:NodeAtCursor()
  if !empty(l:node) && l:node.dir && has_key(s:expanded, l:node.path) && l:node.path !=# s:root
    call remove(s:expanded, l:node.path)
    call s:Render()
  endif
endfunction

function! s:CreateNode() abort
  let l:node = s:NodeAtCursor()
  if empty(l:node)
    return
  endif
  let l:parent = l:node.dir ? l:node.path : fnamemodify(l:node.path, ':h')
  let l:name = input('Create relative path: ')
  let l:path = s:SafeChildPath(l:parent, l:name)
  if empty(l:path)
    call s:TreeError('path must stay inside the project')
    return
  endif
  let l:kind = confirm('Create ' . fnamemodify(l:path, ':t') . ' as:', "&File\n&Directory\n&Cancel", 3)
  if l:kind == 3 || l:kind == 0
    return
  endif
  let l:operation = l:kind == 1 ? 'create-file' : 'create-dir'
  if !s:FsCall(l:operation, [l:path])
    return
  endif
  call s:InvalidateTreeCache()
  if l:kind == 1
    call s:RememberPath(l:path)
  endif
  call s:Reveal(l:path)
  let s:selected_path = l:path
  call s:Render()
  call s:SelectPath(l:path)
  call s:TreeMessage('created ' . s:DisplayName(l:path))
endfunction

function! s:DeleteNode() abort
  let l:node = s:NodeAtCursor()
  if empty(l:node) || l:node.path ==# s:root
    call s:TreeError('the project root cannot be deleted')
    return
  endif
  let l:label = s:DisplayName(l:node.path)
  let l:question = l:node.dir ? 'Delete directory ' . l:label . ' and all contents?' : 'Delete file ' . l:label . '?'
  if confirm(l:question, "&Cancel\n&Delete", 1) != 2
    return
  endif
  if !s:FsCall('delete', [l:node.path])
    return
  endif
  call s:InvalidateTreeCache()
  call s:PruneWatch(l:node.path)
  if s:changed_path ==# l:node.path || stridx(s:changed_path, l:node.path . '/') ==# 0
    let s:changed_path = ''
  endif
  let s:selected_path = fnamemodify(l:node.path, ':h')
  for l:path in keys(s:expanded)
    if l:path ==# l:node.path || stridx(l:path, l:node.path . '/') ==# 0
      call remove(s:expanded, l:path)
    endif
  endfor
  call s:Render()
  call s:TreeMessage('deleted ' . l:label)
endfunction

function! s:RenameNode() abort
  let l:node = s:NodeAtCursor()
  if empty(l:node) || l:node.path ==# s:root
    call s:TreeError('the project root cannot be renamed')
    return
  endif
  let l:old = l:node.path
  let l:name = input('Rename ' . s:DisplayName(l:old) . ' to: ')
  let l:new = s:SafeChildPath(fnamemodify(l:old, ':h'), l:name)
  if empty(l:new)
    call s:TreeError('name must be a child of the current directory')
    return
  endif
  if l:new ==# l:old
    return
  endif
  if !s:FsCall('rename', [l:old, l:new])
    return
  endif
  call s:InvalidateTreeCache()
  call s:RemapPaths(s:expanded, l:old, l:new)
  call s:RemapPaths(s:watch.baseline, l:old, l:new)
  call s:RemapPaths(s:watch.signatures, l:old, l:new)
  call s:RemapPaths(s:watch.hashes, l:old, l:new)
  call s:RemapPaths(s:watch.contents, l:old, l:new)
  call s:RemapPaths(s:watch.snapshot_sizes, l:old, l:new)
  call s:RemapPaths(s:watch.diffs, l:old, l:new)
  let s:snapshot_order = map(s:snapshot_order, 'v:val ==# l:old || stridx(v:val, l:old . "/") ==# 0 ? l:new . strpart(v:val, strlen(l:old)) : v:val')
  if s:changed_path ==# l:old || stridx(s:changed_path, l:old . '/') ==# 0
    let s:changed_path = l:new . strpart(s:changed_path, strlen(l:old))
  endif
  let s:selected_path = l:new
  call s:Reveal(l:new)
  call s:Render()
  call s:SelectPath(l:new)
  call s:TreeMessage('renamed to ' . s:DisplayName(l:new))
endfunction

function! s:CanWatch(path) abort
  return a:path !~# '/\.git\%(/\|$\)' && !s:IsTransient(a:path) &&
        \ !s:ShouldIgnore(a:path) && getftype(a:path) !=# 'link' && filereadable(a:path)
endfunction

function! s:CollectFiles(path, files) abort
  if a:path =~# '/\.git\%(/\|$\)' || s:ShouldIgnore(a:path)
    return
  endif
  for l:entry in s:Children(a:path)
    if s:IsDirectory(l:entry)
      call s:CollectFiles(l:entry, a:files)
    elseif s:CanWatch(l:entry)
      call add(a:files, l:entry)
    endif
  endfor
endfunction

function! s:ReadSnapshot(path) abort
  let l:size = getfsize(a:path)
  if l:size < 0 || l:size > s:content_limit
    return {'contents': [], 'hash': '', 'size': l:size}
  endif
  try
    let l:contents = readfile(a:path, 'b')
    return {'contents': l:contents, 'hash': sha256(join(l:contents, "\n")), 'size': l:size}
  catch /^Vim\%((\a\+)\)\=:E/
    return {'contents': [], 'hash': '', 'size': l:size}
  endtry
endfunction

function! s:SnapshotCost(contents, size) abort
  if a:size < 0
    return 0
  endif
  return a:size + len(a:contents) * 32 + 64
endfunction

function! s:NewBaselineState(files) abort
  return {'files': a:files, 'index': 0, 'bytes': 0, 'signatures': {},
        \ 'hashes': {}, 'contents': {}, 'baseline': {}, 'sizes': {},
        \ 'diffs': {}, 'order': [], 'phase': 'snapshot', 'stack': [],
        \ 'entries': [], 'entry_index': 0, 'cur_dir': ''}
endfunction

function! s:CollectBaselineFile(state, path) abort
  if !s:CanWatch(a:path)
    return
  endif
  let l:size = getfsize(a:path)
  let a:state.signatures[a:path] = getftime(a:path) . ':' . l:size
  " 'stat' snapshot mode tracks changes by mtime+size alone and never reads
  " file contents at startup, so large projects open without any I/O of the
  " file bodies.  Content snapshots (for precise change lines and F5 diff)
  " are only taken in 'content' mode.
  if get(s:settings, 'snapshot_mode', 'content') !=# 'content'
    return
  endif
  if l:size < 0 || l:size > s:content_limit
    return
  endif
  " Do not open every small file once the snapshot budget can no longer
  " accommodate it.  The previous code read the file first and only then
  " checked the budget, making large projects pay the full I/O cost even for
  " snapshots that were immediately discarded.
  let l:minimum_cost = s:SnapshotCost([], l:size)
  if a:state.bytes + l:minimum_cost > s:snapshot_budget
    return
  endif
  let l:snapshot = s:ReadSnapshot(a:path)
  let l:cost = s:SnapshotCost(l:snapshot.contents, l:snapshot.size)
  if a:state.bytes + l:cost > s:snapshot_budget
    return
  endif
  let a:state.hashes[a:path] = l:snapshot.hash
  let a:state.contents[a:path] = l:snapshot.contents
  let a:state.baseline[a:path] = {'hash': l:snapshot.hash, 'size': l:snapshot.size}
  let a:state.sizes[a:path] = l:cost
  call add(a:state.order, a:path)
  let a:state.bytes += l:cost
endfunction

function! s:BaselineResult(state) abort
  return {'baseline': a:state.baseline, 'signatures': a:state.signatures,
        \ 'hashes': a:state.hashes, 'contents': a:state.contents,
        \ 'snapshot_sizes': a:state.sizes, 'diffs': a:state.diffs}
endfunction

function! s:CollectWatch() abort
  " This is the one startup baseline. All later updates arrive as OS events.
  let l:files = []
  call s:CollectFiles(s:root, l:files)
  let l:state = s:NewBaselineState(l:files)
  for l:path in l:files
    call s:CollectBaselineFile(l:state, l:path)
  endfor
  let s:snapshot_order = l:state.order
  let s:snapshot_bytes = l:state.bytes
  return s:BaselineResult(l:state)
endfunction

function! s:FinishAsyncBaseline() abort
  let s:snapshot_order = s:baseline_state.order
  let s:snapshot_bytes = s:baseline_state.bytes
  let s:watch = s:BaselineResult(s:baseline_state)
  let s:baseline_state = {}
  let s:baseline_timer = -1
  let s:initializing = 0
  let s:workspace_ready = 1
  call s:Render()
  call s:RefreshSplash()
  call s:DrainPendingEvents()
endfunction

function! s:BaselineTick(timer) abort
  if empty(s:baseline_state)
    let s:baseline_timer = -1
    return
  endif
  let l:start = reltime()
  let l:count = 0
  if s:baseline_state.phase ==# 'walk'
    " Directory enumeration is incremental at the per-entry level: a directory
    " is listed with the cheap readdir() once and each entry is classified in a
    " small slice, so even a directory with thousands of entries can never
    " freeze the UI for longer than one slice.
    while 1
      if s:baseline_state.entry_index >= len(s:baseline_state.entries)
        if empty(s:baseline_state.stack)
          break
        endif
        let s:baseline_state.cur_dir = remove(s:baseline_state.stack, -1)
        if s:baseline_state.cur_dir =~# '/\.git\%(/\|$\)' || s:ShouldIgnore(s:baseline_state.cur_dir)
          let s:baseline_state.entries = []
          let s:baseline_state.entry_index = 0
          continue
        endif
        try
          let s:baseline_state.entries = readdir(s:baseline_state.cur_dir)
        catch /^Vim\%((\a\+))\=:E/
          let s:baseline_state.entries = []
        endtry
        let s:baseline_state.entry_index = 0
        continue
      endif
      let l:name = s:baseline_state.entries[s:baseline_state.entry_index]
      let s:baseline_state.entry_index += 1
      let l:entry = s:ClassifyEntry(s:baseline_state.cur_dir, l:name)
      if !empty(l:entry)
        if s:IsDirectory(l:entry)
          call add(s:baseline_state.stack, l:entry)
        elseif s:CanWatch(l:entry)
          call add(s:baseline_state.files, l:entry)
        endif
        let l:count += 1
      endif
      if l:count >= 64 || reltimefloat(reltime(l:start)) >= 0.02
        break
      endif
    endwhile
    if empty(s:baseline_state.stack) && s:baseline_state.entry_index >= len(s:baseline_state.entries)
      let s:baseline_state.phase = 'snapshot'
    endif
  else
    while s:baseline_state.index < len(s:baseline_state.files)
      let l:path = s:baseline_state.files[s:baseline_state.index]
      let s:baseline_state.index += 1
      call s:CollectBaselineFile(s:baseline_state, l:path)
      let l:count += 1
      if l:count >= 64 || reltimefloat(reltime(l:start)) >= 0.02
        break
      endif
    endwhile
  endif
  if s:baseline_state.phase ==# 'snapshot' && s:baseline_state.index >= len(s:baseline_state.files)
    call s:FinishAsyncBaseline()
  else
    " Yield to Vim's input loop between slices.  Re-arming a zero-delay timer
    " continuously can starve keyboard and mouse events on large projects.
    if exists('*timer_start')
      let s:baseline_timer = timer_start(10, function('<SID>BaselineTick'))
    else
      call s:BaselineTick(-1)
    endif
  endif
endfunction

function! s:BeginBaseline() abort
  let s:baseline_state = s:NewBaselineState([])
  let s:baseline_state.phase = 'walk'
  let s:baseline_state.stack = [s:root]
  let s:initializing = 1
  if exists('*timer_start')
    let s:baseline_timer = timer_start(0, function('<SID>BaselineTick'))
  else
    call s:BaselineTick(-1)
  endif
endfunction

function! s:StoreSnapshot(path, contents) abort
  if has_key(s:watch.contents, a:path)
    let s:snapshot_bytes -= get(get(s:watch, 'snapshot_sizes', {}), a:path, 0)
  endif
  if !has_key(s:watch, 'snapshot_sizes')
    let s:watch.snapshot_sizes = {}
  endif
  if has_key(s:watch.snapshot_sizes, a:path)
    call remove(s:watch.snapshot_sizes, a:path)
  endif
  call filter(s:snapshot_order, 'v:val !=# a:path')
  let l:size = getfsize(a:path)
  let l:cost = s:SnapshotCost(a:contents, l:size)

  " Check if this is a priority path
  let l:is_priority = index(s:priority_paths, a:path) >= 0

  if l:size >= 0 && l:size <= s:content_limit
    let s:watch.contents[a:path] = a:contents
    let s:watch.snapshot_sizes[a:path] = l:cost
    if l:is_priority
      let s:snapshot_priorities[a:path] = 1
    endif
    let s:snapshot_bytes += l:cost
    call add(s:snapshot_order, a:path)
  else
    if has_key(s:watch.contents, a:path)
      call remove(s:watch.contents, a:path)
    endif
    if has_key(s:snapshot_priorities, a:path)
      call remove(s:snapshot_priorities, a:path)
    endif
  endif

  " Budget cleanup - skip priority files
  while s:snapshot_bytes > s:snapshot_budget && !empty(s:watch.contents)
    let l:victim = remove(s:snapshot_order, 0)
    " Skip high priority files
    if get(s:snapshot_priorities, l:victim, 0)
      call add(s:snapshot_order, l:victim)
      continue
    endif
    let s:snapshot_bytes -= get(s:watch.snapshot_sizes, l:victim, 0)
    call remove(s:watch.snapshot_sizes, l:victim)
    call remove(s:watch.contents, l:victim)
  endwhile
endfunction

function! s:SnapshotStats() abort
  return {'files': len(get(s:watch, 'contents', {})),
        \ 'bytes': s:snapshot_bytes, 'budget': s:snapshot_budget}
endfunction

function! s:FirstChangedLine(before, after) abort
  let l:limit = min([len(a:before), len(a:after)])
  for l:index in range(0, l:limit - 1)
    if a:before[l:index] !=# a:after[l:index]
      return l:index + 1
    endif
  endfor
  return l:limit + 1
endfunction

function! s:BuildDiff(before, after) abort
  let l:diff = []
  let l:limit = max([len(a:before), len(a:after)])
  if l:limit == 0
    return l:diff
  endif
  for l:index in range(0, l:limit - 1)
    let l:old = l:index < len(a:before) ? a:before[l:index] : v:null
    let l:new = l:index < len(a:after) ? a:after[l:index] : v:null
    if l:old !=# l:new
      call add(l:diff, {'type': l:old is# v:null ? 'insert' : l:new is# v:null ? 'delete' : 'change',
            \ 'line': l:index + 1, 'before': l:old, 'after': l:new})
    endif
  endfor
  return l:diff
endfunction

function! s:RememberPath(path) abort
  let l:path = s:NormalizePath(a:path)
  if !s:CanWatch(l:path)
    return
  endif
  let l:snapshot = s:ReadSnapshot(l:path)
  let s:watch.signatures[l:path] = getftime(l:path) . ':' . getfsize(l:path)
  let s:watch.hashes[l:path] = l:snapshot.hash
  if !has_key(s:watch, 'baseline')
    let s:watch.baseline = {}
  endif
  if !has_key(s:watch.baseline, l:path)
    let s:watch.baseline[l:path] = {'hash': l:snapshot.hash, 'size': l:snapshot.size}
  endif
  call s:StoreSnapshot(l:path, l:snapshot.contents)
endfunction

function! s:HandleChangedPath(path, kind) abort
  let l:kind = a:kind
  let l:path = s:NormalizePath(a:path)
  if empty(l:path) || (l:path !=# s:root && stridx(l:path, s:root . '/') !=# 0) || l:path =~# '/\.git\%(/\|$\)'
    return
  endif
  if l:path ==# s:root && index(['MOVE_OUT', 'DELETE', 'ROOT_LOST'], l:kind) >= 0
    let g:vide_watch_backend = 'OFF'
    call s:TreeError('project root was removed or moved')
    return
  endif
  if index(['CREATE', 'MOVE_IN'], l:kind) >= 0
    call s:InvalidateTreeCache()
  endif
  if index(['MOVE_OUT', 'DELETE'], l:kind) >= 0
    call s:InvalidateTreeCache()
    call s:PruneWatch(l:path)
    let s:render_dirty = 1
    let s:structural_change = 1
    let s:has_open_candidate = 0
    return
  endif
  if l:kind ==# 'DIR' || s:IsDirectory(l:path)
    call s:InvalidateTreeCache()
    let s:render_dirty = 1
    let s:structural_change = 1
    let s:has_open_candidate = 0
    return
  endif
  if !filereadable(l:path) || s:IsTransient(l:path)
    if s:selected_path ==# l:path
      let s:selected_path = ''
    endif
    call s:PruneWatch(l:path)
    call s:InvalidateTreeCache()
    let s:render_dirty = 1
    let s:structural_change = 1
    let s:has_open_candidate = 0
    return
  endif

  let l:signature = getftime(l:path) . ':' . getfsize(l:path)
  let l:snapshot = s:ReadSnapshot(l:path)
  let l:hash = l:snapshot.hash

  " A metadata-only event (chmod, touch) carries no content change, so accept
  " it just when the hash really moved.  'minimal' mode drops them outright.
  if l:kind ==# 'ATTRIB'
    if s:GetWatchBehavior().ignore_attrib
      return
    endif
    if has_key(s:watch.hashes, l:path) &&
          \ get(s:watch.hashes, l:path, '') ==# l:hash &&
          \ !empty(l:hash)
      return
    endif
  endif

  let l:before = get(s:watch.contents, l:path, [])
  let l:after = l:snapshot.contents
  let s:watch.signatures[l:path] = l:signature
  let s:watch.hashes[l:path] = l:hash
  if !has_key(s:watch, 'baseline')
    let s:watch.baseline = {}
  endif
  if !has_key(s:watch.baseline, l:path)
    let s:watch.baseline[l:path] = {'hash': get(s:watch.hashes, l:path, ''), 'size': getfsize(l:path)}
  endif
  if !has_key(s:watch, 'diffs')
    let s:watch.diffs = {}
  endif
  let s:watch.diffs[l:path] = s:BuildDiff(l:before, l:after)
  call s:StoreSnapshot(l:path, l:after)

  " Track recent changes and update priority
  call s:TrackRecentChange(l:path, l:kind)
  call s:UpdatePriorityPaths()

  let s:changed_path = l:path
  let s:selected_path = l:path
  let s:changed_line = s:FirstChangedLine(l:before, l:after)
  call s:Reveal(l:path)
  let s:render_dirty = 1
  " Remember the most recently changed file so the batch flush can open it
  " exactly once after all events in the batch are handled, instead of each
  " event stealing the editor window.
  let s:batch_last_path = l:path
  let s:batch_last_line = s:changed_line
  let s:has_open_candidate = 1
endfunction

" Sort helper for the arrival-ordered event batch: [seq, event] pairs.
function! s:SortBySeq(a, b) abort
  return a:a[0] - a:b[0]
endfunction

function! s:FlushChangedEvents(timer) abort
  let s:event_timer = -1
  if s:initializing || empty(s:pending_events)
    return
  endif
  let l:events = s:pending_events
  let s:pending_events = []
  " Deduplicate the batch while preserving arrival order.  For WRITE/ATTRIB
  " only the last occurrence of each path is kept, but its position is the one
  " it would occupy in arrival order, so the most recently written file is
  " processed last and is therefore the one the batch opens.
  let l:compact = []
  let l:by_path = {}
  let l:position = 0
  for l:event in l:events
    let l:kind = l:event[0]
    let l:path = l:event[1]
    if index(['WRITE', 'ATTRIB'], l:kind) >= 0
      let l:by_path[l:path] = [l:position, l:event]
    else
      call add(l:compact, [l:position, l:event])
    endif
    let l:position += 1
  endfor
  for l:entry in values(l:by_path)
    call add(l:compact, l:entry)
  endfor
  call sort(l:compact, function('s:SortBySeq'))
  let l:compact = map(l:compact, 'v:val[1]')
  let s:render_dirty = 0
  let s:structural_change = 0
  let s:has_open_candidate = 0
  let s:last_message = ''
  for l:event in l:compact
    call s:HandleChangedPath(l:event[1], l:event[0])
  endfor
  " One tree refresh for the whole batch instead of one per event.
  if s:render_dirty
    if s:structural_change
      call s:Render()
    else
      call s:RenderChangedPath(s:batch_last_path)
    endif
  endif
  " Open the most recently changed file exactly once per batch.  auto_jump
  " (on by default) preserves the "open the changed file" behaviour, while a
  " burst of writes no longer yanks the editor window once per file.
  if s:has_open_candidate && !empty(s:batch_last_path) && get(s:settings, 'auto_jump', 1)
    call s:OpenFile(s:batch_last_path, s:batch_last_line)
  endif
  " Surface a single change message per batch instead of one echomsg per event.
  if get(s:settings, 'verbose_changes', 1) && !empty(s:last_message)
    echomsg 'VIDE: ' . s:last_message
  endif
endfunction

function! s:QueueChangedEvent(kind, path) abort
  if !exists('*timer_start')
    call s:HandleChangedPath(a:path, a:kind)
    return
  endif
  call add(s:pending_events, [a:kind, a:path])
  if s:event_timer < 0
    " Get behavior based on watch mode
    let l:behavior = s:GetWatchBehavior()
    let s:event_timer = timer_start(l:behavior.event_delay_ms, function('<SID>FlushChangedEvents'))
  endif
endfunction

function! s:GetWatchBehavior() abort
  let l:mode = get(s:settings, 'watch_mode', 'aggressive')
  if l:mode ==# 'aggressive'
    return {
          \ 'event_delay_ms': 50,
          \ 'force_reload': 1,
          \ 'ignore_attrib': 0,
          \ 'show_all_changes': 1
          \ }
  elseif l:mode ==# 'minimal'
    return {
          \ 'event_delay_ms': 150,
          \ 'force_reload': 0,
          \ 'ignore_attrib': 1,
          \ 'show_all_changes': 0
          \ }
  else
    return {
          \ 'event_delay_ms': 100,
          \ 'force_reload': 0,
          \ 'ignore_attrib': 0,
          \ 'show_all_changes': 1
          \ }
  endif
endfunction

function! s:AdjustWatchMode() abort
  " Drop the timer armed with the previous delay, then drain what is queued so
  " nothing waits on a timer that no longer exists.
  if s:event_timer >= 0
    silent! call timer_stop(s:event_timer)
    let s:event_timer = -1
  endif
  if !empty(s:pending_events)
    call s:FlushChangedEvents(-1)
  endif
  echomsg 'Watch mode set to: ' . s:settings.watch_mode
endfunction

function! s:WatchEvent(channel, message) abort
  if s:watcher_stopping || type(a:message) != type('') || empty(a:message)
    return
  endif
  " Buffer incoming chunks instead of dropping them when the callback re-enters
  " (raw channel output can arrive while a previous chunk is still being
  " parsed).  Events are processed once the queue drains.
  call add(s:watch_queue, a:message)
  if s:watching
    return
  endif
  let s:watching = 1
  try
    while !empty(s:watch_queue)
      let s:watch_buffer .= remove(s:watch_queue, 0)
      while !empty(s:watch_buffer)
        if s:watch_buffer[0] !=# 'P'
          let s:watch_buffer = strpart(s:watch_buffer, 1)
          continue
        endif
        let l:separator = stridx(s:watch_buffer, ':')
        if l:separator < 3
          break
        endif
        let l:header = strpart(s:watch_buffer, 1, l:separator - 1)
        let l:kind = matchstr(l:header, '^[A-Z_]*')
        let l:length_text = strpart(l:header, strlen(l:kind))
        if empty(l:kind) || l:length_text !~# '^\d\+$'
          let s:watch_buffer = ''
          break
        endif
        let l:length = str2nr(l:length_text)
        let l:payload_at = l:separator + 1
        if strlen(s:watch_buffer) < l:payload_at + l:length
          break
        endif
        let l:path = strpart(s:watch_buffer, l:payload_at, l:length)
        let s:watch_buffer = strpart(s:watch_buffer, l:payload_at + l:length)
        if l:kind ==# 'ERROR'
          let s:watch_error = 1
          let g:vide_watch_backend = 'OFF'
          call s:TreeError('watcher ' . l:path)
          continue
        endif
        if s:initializing
          call add(s:pending_events, [l:kind, l:path])
        else
          call s:QueueChangedEvent(l:kind, l:path)
        endif
      endwhile
    endwhile
  finally
    let s:watching = 0
  endtry
endfunction

function! s:WatchError(channel, message) abort
  if !empty(a:message)
    let s:watch_error = 1
    let g:vide_watch_backend = 'OFF'
    if empty(get(g:, 'vide_notice', '')) || get(g:, 'vide_notice', '') !~# '^ERROR:'
      call s:TreeError(substitute(a:message, '\n\+$', '', ''))
    endif
  endif
endfunction

function! s:WatchExit(job, status) abort
  let l:key = string(a:job)
  if has_key(s:stopped_watch_jobs, l:key)
    call remove(s:stopped_watch_jobs, l:key)
    return
  endif
  if type(s:watch_job) == v:t_job && l:key !=# string(s:watch_job)
    return
  endif
  let s:watch_job = 0
  if !s:watcher_stopping
    let g:vide_watch_backend = 'OFF'
    if !s:watch_error
      call s:TreeError('watcher stopped; automatic tracking is off')
    endif
  endif
endfunction

function! s:StartWatcher() abort
  let s:watcher_stopping = 0
  let s:watch_error = 0
  let s:watch_buffer = ''
  if !exists('*job_start') || !executable(s:watcher_path)
    let g:vide_watch_backend = 'OFF'
    call s:TreeError('event watcher is unavailable; run make watch')
    return
  endif
  let s:watch_job = job_start([s:watcher_path, s:root], {
        \ 'out_mode': 'raw', 'err_mode': 'nl',
        \ 'out_cb': function('s:WatchEvent'),
        \ 'err_cb': function('s:WatchError'),
        \ 'exit_cb': function('s:WatchExit'), 'stoponexit': 'term'})
  if type(s:watch_job) == v:t_job
    let g:vide_watch_backend = 'LIVE'
  else
    let g:vide_watch_backend = 'OFF'
    call s:TreeError('could not start the event watcher')
  endif
endfunction

function! s:StopWatcher() abort
  let s:watcher_stopping = 1
  " Timer ids start at 0, so compare against the -1 'unset' marker.
  if s:baseline_timer >= 0
    silent! call timer_stop(s:baseline_timer)
    let s:baseline_timer = -1
  endif
  let s:baseline_state = {}
  if s:event_timer >= 0
    silent! call timer_stop(s:event_timer)
    let s:event_timer = -1
  endif
  if s:recent_timer >= 0
    silent! call timer_stop(s:recent_timer)
    let s:recent_timer = -1
  endif
  if type(s:watch_job) == v:t_job
    let s:stopped_watch_jobs[string(s:watch_job)] = 1
    silent! call job_stop(s:watch_job, 'term')
    let s:watch_job = 0
  endif
endfunction

function! s:RestartWatcher() abort
  call s:StopWatcher()
  call s:StartWatcher()
endfunction

function! s:DrainPendingEvents() abort
  call s:FlushChangedEvents(-1)
endfunction

function! s:CloseSettings() abort
  if s:settings_popup > 0
    silent! call popup_close(s:settings_popup)
  endif
  let s:settings_popup = -1
endfunction

function! s:ApplySetting(index, value) abort
  " Numeric settings: reject non-numbers and values outside the advertised
  " range instead of silently clamping a typo to a surprising value.
  if a:index <= 3
    if a:value !~# '^\d\+$'
      call s:TreeError('enter a whole number')
      return
    endif
    let l:keys = ['sidebar_percent', 'content_limit_kb', 'snapshot_budget_kb']
    let l:bounds = s:setting_ranges[l:keys[a:index - 1]]
    let l:number = str2nr(a:value)
    if l:number < l:bounds[0] || l:number > l:bounds[1]
      call s:TreeError(printf('value must be between %d and %d', l:bounds[0], l:bounds[1]))
      return
    endif
  endif
  if a:index == 4 && index(['auto', 'unicode', 'ascii'], tolower(trim(a:value))) < 0
    call s:TreeError('marker style must be auto, unicode, or ascii')
    return
  endif
  if a:index == 5 && index(['aggressive', 'normal', 'minimal'], tolower(trim(a:value))) < 0
    call s:TreeError('watch mode must be aggressive, normal, or minimal')
    return
  endif
  if a:index == 6 && index(['ask', 'use', 'reload'], tolower(trim(a:value))) < 0
    call s:TreeError('conflict strategy must be ask, use, or reload')
    return
  endif
  if a:index == 7 && index(['on', 'off', '1', '0'], tolower(trim(a:value))) < 0
    call s:TreeError('verbose changes must be on/off or 1/0')
    return
  endif
  if a:index == 8 && index(['on', 'off', '1', '0'], tolower(trim(a:value))) < 0
    call s:TreeError('auto-jump must be on/off or 1/0')
    return
  endif
  if a:index == 9 && index(['content', 'stat'], tolower(trim(a:value))) < 0
    call s:TreeError('snapshot mode must be content or stat')
    return
  endif

  if a:index == 1
    let s:settings.sidebar_percent = str2nr(a:value)
  elseif a:index == 2
    let s:settings.content_limit_kb = str2nr(a:value)
  elseif a:index == 3
    let s:settings.snapshot_budget_kb = str2nr(a:value)
  elseif a:index == 4
    let s:settings.marker_style = tolower(trim(a:value))
  elseif a:index == 5
    let s:settings.watch_mode = tolower(trim(a:value))
    call s:AdjustWatchMode()
  elseif a:index == 6
    let s:settings.conflict_strategy = tolower(trim(a:value))
  elseif a:index == 7
    let l:val = tolower(trim(a:value))
    let s:settings.verbose_changes = (l:val ==# 'on' || l:val ==# '1')
  elseif a:index == 8
    let l:val = tolower(trim(a:value))
    let s:settings.auto_jump = (l:val ==# 'on' || l:val ==# '1')
  elseif a:index == 9
    let s:settings.snapshot_mode = tolower(trim(a:value))
  endif
  call s:ValidateSettings()
  call s:SaveSettings()
  call s:ResizeSidebar()
  call s:Render()
endfunction

function! s:EditSetting(index) abort
  if a:index < 1 || a:index > 9
    return
  endif
  call s:CloseSettings()
  if a:index == 1
    let l:value = input('Sidebar width (20-60%) [' . s:settings.sidebar_percent . ']: ')
  elseif a:index == 2
    let l:value = input('Per-file snapshot limit (64-4096 KB) [' . s:settings.content_limit_kb . ']: ')
  elseif a:index == 3
    let l:value = input('Snapshot budget (1024-65536 KB) [' . s:settings.snapshot_budget_kb . ']: ')
  elseif a:index == 4
    let l:value = input('Marker style (auto/unicode/ascii) [' . s:settings.marker_style . ']: ')
  elseif a:index == 5
    let l:value = input('Watch mode (aggressive/normal/minimal) [' . s:settings.watch_mode . ']: ')
  elseif a:index == 6
    let l:value = input('Conflict strategy (ask/use/reload) [' . s:settings.conflict_strategy . ']: ')
  elseif a:index == 7
    let l:value = input('Verbose changes (on/off) [' . (s:settings.verbose_changes ? 'on' : 'off') . ']: ')
  elseif a:index == 8
    let l:value = input('Auto-jump to changed file (on/off) [' . (s:settings.auto_jump ? 'on' : 'off') . ']: ')
  elseif a:index == 9
    let l:value = input('Snapshot mode (content/stat) [' . s:settings.snapshot_mode . ']: ')
  endif
  if !empty(l:value)
    call s:ApplySetting(a:index, l:value)
  endif
  call s:OpenSettings()
endfunction

function! s:SettingsChoice(id, result) abort
  let s:settings_popup = -1
  if a:result > 0
    call s:EditSetting(a:result)
  endif
endfunction

function! s:OpenSettings() abort
  if s:settings_popup > 0
    return
  endif
  if !exists('*popup_create') || &lines < 12 || &columns < 45
    let l:choice = inputlist(['VIDE SETTINGS',
          \ '1. Sidebar width: ' . s:settings.sidebar_percent . '%',
          \ '2. Per-file snapshot: ' . s:settings.content_limit_kb . ' KB',
          \ '3. Snapshot budget: ' . s:settings.snapshot_budget_kb . ' KB',
          \ '4. Marker style: ' . s:settings.marker_style,
          \ '5. Watch mode: ' . s:settings.watch_mode,
          \ '6. Conflict strategy: ' . s:settings.conflict_strategy,
          \ '7. Verbose changes: ' . (s:settings.verbose_changes ? 'ON' : 'OFF'),
          \ '8. Auto-jump: ' . (s:settings.auto_jump ? 'ON' : 'OFF'),
          \ '9. Snapshot mode: ' . s:settings.snapshot_mode])
    if l:choice >= 1 && l:choice <= 9
      let l:value = input('New value: ')
      if !empty(l:value)
        call s:ApplySetting(l:choice, l:value)
      endif
    endif
    return
  endif
  let l:width = min([60, max([32, &columns - 8])])
  highlight PmenuSel cterm=bold ctermfg=Black ctermbg=DarkCyan gui=bold guifg=Black guibg=DarkCyan
  let l:items = [
        \ 'Sidebar width: ' . s:settings.sidebar_percent . '%',
        \ 'Per-file snapshot: ' . s:settings.content_limit_kb . ' KB',
        \ 'Snapshot budget: ' . s:settings.snapshot_budget_kb . ' KB',
        \ 'Marker style: ' . s:settings.marker_style,
        \ 'Watch mode: ' . s:settings.watch_mode . ' (aggressive/normal/minimal)',
        \ 'Conflict strategy: ' . s:settings.conflict_strategy . ' (ask/use/reload)',
        \ 'Verbose changes: ' . (s:settings.verbose_changes ? 'ON' : 'OFF'),
        \ 'Auto-jump to changed file: ' . (s:settings.auto_jump ? 'ON' : 'OFF'),
        \ 'Snapshot mode: ' . s:settings.snapshot_mode . ' (content/stat)']
  let s:settings_popup = popup_menu(l:items, {
        \ 'pos': 'center', 'minwidth': l:width, 'maxwidth': l:width,
        \ 'padding': [1, 2, 1, 2], 'border': [1, 1, 1, 1],
        \ 'highlight': 'VideInterruptWarning',
        \ 'borderhighlight': ['VideInterruptBorder'],
        \ 'title': ' VIDE SETTINGS ', 'callback': function('s:SettingsChoice'),
        \ 'zindex': 250})
endfunction

function! s:ResizeSidebar() abort
  if win_id2win(s:tree_win) > 0
    let l:available = max([20, &columns - 20])
    let l:width = min([l:available, max([20, (&columns * s:settings.sidebar_percent) / 100])])
    call win_execute(s:tree_win, 'vertical resize ' . l:width)
  endif
  call s:RefreshSplash()
endfunction

" Built via '%!' rather than '%{}' so the highlight items below are parsed by
" Vim instead of being shown literally: '%{}' inserts its result as plain text.
function! vide#TreeStatusline() abort
  let l:parts = ['%#VideStatus# VIDE %*']

  let l:conflicts = get(b:, 'vide_conflict_count', 0)
  if l:conflicts > 0
    call add(l:parts, printf('%%#VideConflict# %s CONFLICT%s %%*',
          \ s:ConflictMarker(), l:conflicts > 1 ? 'S(' . l:conflicts . ')' : ''))
  endif

  let l:backend = get(g:, 'vide_watch_backend', 'OFF')
  let l:position = printf('%d/%d', line('.'), line('$'))

  " Measure the fixed text exactly rather than estimating: the sidebar is
  " narrow, so an over-generous budget makes '%<' cut a token in half.
  let l:fixed = strwidth(' VIDE ') + strwidth(' ' . l:backend . ' ')
        \ + strwidth(' ' . l:position . ' ')
  if l:conflicts > 0
    let l:fixed += strwidth(printf(' %s CONFLICT%s ', s:ConflictMarker(),
          \ l:conflicts > 1 ? 'S(' . l:conflicts . ')' : ''))
  endif

  let l:notice = get(g:, 'vide_notice', '')
  let l:detail = !empty(l:notice) ? l:notice : get(g:, 'vide_last_change', '')
  let l:room = s:StatusWidth() - l:fixed - 1

  call add(l:parts, '%=%#VideStatusMeta# ')
  call add(l:parts, s:StatuslineEscape(l:backend) . ' ')
  if !empty(l:detail) && l:room >= 4
    call add(l:parts, s:StatuslineEscape(s:ShortenForStatus(l:detail, l:room)) . ' ')
  endif
  call add(l:parts, s:StatuslineEscape(l:position) . ' ')
  return join(l:parts, '')
endfunction

" Width available to the tree statusline. '%!' is evaluated while Vim draws a
" specific window, so resolve the sidebar window explicitly instead of trusting
" the ambient winwidth(0).
function! s:StatusWidth() abort
  if s:tree_win > 0 && win_id2win(s:tree_win) > 0
    return winwidth(win_id2win(s:tree_win))
  endif
  return winwidth(0)
endfunction

" Dynamic text must not be re-read as statusline syntax.
function! s:StatuslineEscape(text) abort
  return substitute(a:text, '%', '%%', 'g')
endfunction

" Shorten a status message to fit the sidebar.  For a change message
" ('[WRITE] a/b/c.py') the filename is what matters, so leading path segments
" go first; for prose the meaning is up front, so keep the head instead.
function! s:ShortenForStatus(text, width) abort
  if strwidth(a:text) <= a:width
    return a:text
  endif

  let l:kind = matchstr(a:text, '^\[\w\+\]\s*')
  if !empty(l:kind) || a:text =~# '/'
    let l:body = a:text[len(l:kind):]
    let l:segments = split(l:body, '/')
    while len(l:segments) > 1
      call remove(l:segments, 0)
      let l:candidate = l:kind . '…/' . join(l:segments, '/')
      if strwidth(l:candidate) <= a:width
        return l:candidate
      endif
    endwhile
    let l:tail = empty(l:segments) ? l:body : l:segments[-1]
    if strwidth(l:tail) <= a:width
      return l:tail
    endif
    return '…' . strcharpart(l:tail, strchars(l:tail) - a:width + 1)
  endif

  return strcharpart(a:text, 0, a:width - 1) . '…'
endfunction

function! s:ConflictMarker() abort
  return get(s:settings, 'marker_style', 'unicode') ==# 'ascii' ? '!' : '⚠'
endfunction

function! s:SetupTreeBuffer() abort
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap nonumber norelativenumber
  setlocal cursorline cursorlineopt=line signcolumn=no foldcolumn=0 colorcolumn=
  setlocal winfixwidth
  setlocal winhighlight=Normal:VideExplorerNormal,CursorLine:VideExplorerCursor,StatusLine:VideStatusLine,StatusLineNC:VideStatusLineNC,VertSplit:VideDivider
  setlocal statusline=%!vide#TreeStatusline()
  syntax clear
  syntax match VideTreeDirectory '^\s*[▶▼v>]\s.*$'
  syntax match VideTreeRoot '^\(▼\|v\).*$'
  syntax match VideTreeMarker '^\s*[▶▼v>]'
  execute 'file [vide] Explorer'
  nnoremap <silent><buffer> <CR> :<C-U>call <SID>Activate()<CR>
  nnoremap <silent><buffer> <Space> :<C-U>call <SID>Activate()<CR>
  nnoremap <silent><buffer> <Right> :<C-U>call <SID>Activate()<CR>
  nnoremap <silent><buffer> <Left> :<C-U>call <SID>Collapse()<CR>
  nnoremap <silent><buffer> <C-L> :<C-U>call <SID>Render()<CR>
  nnoremap <silent><buffer> <C-N> :<C-U>call <SID>CreateNode()<CR>
  nnoremap <silent><buffer> <C-D> :<C-U>call <SID>DeleteNode()<CR>
  nnoremap <silent><buffer> <C-R> :<C-U>call <SID>RenameNode()<CR>
  nnoremap <silent><buffer> <C-P> :<C-U>call <SID>OpenSettings()<CR>
  nnoremap <silent><buffer> <Tab> <C-W>w
  " Let Vim process the press first so the cursor follows the pointer; the
  " release then activates exactly once.  Mapping both events toggles a
  " directory twice during one normal click.
  nnoremap <silent><buffer> <LeftRelease> :<C-U>call <SID>MouseActivate()<CR>
endfunction

" Conflict and change management.  <C-H> is deliberately not mapped globally:
" most terminals send the same byte for <C-H> and <BS>, so a global mapping
" would break Backspace in the editor window.
nnoremap <silent> <F5> :<C-U>call <SID>CompareConflict()<CR>
nnoremap <silent> <F6> :<C-U>call <SID>ForceRefreshAll()<CR>
nnoremap <silent> <F7> :<C-U>call <SID>ShowChangeHistory()<CR>
command! VideChanges call <SID>ShowChangeHistory()
command! VideRefresh call <SID>ForceRefreshAll()
command! VideDiff call <SID>CompareConflict()

function! s:StyleEditorWindow() abort
  if win_id2win(s:editor_win) > 0
    call win_execute(s:editor_win, 'setlocal nowrap sidescroll=1 winhighlight=StatusLine:VideStatusLine,StatusLineNC:VideStatusLineNC,VertSplit:VideDivider')
  endif
endfunction

function! s:Centered(text) abort
  return repeat(' ', max([0, (winwidth(0) - strdisplaywidth(a:text)) / 2])) . a:text
endfunction

function! s:ShowSplash() abort
  let l:refresh = bufname('%') ==# '[VIDE]'
  if !l:refresh && (argc() > 0 || &modified || !empty(expand('%:p')) || getline(1) !=# '')
    return
  endif
  let l:lines = ['', s:Centered('VIDE'), '']
  let l:hint = s:workspace_ready ? 'Select a file to open' : 'Loading workspace...'
  if winwidth(0) < 34
    " Keep every splash line inside a narrow editor split.
    call extend(l:lines, [s:Centered('Vim IDE'), s:Centered(s:workspace_ready ? 'Ready' : 'Loading...')])
  else
    let l:logo = [
          \ ' __     ___ ____  _____ ',
          \ ' \\ \   / /_ _|  _ \\| ____|',
          \ '  \\ \ / / | || | | |  _|  ',
          \ '   \\ V /  | || |_| | |___ ',
          \ '    \\_/  |___|____/|_____|']
    for l:line in l:logo
      call add(l:lines, s:Centered(l:line))
    endfor
    call extend(l:lines, ['', s:Centered('Vim Development Environment'), s:Centered(l:hint)])
  endif
  setlocal modifiable
  silent %delete _
  call setline(1, l:lines)
  setlocal buftype=nofile bufhidden=wipe noswapfile nowrap nonumber norelativenumber nomodified nomodifiable
  setlocal winhighlight=Normal:VideSplash,EndOfBuffer:VideSplash
  execute 'file [VIDE]'
  syntax clear
  syntax match VideSplash '^\s*__.*$'
  syntax match VideSplash '^\s*\\.*$'
  syntax match VideSplashText 'VIDE\|Vim Development Environment\|Loading workspace...\|Select a file to open\|Ready'
endfunction

function! s:RefreshSplash() abort
  if win_id2win(s:editor_win) == 0
    return
  endif
  let l:origin_win = win_getid()
  if win_gotoid(s:editor_win) && bufname('%') ==# '[VIDE]'
    call s:ShowSplash()
  endif
  if win_getid() != l:origin_win && win_id2win(l:origin_win) > 0
    call win_gotoid(l:origin_win)
  endif
endfunction

function! s:Start() abort
  if s:tree_buf > 0 || &columns < 45
    return
  endif
  let s:editor_win = win_getid()
  call s:LoadIgnorePatterns()
  topleft vertical new
  let s:tree_win = win_getid()
  let s:tree_buf = bufnr('%')
  call s:SetupTreeBuffer()
  call s:ResizeSidebar()
  call s:StyleEditorWindow()
  call win_gotoid(s:editor_win)
  call s:ShowSplash()
  call s:InvalidateTreeCache()
  " Draw the root immediately.  The full baseline below reuses this cache,
  " so showing the tree early does not reintroduce a second walk.
  call s:Render()
  redraw!
  let s:snapshot_order = []
  call s:StartWatcher()
  " Establish the baseline in short timer slices so Vim can paint and accept
  " input while a large project is being opened.
  call s:BeginBaseline()
endfunction

function! s:MaybeExitAfterEditorClose() abort
  if s:tree_buf > 0 && win_id2win(s:tree_win) > 0 && winnr('$') == 1
    execute 'qa'
  endif
endfunction

" vide always owns both panes, so a bare :q should leave the whole workspace.
cnoreabbrev <expr> q getcmdtype() ==# ':' && getcmdpos() == 2 ? 'qa' : 'q'
nnoremap <silent> <C-C> :<C-U>call <SID>Interrupt()<CR>
xnoremap <silent> <C-C> :<C-U>call <SID>Interrupt()<CR>
inoremap <silent> <C-C> <C-O>:call <SID>Interrupt()<CR>
cnoremap <silent> <C-C> <C-U>call <SID>Interrupt()<CR>
tnoremap <silent> <C-C> <C-\\><C-N>:call <SID>Interrupt()<CR>

let g:vide_runtime_dispatch = {
      \ 'start': function('<SID>Start'),
      \ 'stop': function('<SID>StopWatcher'),
      \ 'render': function('<SID>Render'),
      \ 'activate': function('<SID>Activate'),
      \ 'restart_watch': function('<SID>RestartWatcher'),
      \ 'snapshot_stats': function('<SID>SnapshotStats'),
      \ 'fs_call': function('<SID>FsCall'),
      \ 'open_settings': function('<SID>OpenSettings'),
      \ 'resize': function('<SID>ResizeSidebar'),
      \ 'should_ignore': function('<SID>ShouldIgnore')}

call s:LoadSettings()

augroup vide_runtime
  autocmd!
  autocmd VimEnter * call vide#core#start()
  autocmd VimResized * call vide#core#start() | call vide#ui#resize()
  autocmd FileChangedShell * call <SID>FileChangedShell()
  autocmd BufReadPost * call <SID>RememberPath(expand('<afile>:p'))
  autocmd BufWritePost * call <SID>RememberPath(expand('<afile>:p'))
  autocmd WinClosed * call <SID>MaybeExitAfterEditorClose()
  autocmd VimLeavePre * call vide#core#stop()
  autocmd VimLeavePre * if s:interrupt_timer > 0 | call timer_stop(s:interrupt_timer) | endif
augroup END

" Define highlight groups for conflict and change visualization
highlight default VideConflict ctermfg=Yellow ctermbg=NONE guifg=#E5C07B guibg=NONE gui=bold cterm=bold
highlight default VideRecentChange ctermfg=Cyan ctermbg=NONE guifg=#56B6C2 guibg=NONE
highlight default VideChanged ctermfg=Green ctermbg=NONE guifg=#98C379 guibg=NONE

if v:vim_did_enter
  call s:Start()
endif
