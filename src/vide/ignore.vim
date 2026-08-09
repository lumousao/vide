" Ignore-pattern facade.
if exists('*vide#ignore#should_ignore')
  finish
endif

function! vide#ignore#patterns() abort
  return get(g:, 'vide_ignore_patterns', [])
endfunction

function! vide#ignore#should_ignore(path) abort
  if exists('g:vide_runtime_dispatch') && has_key(g:vide_runtime_dispatch, 'should_ignore')
    return call(g:vide_runtime_dispatch.should_ignore, [a:path])
  endif
  return 0
endfunction
