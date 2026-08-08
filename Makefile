.PHONY: vim watch test clean

VIM_BIN := $(shell test -x vim-master/src/vim && echo vim-master/src/vim || echo vim)
WATCHER := bin/vide-watch
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror

vim:
	@printf '%s\n' '#include <curses.h>' 'int main(void) { return 0; }' | $${CC:-cc} -x c - -lncurses -fsyntax-only >/dev/null 2>&1 || { echo 'vide: building bundled Vim requires the ncurses development package (for example ncurses-devel).'; exit 1; }
	$(MAKE) -C vim-master/src

watch: $(WATCHER)

$(WATCHER): lib/vide-watch.c
	$(CC) $(CFLAGS) -std=c11 -o $@ $<

test: $(WATCHER)
	bash -n bin/vide
	@$(VIM_BIN) --version | grep -q '+mouse'
	@$(VIM_BIN) --version | grep -q '+timers'
	VIMRUNTIME=$(CURDIR)/vim-master/runtime $(VIM_BIN) -Nu NONE -n -i NONE -es -S tests/test_vide.vim

clean:
	$(MAKE) -C vim-master/src clean
	$(RM) $(WATCHER)
