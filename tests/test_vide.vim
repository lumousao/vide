set nomore
let s:root = tempname()
call mkdir(s:root . '/nested', 'p')
call writefile(['before', 'keep'], s:root . '/nested/child.txt')
call writefile(['same', 'before', 'same'], s:root . '/unopened.txt')
call writefile(['make before'], s:root . '/Makefile')
call writefile(['odd name'], s:root . '/odd' . "\n" . 'name.txt')
call mkdir(s:root . '/.hidden/deep', 'p')
call writefile(['hidden before'], s:root . '/.hidden/deep/inside.txt')
execute 'cd ' . fnameescape(s:root)
let g:vide_settings = {'sidebar_percent': 34, 'content_limit_kb': 256, 'snapshot_budget_kb': 8192}
execute 'source ' . fnameescape(fnamemodify(expand('<sfile>:p'), ':h:h') . '/src/vide.vim')
set columns=50
doautocmd VimEnter
sleep 1

call assert_match('VIDE', join(getline(1, '$'), "\n"))
call assert_equal('LIVE', g:vide_watch_backend)
call assert_equal(34, g:vide_settings.sidebar_percent)
call assert_equal(8192, g:vide_settings.snapshot_budget_kb)

let s:tree_win = 0
for s:info in getwininfo()
  if bufname(s:info.bufnr) ==# '[vide] Explorer'
    let s:tree_win = s:info.winid
  endif
endfor
call assert_notequal(0, s:tree_win)
call win_gotoid(s:tree_win)
call assert_match('▼ ' . fnamemodify(s:root, ':t'), getline(1))
call assert_true(index(getline(1, '$'), '    odd?name.txt') >= 0)
let s:nested_line = match(getline(1, '$'), '^  ▶ nested$') + 1
call assert_notequal(0, s:nested_line)
call cursor(s:nested_line, 1)
execute "normal \<CR>"
call assert_match('child.txt', join(getline(1, '$'), "\n"))
call assert_equal(2, winnr('$'))
call assert_equal('nofile', &l:buftype)
call assert_equal(0, &l:wrap)
call assert_equal('', maparg('<LeftMouse>', 'n'))
call assert_match('MouseActivate', maparg('<LeftRelease>', 'n'))
call assert_match('Interrupt', maparg('<C-C>', 'n'))
call assert_match('Interrupt', maparg('<C-C>', 'i'))
call assert_notmatch('wqa', execute('cnoreabbrev'))
call assert_equal(0, exists(':VideSettings'))
call assert_equal('', maparg('s', 'n'))
call assert_equal('', maparg('a', 'n'))
call assert_equal('', maparg('d', 'n'))
call assert_equal('', maparg('R', 'n'))
call assert_equal('', maparg('r', 'n'))
call assert_match('CreateNode', maparg('<C-N>', 'n'))
call assert_match('DeleteNode', maparg('<C-D>', 'n'))
call assert_match('RenameNode', maparg('<C-R>', 'n'))
call assert_match('OpenSettings', maparg('<C-P>', 'n'))
call assert_match('Render', maparg('<C-L>', 'n'))
set columns=120
doautocmd VimResized
call assert_equal(40, winwidth(0))

" A file never opened in Vim still has a baseline snapshot for line location.
call writefile(['same', 'after', 'same'], s:root . '/unopened.txt')
sleep 500m
call assert_equal(s:root . '/unopened.txt', expand('%:p'))
call assert_equal(2, line('.'))

" Tree selection follows an event-driven automatic open, including root files.
call writefile(['root makefile changed'], s:root . '/Makefile')
sleep 500m
call assert_equal(s:root . '/Makefile', expand('%:p'))
call win_gotoid(s:tree_win)
call assert_match('Makefile$', getline('.'))

" A new directory is watched as an event, not through a timed rescan.
call mkdir(s:root . '/created/deep', 'p')
call writefile(['new directory event'], s:root . '/created/deep/inside.txt')
sleep 700m
call assert_equal(s:root . '/created/deep/inside.txt', expand('%:p'))
call win_gotoid(s:tree_win)
call assert_match('inside.txt$', getline('.'))
call assert_match('created', join(getline(1, '$'), "\n"))
call assert_true(len(filter(getmatches(), 'v:val.group ==# "VideChanged"')) > 0)

" Deleting and recreating a directory must clear all old path state.
call mkdir(s:root . '/cycle')
call writefile(['cycle before'], s:root . '/cycle/file.txt')
sleep 500m
call delete(s:root . '/cycle', 'rf')
sleep 500m
call assert_false(isdirectory(s:root . '/cycle'))
call mkdir(s:root . '/cycle')
call writefile(['cycle after'], s:root . '/cycle/file.txt')
sleep 700m
call assert_equal(s:root . '/cycle/file.txt', expand('%:p'))

" Moving a directory away and back establishes fresh state at the new path.
call mkdir(s:root . '/move-src')
call writefile(['move before'], s:root . '/move-src/item.txt')
sleep 400m
call rename(s:root . '/move-src', s:root . '/move-dst')
sleep 500m
call rename(s:root . '/move-dst', s:root . '/move-src')
call writefile(['move after'], s:root . '/move-src/item.txt')
sleep 700m
call assert_equal(s:root . '/move-src/item.txt', expand('%:p'))

" A WRITE event remains valid when size and mtime are unchanged.
call writefile(['same-size-a'], s:root . '/same-size.txt')
sleep 300m
let s:mtime = getftime(s:root . '/same-size.txt')
call writefile(['same-size-b'], s:root . '/same-size.txt')
if exists('*setftime')
  call setftime(s:mtime, s:root . '/same-size.txt')
endif
sleep 700m
call assert_equal(s:root . '/same-size.txt', expand('%:p'))
call assert_equal('same-size-b', getline(1))

" A lexical child path through a link must be rejected before filesystem writes.
call system('ln -s /tmp ' . shellescape(s:root . '/link'))
let s:script_id = matchstr(execute('function /SafeChildPath'), '<SNR>\zs\d\+\ze_')
execute 'call assert_equal('''', <SNR>' . s:script_id . '_SafeChildPath(' . string(s:root) . ', ''link/escape.txt''))'

" Secure file operations use the descriptor-based helper.
let s:fs_script_id = s:script_id
execute 'call assert_true(<SNR>' . s:fs_script_id . '_FsCall(''create-dir'', [''managed'']))'
execute 'call assert_true(<SNR>' . s:fs_script_id . '_FsCall(''create-file'', [''managed/note.txt'']))'
call assert_true(filereadable(s:root . '/managed/note.txt'))
execute 'call assert_true(<SNR>' . s:fs_script_id . '_FsCall(''rename'', [''managed/note.txt'', ''managed/renamed.txt'']))'
call assert_true(filereadable(s:root . '/managed/renamed.txt'))
execute 'call assert_true(<SNR>' . s:fs_script_id . '_FsCall(''delete'', [''managed'']))'
call assert_false(isdirectory(s:root . '/managed'))

if len(v:errors)
  cquit
endif
qa!
