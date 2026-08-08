" vide: a small project explorer hosted inside unmodified Vim.
if exists('g:loaded_vide_runtime')
  finish
endif
let g:loaded_vide_runtime = 1

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
let s:watch = {'signatures': {}, 'hashes': {}, 'contents': {}}
let s:content_limit = 262144
let s:snapshot_budget = 8388608
let s:snapshot_bytes = 0
let s:snapshot_order = []
let s:changed_path = ''
let s:changed_line = 1
let s:selected_path = ''
let s:watch_job = 0
let s:watcher_stopping = 0
let s:stopped_watch_jobs = {}
let s:watch_buffer = ''
let s:pending_events = []
let s:initializing = 0
let s:watcher_path = get(g:, 'vide_watcher', expand('<sfile>:p:h:h') . '/bin/vide-watch')
let s:notice = ''
let g:vide_notice = ''
let s:interrupt_armed = 0
let s:interrupt_timer = -1
let s:interrupt_popup = -1
let s:settings_popup = -1
let s:settings = {
      \ 'sidebar_percent': 34,
      \ 'content_limit_kb': 256,
      \ 'snapshot_budget_kb': 8192}
let g:vide_watch_backend = 'OFF'

highlight default VideChanged cterm=bold ctermfg=Black ctermbg=DarkYellow gui=bold guifg=Black guibg=DarkYellow
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
  return isdirectory(a:path) && getftype(a:path) !=# 'link'
endfunction

function! s:NormalizePath(path) abort
  return substitute(fnamemodify(a:path, ':p'), '/\+$', '', '')
endfunction

function! s:DisplayName(path) abort
  return substitute(fnamemodify(a:path, ':t'), '[[:cntrl:]]', '?', 'g')
endfunction

function! s:TreeMarker(path) abort
  if &encoding =~? 'utf-8'
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
  if has_key(s:settings, 'poll_ms')
    call remove(s:settings, 'poll_ms')
  endif
  if has_key(s:settings, 'watch_mode')
    call remove(s:settings, 'watch_mode')
  endif
  let s:settings.sidebar_percent = min([60, max([20, str2nr(string(get(s:settings, 'sidebar_percent', 34)))])])
  let s:settings.content_limit_kb = min([4096, max([64, str2nr(string(get(s:settings, 'content_limit_kb', 256)))])])
  let s:settings.snapshot_budget_kb = min([65536, max([1024, str2nr(string(get(s:settings, 'snapshot_budget_kb', 8192)))])])
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

function! s:PruneWatch(path) abort
  let l:path = s:NormalizePath(a:path)
  for l:store in [s:watch.signatures, s:watch.hashes, s:watch.contents, get(s:watch, 'snapshot_sizes', {})]
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
  if empty(l:name) || l:name =~# '^/' || l:name =~# '[[:cntrl:]]'
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

function! s:Children(path) abort
  let l:entries = globpath(a:path, '*', 0, 1) + globpath(a:path, '.*', 0, 1)
  let l:result = []
  for l:entry in l:entries
    let l:normalized = s:NormalizePath(l:entry)
    let l:name = fnamemodify(l:entry, ':t')
    if l:name !=# '.' && l:name !=# '..' && l:normalized !=# s:root && l:normalized !=# fnamemodify(s:root, ':h') && !s:IsTransient(l:entry)
      call add(l:result, l:normalized)
    endif
  endfor
  return sort(l:result, function('s:ComparePaths'))
endfunction

function! s:AddNode(path, depth, lines, nodes) abort
  let l:is_dir = s:IsDirectory(a:path)
  let l:name = a:path ==# s:root ? s:DisplayName(s:root) : s:DisplayName(a:path)
  let l:indent = repeat('  ', a:depth)
  if l:is_dir
    let l:prefix = l:indent . s:TreeMarker(a:path) . ' '
    call add(a:lines, l:prefix . s:FitTreeLabel(l:name, winwidth(0) - strdisplaywidth(l:prefix)))
  else
    let l:prefix = l:indent . '  '
    call add(a:lines, l:prefix . s:FitTreeLabel(l:name, winwidth(0) - strdisplaywidth(l:prefix)))
  endif
  call add(a:nodes, {'path': a:path, 'dir': l:is_dir, 'line': len(a:lines)})

  if l:is_dir && has_key(s:expanded, a:path)
    for l:child in s:Children(a:path)
      call s:AddNode(l:child, a:depth + 1, a:lines, a:nodes)
    endfor
  endif
endfunction

function! s:ApplyChangedHighlight() abort
  if exists('b:vide_change_match') && b:vide_change_match > 0
    silent! call matchdelete(b:vide_change_match)
  endif
  let b:vide_change_match = -1
  if empty(s:changed_path)
    return
  endif
  for l:node in get(b:, 'vide_nodes', [])
    if l:node.path ==# s:changed_path
      let b:vide_change_match = matchaddpos('VideChanged', [[l:node.line, 1, -1]], 20)
      return
    endif
  endfor
endfunction

function! s:Render() abort
  if !bufexists(s:tree_buf)
    return
  endif
  let l:origin_win = win_getid()
  if !win_gotoid(s:tree_win)
    return
  endif
  let l:lines = []
  let l:nodes = []
  call s:AddNode(s:root, 0, l:lines, l:nodes)
  setlocal modifiable
  silent %delete _
  call setline(1, l:lines)
  if line('$') > len(l:lines)
    call deletebufline('%', len(l:lines) + 1, '$')
  endif
  let b:vide_nodes = l:nodes
  setlocal nomodifiable
  call s:ApplyChangedHighlight()
  if !empty(s:selected_path)
    for l:node in l:nodes
      if l:node.path ==# s:selected_path
        call cursor(l:node.line, 1)
        break
      endif
    endfor
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

function! s:OpenFile(path, line) abort
  let l:winid = s:EditorWindow()
  if l:winid < 0 || !win_gotoid(l:winid)
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
    call s:TreeError('path must stay inside the project and contain no control characters')
    return
  endif
  if filereadable(l:path) || isdirectory(l:path) || getftype(l:path) !=# ''
    call s:TreeError('target already exists')
    return
  endif
  let l:kind = confirm('Create ' . fnamemodify(l:path, ':t') . ' as:', "&File\n&Directory\n&Cancel", 3)
  if l:kind == 3 || l:kind == 0
    return
  endif
  try
    if empty(s:SafeChildPath(l:parent, l:name))
      call s:TreeError('path changed or now contains a symbolic link')
      return
    endif
    if l:kind == 1
      call mkdir(fnamemodify(l:path, ':h'), 'p')
      call writefile([], l:path)
      call s:RememberPath(l:path)
    else
      call mkdir(l:path, 'p')
    endif
  catch /^Vim\%((\a\+)\)\=:E/
    call s:TreeError('could not create target')
    return
  endtry
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
  if delete(l:node.path, l:node.dir ? 'rf' : '') != 0
    call s:TreeError('delete failed')
    return
  endif
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
  if getftype(l:new) !=# ''
    call s:TreeError('target already exists')
    return
  endif
  if empty(s:SafeChildPath(fnamemodify(l:old, ':h'), l:name))
    call s:TreeError('path changed or now contains a symbolic link')
    return
  endif
  if rename(l:old, l:new) != 0
    call s:TreeError('rename failed')
    return
  endif
  call s:RemapPaths(s:expanded, l:old, l:new)
  call s:RemapPaths(s:watch.signatures, l:old, l:new)
  call s:RemapPaths(s:watch.hashes, l:old, l:new)
  call s:RemapPaths(s:watch.contents, l:old, l:new)
  call s:RemapPaths(s:watch.snapshot_sizes, l:old, l:new)
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
  return a:path !~# '/\.git\%(/\|$\)' && !s:IsTransient(a:path) && filereadable(a:path)
endfunction

function! s:ReadContents(path) abort
  if getfsize(a:path) < 0 || getfsize(a:path) > s:content_limit
    return []
  endif
  try
    return readfile(a:path)
  catch /^Vim\%((\a\+)\)\=:E/
    return []
  endtry
endfunction

function! s:CollectFiles(path, files) abort
  if a:path =~# '/\.git\%(/\|$\)'
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

function! s:ContentSignature(path) abort
  let l:size = getfsize(a:path)
  if l:size < 0 || l:size > s:content_limit
    return ''
  endif
  try
    return sha256(join(readfile(a:path, 'b'), "\n"))
  catch /^Vim\%((\a\+)\)\=:E/
    return ''
  endtry
endfunction

function! s:CollectWatch() abort
  " This is the one startup baseline. All later updates arrive as OS events.
  let l:files = []
  let l:signatures = {}
  let l:hashes = {}
  let l:contents = {}
  let l:sizes = {}
  let l:bytes = 0
  call s:CollectFiles(s:root, l:files)
  for l:path in l:files
    if !s:CanWatch(l:path)
      continue
    endif
    let l:size = getfsize(l:path)
    let l:signatures[l:path] = getftime(l:path) . ':' . l:size
    if l:size >= 0 && l:size <= s:content_limit && l:bytes + l:size <= s:snapshot_budget
      let l:hashes[l:path] = s:ContentSignature(l:path)
      let l:contents[l:path] = s:ReadContents(l:path)
      let l:sizes[l:path] = l:size
      call add(s:snapshot_order, l:path)
      let l:bytes += l:size
    endif
  endfor
  let s:snapshot_bytes = l:bytes
  return {'signatures': l:signatures, 'hashes': l:hashes, 'contents': l:contents, 'snapshot_sizes': l:sizes}
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
  if getfsize(a:path) >= 0 && getfsize(a:path) <= s:content_limit
    let s:watch.contents[a:path] = a:contents
    let s:watch.snapshot_sizes[a:path] = getfsize(a:path)
    let s:snapshot_bytes += getfsize(a:path)
    call add(s:snapshot_order, a:path)
  else
    if has_key(s:watch.contents, a:path)
      call remove(s:watch.contents, a:path)
    endif
  endif
  while s:snapshot_bytes > s:snapshot_budget && !empty(s:watch.contents)
    let l:victim = remove(s:snapshot_order, 0)
    let s:snapshot_bytes -= get(s:watch.snapshot_sizes, l:victim, 0)
    call remove(s:watch.snapshot_sizes, l:victim)
    call remove(s:watch.contents, l:victim)
  endwhile
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

function! s:RememberPath(path) abort
  let l:path = s:NormalizePath(a:path)
  if !s:CanWatch(l:path)
    return
  endif
  let s:watch.signatures[l:path] = getftime(l:path) . ':' . getfsize(l:path)
  let s:watch.hashes[l:path] = s:ContentSignature(l:path)
  call s:StoreSnapshot(l:path, s:ReadContents(l:path))
endfunction

function! s:HandleChangedPath(path) abort
  let l:path = s:NormalizePath(a:path)
  if empty(l:path) || stridx(l:path, s:root . '/') !=# 0 || l:path =~# '/\.git\%(/\|$\)'
    return
  endif
  if s:IsDirectory(l:path)
    call s:Render()
    return
  endif
  if !filereadable(l:path) || s:IsTransient(l:path)
    if s:selected_path ==# l:path
      let s:selected_path = ''
    endif
    if has_key(s:watch.signatures, l:path)
      call remove(s:watch.signatures, l:path)
    endif
    if has_key(s:watch.hashes, l:path)
      call remove(s:watch.hashes, l:path)
    endif
    if has_key(s:watch.contents, l:path)
      call remove(s:watch.contents, l:path)
    endif
    if has_key(get(s:watch, 'snapshot_sizes', {}), l:path)
      let s:snapshot_bytes -= s:watch.snapshot_sizes[l:path]
      call remove(s:watch.snapshot_sizes, l:path)
    endif
    call filter(s:snapshot_order, 'v:val !=# l:path')
    call s:Render()
    return
  endif

  let l:signature = getftime(l:path) . ':' . getfsize(l:path)
  let l:hash = s:ContentSignature(l:path)
  if get(s:watch.signatures, l:path, '') ==# l:signature
        \ && get(s:watch.hashes, l:path, '') ==# l:hash
    return
  endif
  let l:before = get(s:watch.contents, l:path, [])
  let l:after = s:ReadContents(l:path)
  let s:watch.signatures[l:path] = l:signature
  let s:watch.hashes[l:path] = l:hash
  call s:StoreSnapshot(l:path, l:after)
  let s:changed_path = l:path
  let s:selected_path = l:path
  let s:changed_line = s:FirstChangedLine(l:before, l:after)
  call s:Reveal(l:path)
  call s:Render()
  call s:SelectPath(l:path)
  call s:OpenFile(l:path, s:changed_line)
endfunction

function! s:WatchEvent(channel, message) abort
  if s:watching || s:watcher_stopping || type(a:message) != type('') || empty(a:message)
    return
  endif
  let s:watching = 1
  try
    let s:watch_buffer .= a:message
    while !empty(s:watch_buffer)
      if s:watch_buffer[0] ==# 'E'
        let l:newline = stridx(s:watch_buffer, "\n")
        if l:newline < 0
          break
        endif
        call s:TreeError('watcher ' . strpart(s:watch_buffer, 1, l:newline - 1))
        let s:watch_buffer = strpart(s:watch_buffer, l:newline + 1)
        let g:vide_watch_backend = 'OFF'
        continue
      endif
      if s:watch_buffer[0] !=# 'P'
        let s:watch_buffer = strpart(s:watch_buffer, 1)
        continue
      endif
      let l:separator = stridx(s:watch_buffer, ':')
      if l:separator < 2
        break
      endif
      let l:length_text = strpart(s:watch_buffer, 1, l:separator - 1)
      if l:length_text !~# '^\d\+$'
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
      if s:initializing
        call add(s:pending_events, l:path)
      else
        call s:HandleChangedPath(l:path)
      endif
    endwhile
  finally
    let s:watching = 0
  endtry
endfunction

function! s:WatchError(channel, message) abort
  if !empty(a:message)
    call s:TreeError(substitute(a:message, '\n\+$', '', ''))
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
    call s:TreeError('watcher stopped; automatic tracking is off')
  endif
endfunction

function! s:StartWatcher() abort
  let s:watcher_stopping = 0
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
  let l:events = s:pending_events
  let s:pending_events = []
  for l:path in l:events
    call s:HandleChangedPath(l:path)
  endfor
endfunction

function! s:CloseSettings() abort
  if s:settings_popup > 0
    silent! call popup_close(s:settings_popup)
  endif
  let s:settings_popup = -1
endfunction

function! s:ApplySetting(index, value) abort
  if a:value !~# '^\d\+$'
    call s:TreeError('enter a whole number')
    return
  endif
  if a:index == 1
    let s:settings.sidebar_percent = str2nr(a:value)
  elseif a:index == 2
    let s:settings.content_limit_kb = str2nr(a:value)
  elseif a:index == 3
    let s:settings.snapshot_budget_kb = str2nr(a:value)
  endif
  call s:ValidateSettings()
  call s:SaveSettings()
  call s:ResizeSidebar()
  call s:Render()
endfunction

function! s:EditSetting(index) abort
  if a:index < 1 || a:index > 3
    return
  endif
  call s:CloseSettings()
  if a:index == 1
    let l:value = input('Sidebar width (20-60%) [' . s:settings.sidebar_percent . ']: ')
  elseif a:index == 2
    let l:value = input('Per-file snapshot limit (64-4096 KB) [' . s:settings.content_limit_kb . ']: ')
  else
    let l:value = input('Snapshot budget (1024-65536 KB) [' . s:settings.snapshot_budget_kb . ']: ')
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
    let l:choice = inputlist(['VIDE SETTINGS', '1. Sidebar width: ' . s:settings.sidebar_percent . '%', '2. Per-file snapshot: ' . s:settings.content_limit_kb . ' KB', '3. Snapshot budget: ' . s:settings.snapshot_budget_kb . ' KB'])
    if l:choice >= 1 && l:choice <= 3
      let l:value = input('New value: ')
      if !empty(l:value)
        call s:ApplySetting(l:choice, l:value)
      endif
    endif
    return
  endif
  let l:width = min([50, max([32, &columns - 8])])
  highlight PmenuSel cterm=bold ctermfg=Black ctermbg=DarkCyan gui=bold guifg=Black guibg=DarkCyan
  let l:items = [
        \ 'Sidebar width: ' . s:settings.sidebar_percent . '%',
        \ 'Per-file snapshot: ' . s:settings.content_limit_kb . ' KB',
        \ 'Snapshot budget: ' . s:settings.snapshot_budget_kb . ' KB']
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

function! s:SetupTreeBuffer() abort
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap nonumber norelativenumber
  setlocal cursorline cursorlineopt=line signcolumn=no foldcolumn=0 colorcolumn=
  setlocal winfixwidth
  setlocal winhighlight=Normal:VideExplorerNormal,CursorLine:VideExplorerCursor,StatusLine:VideStatusLine,StatusLineNC:VideStatusLineNC,VertSplit:VideDivider
  setlocal statusline=%#VideStatus#\ VIDE\ %*%<%=%#VideStatusMeta#\ %{get(g:,\ 'vide_watch_backend',\ 'OFF')}\ %{get(g:,\ 'vide_notice',\ '')}\ \ %l/%L\ 
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

function! s:StyleEditorWindow() abort
  if win_id2win(s:editor_win) > 0
    call win_execute(s:editor_win, 'setlocal winhighlight=StatusLine:VideStatusLine,StatusLineNC:VideStatusLineNC,VertSplit:VideDivider')
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
  if winwidth(0) < 34
    " Keep every splash line inside a narrow editor split.
    call extend(l:lines, [s:Centered('Vim IDE'), s:Centered('Loading...')])
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
    call extend(l:lines, ['', s:Centered('Vim Development Environment'), s:Centered('Loading workspace...')])
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
  syntax match VideSplashText 'VIDE\|Vim Development Environment\|Loading workspace...'
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
  topleft vertical new
  let s:tree_win = win_getid()
  let s:tree_buf = bufnr('%')
  call s:SetupTreeBuffer()
  call s:ResizeSidebar()
  call s:Render()
  call s:StyleEditorWindow()
  call win_gotoid(s:editor_win)
  call s:ShowSplash()
  let s:snapshot_order = []
  let s:initializing = 1
  call s:StartWatcher()
  let s:watch = s:CollectWatch()
  let s:initializing = 0
  call s:DrainPendingEvents()
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

call s:LoadSettings()

augroup vide_runtime
  autocmd!
  autocmd VimEnter * call <SID>Start()
  autocmd VimResized * call <SID>Start() | call <SID>ResizeSidebar()
  autocmd BufReadPost * call <SID>RememberPath(expand('<afile>:p'))
  autocmd BufWritePost * call <SID>RememberPath(expand('<afile>:p'))
  autocmd WinClosed * call <SID>MaybeExitAfterEditorClose()
  autocmd VimLeavePre * call <SID>StopWatcher()
  autocmd VimLeavePre * if s:interrupt_timer > 0 | call timer_stop(s:interrupt_timer) | endif
augroup END

if v:vim_did_enter
  call s:Start()
endif
