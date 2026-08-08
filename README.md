# vide

`vide` is a terminal workspace view built around unmodified Vim.  It opens a
34% project explorer at the left and keeps the rest of the terminal as the
normal Vim editing window.

## Run

```sh
./bin/vide
./bin/vide path/to/file
```

The launcher works when invoked from bash or zsh.  A locally built
`vim-master/src/vim` is preferred; otherwise it uses `vim` from `PATH`. Set
`VIDE_VIM` to use a different Vim executable.

To build the bundled Vim implementation and Linux event watcher, run
`make vim watch`. Building Vim requires the ncurses development package (for
example `ncurses-devel` on Fedora). VIDE uses kernel events and never performs
periodic directory scans.

## Explorer controls

`Enter`, `Space`, Right Arrow, or a mouse click expands a directory or opens a
file. Left Arrow collapses a directory, `Ctrl-L` redraws the tree, and `Tab`
switches between the explorer and Vim. Enter `:q` (or `:q!`) once to leave the
whole workspace. Native `:wq` keeps Vim's current-buffer write semantics and
closes the workspace after the final editor window is gone. The explorer uses
large bold Unicode triangles with an ASCII fallback.

The explorer uses Ctrl shortcuts only: `Ctrl-N` creates a file or directory,
`Ctrl-D` deletes the selected file or directory after confirmation, `Ctrl-R`
renames it, and `Ctrl-P` opens settings. These mappings are local to the left
explorer; the right editor keeps Vim's original keys and `:` commands. The
project root cannot be deleted or renamed, and all requested paths are checked
to remain inside the workspace.

Press `Ctrl-C` once for a force-quit warning. Press it again within three
seconds to exit immediately; after the timeout the warning is dismissed and
the first press has no effect.

## Settings

Focus the explorer and press `Ctrl-P` to open settings. The popup safely
adjusts the sidebar width, per-file snapshot limit, and total snapshot budget.
Values are range-checked before they are applied. Settings are saved to
`~/.config/vide/settings.vim` when writable; otherwise they remain active for
the current session.

When a change is detected, the newest changed file is expanded and highlighted
in the tree, opened in Vim, and moved to its first changed line when a prior
readable version is available. If the active editor has unsaved work, vide
preserves it and opens the changed file in an additional split in the Vim area.

On Linux, `make watch` builds `bin/vide-watch`, which reports writes, creates,
moves, and deletes directly from the kernel. The active backend is shown as
`LIVE` in the explorer status line. If the helper is unavailable or exits,
VIDE shows `OFF` and does not silently start a polling fallback.


Project layout: `bin/` contains the launcher and compiled watcher, `src/`
contains the Vim integration, `lib/` contains watcher source, and `tests/`
contains the event-driven regression suite.
