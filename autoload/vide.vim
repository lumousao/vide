" Public autoload namespace marker.  The bundled launcher sources src/vide.vim
" directly, while installations that add the project to 'runtimepath' can use
" the vide#module#... facades from src/vide/.
function! vide#version() abort
  return '0.5.0'
endfunction
