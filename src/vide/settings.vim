" Settings facade.
if exists('*vide#settings#open')
  finish
endif

function! vide#settings#open() abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'open_settings')
    return call(g:vide_runtime_dispatch.open_settings, [])
  endif
endfunction
