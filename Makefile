.PHONY: vim watch fs all test lint benchmark security clean

VIM_BIN := $(shell test -x vim-master/src/vim && echo vim-master/src/vim || echo vim)
WATCHER := bin/vide-watch
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
WATCH_SRC := lib/vide-watch-main.c lib/vide-watch-linux.c lib/vide-watch.c lib/vide-watch-hashmap.c lib/vide-watch-hashmap.h
else ifeq ($(UNAME_S),Darwin)
WATCH_SRC := lib/vide-watch-bsd.c lib/vide-watch.h
else ifeq ($(UNAME_S),FreeBSD)
WATCH_SRC := lib/vide-watch-bsd.c lib/vide-watch.h
else ifeq ($(OS),Windows_NT)
WATCH_SRC := lib/vide-watch-windows.c lib/vide-watch.h
else
WATCH_SRC := lib/vide-watch-bsd.c lib/vide-watch.h
endif
FS_HELPER := bin/vide-fs
ifeq ($(OS),Windows_NT)
FS_SRC := lib/vide-fs-windows.c
else
FS_SRC := lib/vide-fs.c
endif
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror

vim:
	@printf '%s\n' '#include <curses.h>' 'int main(void) { return 0; }' | $${CC:-cc} -x c - -lncurses -fsyntax-only >/dev/null 2>&1 || { echo 'vide: building bundled Vim requires the ncurses development package (for example ncurses-devel).'; exit 1; }
	$(MAKE) -C vim-master/src

all: vim watch fs

watch: $(WATCHER)

fs: $(FS_HELPER)

$(WATCHER): $(WATCH_SRC)
	$(CC) $(CFLAGS) -std=c11 -o $@ $(filter %.c,$(WATCH_SRC))

$(FS_HELPER): $(FS_SRC)
	$(CC) $(CFLAGS) -std=c11 -o $@ $(FS_SRC)

test: $(WATCHER) $(FS_HELPER)
	bash -n bin/vide
	@bash tests/test_watch.sh
	@bash tests/test_fs.sh
	@bash tests/test_races.sh
	@VIM_BIN=$(VIM_BIN) bash tests/test_vim_commands.sh
	@$(VIM_BIN) --version | grep -q '+mouse' || { echo 'vide: Vim +mouse is required for explorer clicks'; exit 1; }
	@$(VIM_BIN) --version | grep -q '+timers' || { echo 'vide: Vim +timers is required for Ctrl-C handling'; exit 1; }
	@$(VIM_BIN) --version | grep -q '+channel' || { echo 'vide: Vim +channel is required for watcher events'; exit 1; }
	@$(VIM_BIN) --version | grep -q '+job' || { echo 'vide: Vim +job is required for watcher events'; exit 1; }
	VIMRUNTIME=$(CURDIR)/vim-master/runtime $(VIM_BIN) -Nu NONE -n -i NONE -es -S tests/test_vide.vim
	VIMRUNTIME=$(CURDIR)/vim-master/runtime $(VIM_BIN) -Nu NONE -n -i NONE -es -S tests/test_errors.vim
	VIMRUNTIME=$(CURDIR)/vim-master/runtime $(VIM_BIN) -Nu NONE -n -i NONE -es -S tests/test_large_files.vim
	VIMRUNTIME=$(CURDIR)/vim-master/runtime $(VIM_BIN) -Nu NONE -n -i NONE -es -S tests/test_concurrent.vim
	VIMRUNTIME=$(CURDIR)/vim-master/runtime $(VIM_BIN) -Nu NONE -n -i NONE -es -S tests/test_modules.vim
	VIMRUNTIME=$(CURDIR)/vim-master/runtime $(VIM_BIN) -Nu NONE -n -i NONE -es -S tests/test_ignore.vim
	VIMRUNTIME=$(CURDIR)/vim-master/runtime $(VIM_BIN) -Nu NONE -n -i NONE -es -S tests/test_snapshot_budget.vim

lint:
	@! rg -n 'WatchTick|poll_ms|inotifywait' src lib bin tests
	@$(CC) $(CFLAGS) -std=c11 -fsyntax-only lib/vide-fs.c
	@$(CC) $(CFLAGS) -std=c11 -fsyntax-only lib/vide-watch.c lib/vide-watch-hashmap.c
	@if command -v vint >/dev/null 2>&1; then vint src/vide.vim src/vide/*.vim; else echo 'vint not installed; Vimscript lint skipped'; fi
	@if command -v clang-tidy >/dev/null 2>&1; then clang-tidy lib/vide-fs.c lib/vide-watch.c lib/vide-watch-hashmap.c -- -std=c11; else echo 'clang-tidy not installed; C lint skipped'; fi

benchmark: $(WATCHER)
	@bash tests/benchmark.sh
	@bash tests/event_latency.sh

security: $(FS_HELPER) $(WATCHER)
	@bash tests/manual_security_tests.sh

clean:
	$(MAKE) -C vim-master/src clean
	$(RM) $(WATCHER) $(FS_HELPER)
