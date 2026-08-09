" Tree public facade; private rendering remains script-local in vide.vim.
if exists('*vide#tree#render')
  finish
endif

function! vide#tree#render() abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'render')
    return call(g:vide_runtime_dispatch.render, [])
  endif
endfunction

function! vide#tree#activate() abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'activate')
    return call(g:vide_runtime_dispatch.activate, [])
  endif
endfunction
