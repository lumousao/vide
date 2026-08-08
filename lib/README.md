# Library boundary

`src/vide.vim` is the Vim runtime entrypoint. This directory is reserved for
small, independently testable helpers when the runtime grows. `vide-watch.c`
is the Linux inotify helper used by the Vim job channel; it maintains
recursive watches from filesystem events and never runs a periodic scan.
