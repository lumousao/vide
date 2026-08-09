# Library boundary

`src/vide.vim` is the Vim runtime entrypoint. This directory is reserved for
small, independently testable helpers when the runtime grows. `vide-watch.c`
is the Linux inotify helper used by the Vim job channel; it maintains
recursive watches from filesystem events and never runs a periodic scan.
Its stdout uses length-framed records of the form `P<event><bytes>:<path>`;
events are `WRITE`, `CREATE`, `MOVE_IN`, `MOVE_OUT`, `DELETE`, `DIR`, and
`ERROR`. Error payloads include the failing directory and the operating-system
reason before the helper exits.

Watch descriptors are indexed by an open-addressing hash table, so event
dispatch remains constant-time as the project grows. Platform-specific source
files provide the kqueue and Windows integration points selected by the
Makefile.
