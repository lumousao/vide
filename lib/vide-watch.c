#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

#include "vide-watch-hashmap.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

struct watch_entry {
    int wd;
    char *path;
};

static int notify_fd = -1;
static struct watch_entry *entries;
static size_t entry_count;
static size_t entry_capacity;
static char *project_root;
static int *stale_wds;
static size_t stale_count;
static size_t stale_capacity;
static struct vide_wd_map wd_map;

static void die(const char *message)
{
    fprintf(stderr, "vide-watch: %s: %s\n", message, strerror(errno));
    exit(1);
}

static int is_real_dir(const char *path)
{
    struct stat st;
    return lstat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int ignored_directory(const char *path)
{
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return !strcmp(base, ".git") || !strcmp(base, "node_modules") ||
           !strcmp(base, "__pycache__");
}

static void emit_record(const char *type, const char *path)
{
    size_t length = strlen(path);
    printf("P%s%zu:", type, length);
    fwrite(path, 1, length, stdout);
    fflush(stdout);
}

static void emit_error(const char *path, const char *message)
{
    char detail[PATH_MAX + 256];
    size_t length;
    if (path && *path)
        snprintf(detail, sizeof(detail), "%s: %s", path, message);
    else
        snprintf(detail, sizeof(detail), "%s", message);
    length = strlen(detail);
    printf("PERROR%zu:", length);
    fwrite(detail, 1, length, stdout);
    fflush(stdout);
}

static ssize_t find_entry(int wd)
{
    size_t index;
    return vide_wd_map_get(&wd_map, wd, &index) ? (ssize_t)index : -1;
}

static void mark_stale(int wd)
{
    if (stale_count == stale_capacity) {
        size_t next = stale_capacity ? stale_capacity * 2 : 32;
        int *grown = realloc(stale_wds, next * sizeof(*stale_wds));
        if (!grown)
            die("out of memory");
        stale_wds = grown;
        stale_capacity = next;
    }
    stale_wds[stale_count++] = wd;
}

static int consume_stale(int wd)
{
    size_t i;
    for (i = 0; i < stale_count; ++i) {
        if (stale_wds[i] == wd) {
            stale_wds[i] = stale_wds[--stale_count];
            return 1;
        }
    }
    return 0;
}

static void remember_watch(int wd, const char *path)
{
    if (entry_count == entry_capacity) {
        size_t next = entry_capacity ? entry_capacity * 2 : 64;
        struct watch_entry *grown = realloc(entries, next * sizeof(*entries));
        if (!grown)
            die("out of memory");
        entries = grown;
        entry_capacity = next;
    }
    entries[entry_count].wd = wd;
    entries[entry_count].path = strdup(path);
    if (!entries[entry_count].path)
        die("out of memory");
    if (vide_wd_map_set(&wd_map, wd, entry_count) < 0)
        die("cannot grow watch descriptor table");
    ++entry_count;
}

static void forget_watch(int wd)
{
    ssize_t index = find_entry(wd);
    if (index < 0)
        return;
    vide_wd_map_remove(&wd_map, wd);
    free(entries[index].path);
    entries[index] = entries[entry_count - 1];
    --entry_count;
    if ((size_t)index < entry_count &&
        vide_wd_map_set(&wd_map, entries[index].wd, (size_t)index) < 0)
        die("cannot update watch descriptor table");
}

static void forget_tree(const char *path)
{
    size_t i = 0;
    size_t length = strlen(path);
    while (i < entry_count) {
        if (!strcmp(entries[i].path, path) ||
            (!strncmp(entries[i].path, path, length) &&
             entries[i].path[length] == '/')) {
            int wd = entries[i].wd;
            inotify_rm_watch(notify_fd, wd);
            mark_stale(wd);
            forget_watch(wd);
            continue;
        }
        ++i;
    }
}

static void add_tree(const char *path, int announce_files);

static int add_directory_watch(const char *path)
{
    const uint32_t mask = IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE |
                          IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF |
                          IN_ATTRIB;
    int wd = inotify_add_watch(notify_fd, path, mask);
    if (wd < 0) {
        int saved = errno;
        if (saved == ENOENT || saved == ENOTDIR) {
            return 0;
        }
        if (saved == EACCES || saved == ENOSPC || saved == EMFILE || saved == ENFILE) {
            char detail[256];
            snprintf(detail, sizeof(detail), "inotify_add_watch failed: %s", strerror(saved));
            errno = saved;
            emit_error(path, detail);
            exit(2);
        }
        {
            char detail[256];
            snprintf(detail, sizeof(detail), "cannot add directory watch: %s", strerror(saved));
            errno = saved;
            emit_error(path, detail);
        }
        exit(2);
    }
    ssize_t index = find_entry(wd);
    if (index < 0) {
        remember_watch(wd, path);
    } else if (strcmp(entries[index].path, path)) {
        char *updated = strdup(path);
        if (!updated)
            die("out of memory");
        free(entries[index].path);
        entries[index].path = updated;
    }
    return 0;
}

static void add_tree(const char *path, int announce_files)
{
    DIR *dir;
    struct dirent *item;
    char child[PATH_MAX];
    if (strcmp(path, project_root) && ignored_directory(path))
        return;
    if (!is_real_dir(path))
        return;
    if (add_directory_watch(path) < 0)
        return;
    dir = opendir(path);
    if (!dir) {
        int saved = errno;
        if (saved != ENOENT && saved != ENOTDIR) {
            char detail[256];
            snprintf(detail, sizeof(detail), "opendir failed: %s", strerror(saved));
            errno = saved;
            emit_error(path, detail);
            exit(2);
        }
        return;
    }
    while ((item = readdir(dir)) != NULL) {
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, ".."))
            continue;
        int child_len = snprintf(child, sizeof(child), "%s/%s", path, item->d_name);
        if (child_len < 0 || child_len >= (int)sizeof(child)) {
            emit_error(path, "path component too long, skipping");
            continue;
        }
        if (is_real_dir(child))
            add_tree(child, announce_files);
        else if (announce_files) {
            struct stat st;
            if (lstat(child, &st) == 0 && S_ISREG(st.st_mode))
                emit_record("CREATE", child);
        }
    }
    closedir(dir);
}

static void emit_event_path(const char *type, const char *directory, const char *name)
{
    char path[PATH_MAX];
    if (!name || !*name)
        emit_record(type, directory);
    else {
        int path_len = snprintf(path, sizeof(path), "%s/%s", directory, name);
        if (path_len < 0 || path_len >= (int)sizeof(path)) {
            emit_error(directory, "event path too long, skipping");
            return;
        }
        emit_record(type, path);
    }
}

static void handle_event(const struct inotify_event *event)
{
    ssize_t index = find_entry(event->wd);
    char path[PATH_MAX];

    if ((event->mask & IN_IGNORED) && consume_stale(event->wd))
        return;
    if (event->mask & IN_Q_OVERFLOW) {
        emit_error(project_root, "inotify queue overflow");
        exit(2);
    }
    if (index < 0)
        return;
    if ((event->mask & (IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED)) &&
        !strcmp(entries[index].path, project_root)) {
        emit_error(project_root, "ROOT_LOST: project root was removed or moved");
        exit(2);
    }
    if (event->len) {
        int path_len = snprintf(path, sizeof(path), "%s/%s",
                                entries[index].path, event->name);
        if (path_len < 0 || path_len >= (int)sizeof(path)) {
            emit_error(entries[index].path, "event path too long, skipping");
            return;
        }
    }
    if (event->len == 0)
        snprintf(path, sizeof(path), "%s", entries[index].path);

    if (event->mask & IN_ISDIR) {
        const char *type = (event->mask & IN_MOVED_FROM) ? "MOVE_OUT" :
                           (event->mask & IN_DELETE) ? "DELETE" :
                           (event->mask & IN_MOVED_TO) ? "MOVE_IN" : "DIR";
        emit_event_path(type, entries[index].path, event->len ? event->name : NULL);
        if (event->mask & (IN_CREATE | IN_MOVED_TO))
            add_tree(path, 1);
        if (event->mask & (IN_DELETE | IN_MOVED_FROM))
            forget_tree(path);
    } else if (event->mask & (IN_MOVED_FROM | IN_DELETE | IN_MOVED_TO |
                              IN_CREATE | IN_CLOSE_WRITE | IN_ATTRIB)) {
        const char *type = (event->mask & IN_MOVED_FROM) ? "MOVE_OUT" :
                           (event->mask & IN_DELETE) ? "DELETE" :
                           (event->mask & IN_MOVED_TO) ? "MOVE_IN" :
                           (event->mask & IN_CREATE) ? "CREATE" :
                           (event->mask & IN_CLOSE_WRITE) ? "WRITE" : "ATTRIB";
        emit_event_path(type, entries[index].path, event->len ? event->name : NULL);
    }
    if (event->mask & (IN_IGNORED | IN_DELETE_SELF))
        forget_watch(event->wd);
}

int main(int argc, char **argv)
{
    char buffer[64 * 1024];
    ssize_t length;
    size_t offset;
    int scan_once = 0;

    if ((argc == 3 && !strcmp(argv[1], "--scan-once")) || argc == 2)
        scan_once = argc == 3;
    else {
        fprintf(stderr, "usage: vide-watch [--scan-once] PROJECT_ROOT\n");
        return 2;
    }
    if (!is_real_dir(scan_once ? argv[2] : argv[1])) {
        fprintf(stderr, "usage: vide-watch [--scan-once] PROJECT_ROOT\n");
        return 2;
    }
    project_root = strdup(scan_once ? argv[2] : argv[1]);
    if (!project_root)
        die("out of memory");
    notify_fd = inotify_init1(IN_CLOEXEC);
    if (notify_fd < 0)
        die("cannot initialize inotify");
    signal(SIGPIPE, SIG_IGN);
    if (vide_wd_map_init(&wd_map, 128) < 0)
        die("cannot initialize watch descriptor table");
    add_tree(project_root, 0);
    if (entry_count == 0) {
        emit_error(project_root, "no usable directory watches");
        return 2;
    }
    if (scan_once)
        return 0;
    for (;;) {
        length = read(notify_fd, buffer, sizeof(buffer));
        if (length < 0) {
            if (errno == EINTR)
                continue;
            die("cannot read inotify events");
        }
        offset = 0;
        while (offset < (size_t)length) {
            struct inotify_event *event =
                (struct inotify_event *)(buffer + offset);
            handle_event(event);
            offset += sizeof(*event) + event->len;
            if (entry_count == 0) {
                emit_error(project_root, "no valid directory watches remain");
                return 2;
            }
        }
    }
}
