" Core public facade.  The implementation keeps state private in vide.vim;
" this facade provides a stable module API for future split-out internals.
if exists('*vide#core#start')
  finish
endif

function! vide#core#start() abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'start')
    return call(g:vide_runtime_dispatch.start, [])
  endif
endfunction

function! vide#core#stop() abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'stop')
    return call(g:vide_runtime_dispatch.stop, [])
  endif
endfunction
