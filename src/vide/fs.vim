" Safe filesystem facade.
if exists('*vide#fs#call')
  finish
endif

function! vide#fs#call(operation, paths) abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'fs_call')
    return call(g:vide_runtime_dispatch.fs_call, [a:operation, a:paths])
  endif
  return 0
endfunction
