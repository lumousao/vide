" UI facade.
if exists('*vide#ui#resize')
  finish
endif

function! vide#ui#resize() abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'resize')
    return call(g:vide_runtime_dispatch.resize, [])
  endif
endfunction
