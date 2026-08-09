#include "vide-watch.h"

#if defined(__APPLE__) || defined(__FreeBSD__)
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <unistd.h>

struct bsd_watch { int fd; char *path; };
static struct bsd_watch *watches;
static size_t watch_count;

static void emit_record(const char *kind, const char *path)
{
    size_t n = strlen(path);
    printf("P%s%zu:", kind, n);
    fwrite(path, 1, n, stdout);
    fflush(stdout);
}

static void emit_error(const char *root, const char *reason)
{
    char detail[PATH_MAX + 128];
    int n = snprintf(detail, sizeof(detail), "%s: %s", root, reason);
    if (n > 0) {
        printf("PERROR%d:", n);
        fwrite(detail, 1, (size_t)n, stdout);
        fflush(stdout);
    }
}

static int add_directory(int kq, const char *path)
{
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    struct kevent change;
    if (fd < 0)
        return -1;
    watches = realloc(watches, (watch_count + 1) * sizeof(*watches));
    if (!watches) {
        close(fd);
        return -1;
    }
    watches[watch_count].fd = fd;
    watches[watch_count].path = strdup(path);
    if (!watches[watch_count].path) {
        close(fd);
        return -1;
    }
    EV_SET(&change, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_DELETE | NOTE_RENAME, 0, watches[watch_count].path);
    if (kevent(kq, &change, 1, NULL, 0, NULL) < 0)
        return -1;
    ++watch_count;
    return 0;
}

static int add_tree(int kq, const char *root)
{
    char *paths[] = {(char *)root, NULL};
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    FTSENT *entry;
    if (!fts)
        return -1;
    while ((entry = fts_read(fts)) != NULL) {
        if (entry->fts_info == FTS_D)
            add_directory(kq, entry->fts_path);
        else if (entry->fts_info == FTS_DNR)
            emit_error(entry->fts_path, "directory is not readable");
    }
    fts_close(fts);
    return watch_count ? 0 : -1;
}

int main(int argc, char **argv)
{
    int kq;
    struct kevent event;
    if (argc != 2) {
        fprintf(stderr, "usage: vide-watch PROJECT_ROOT\n");
        return 2;
    }
    kq = kqueue();
    if (kq < 0 || add_tree(kq, argv[1]) < 0) {
        emit_error(argv[1], strerror(errno));
        return 2;
    }
    for (;;) {
        if (kevent(kq, NULL, 0, &event, 1, NULL) < 0) {
            if (errno == EINTR) continue;
            emit_error(argv[1], strerror(errno));
            return 2;
        }
        if (event.udata && (event.fflags & (NOTE_DELETE | NOTE_RENAME))) {
            const char *path = event.udata;
            if (!strcmp(path, argv[1])) {
                emit_error(argv[1], "ROOT_LOST: project root was removed or moved");
                return 2;
            }
            emit_record("DELETE", path);
        } else if (event.udata) {
            emit_record("DIR", (const char *)event.udata);
        }
    }
}
#else
int main(void) { return 2; }
#endif
