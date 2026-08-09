" Watch lifecycle facade.
if exists('*vide#watch#restart')
  finish
endif

function! vide#watch#restart() abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'restart_watch')
    return call(g:vide_runtime_dispatch.restart_watch, [])
  endif
endfunction

function! vide#watch#status() abort
  return get(g:, 'vide_watch_backend', 'OFF')
endfunction

function! vide#watch#snapshot_stats() abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'snapshot_stats')
    return call(g:vide_runtime_dispatch.snapshot_stats, [])
  endif
  return {'files': 0, 'bytes': 0, 'budget': 0}
endfunction
