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

static void emit_path(const char *path)
{
    size_t length = strlen(path);
    printf("P%zu:", length);
    fwrite(path, 1, length, stdout);
    fflush(stdout);
}

static ssize_t find_entry(int wd)
{
    size_t i;
    for (i = 0; i < entry_count; ++i)
        if (entries[i].wd == wd)
            return (ssize_t)i;
    return -1;
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
    ++entry_count;
}

static void forget_watch(int wd)
{
    ssize_t index = find_entry(wd);
    if (index < 0)
        return;
    free(entries[index].path);
    entries[index] = entries[entry_count - 1];
    --entry_count;
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
            forget_watch(wd);
            continue;
        }
        ++i;
    }
}

static void add_tree(const char *path, int announce_files);

static void add_directory_watch(const char *path)
{
    const uint32_t mask = IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE |
                          IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF |
                          IN_ATTRIB;
    int wd = inotify_add_watch(notify_fd, path, mask);
    if (wd < 0) {
        if (errno == ENOENT || errno == ENOTDIR || errno == EACCES)
            return;
        die("cannot add directory watch");
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
}

static void add_tree(const char *path, int announce_files)
{
    DIR *dir;
    struct dirent *item;
    char child[PATH_MAX];
    const char *base = strrchr(path, '/');

    if (base && !strcmp(base + 1, ".git"))
        return;
    if (!is_real_dir(path))
        return;
    add_directory_watch(path);
    dir = opendir(path);
    if (!dir)
        return;
    while ((item = readdir(dir)) != NULL) {
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, ".."))
            continue;
        if (snprintf(child, sizeof(child), "%s/%s", path, item->d_name) >=
            (int)sizeof(child))
            continue;
        if (is_real_dir(child))
            add_tree(child, announce_files);
        else if (announce_files) {
            struct stat st;
            if (lstat(child, &st) == 0 && S_ISREG(st.st_mode))
                emit_path(child);
        }
    }
    closedir(dir);
}

static void emit_event_path(const char *directory, const char *name)
{
    char path[PATH_MAX];
    if (!name || !*name)
        emit_path(directory);
    else if (snprintf(path, sizeof(path), "%s/%s", directory, name) <
             (int)sizeof(path))
        emit_path(path);
}

static void handle_event(const struct inotify_event *event)
{
    ssize_t index = find_entry(event->wd);
    char path[PATH_MAX];

    if (event->mask & IN_Q_OVERFLOW) {
        fputs("Eoverflow\n", stdout);
        fflush(stdout);
        exit(2);
    }
    if (index < 0)
        return;
    if (event->len && snprintf(path, sizeof(path), "%s/%s",
                               entries[index].path, event->name) >=
                       (int)sizeof(path))
        return;
    if (event->len == 0)
        snprintf(path, sizeof(path), "%s", entries[index].path);

    if (event->mask & IN_ISDIR) {
        emit_event_path(entries[index].path, event->len ? event->name : NULL);
        if (event->mask & (IN_CREATE | IN_MOVED_TO))
            add_tree(path, 1);
        if (event->mask & (IN_DELETE | IN_MOVED_FROM))
            forget_tree(path);
    } else if (event->mask & (IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE |
                              IN_ATTRIB)) {
        emit_event_path(entries[index].path, event->len ? event->name : NULL);
    }
    if (event->mask & (IN_IGNORED | IN_DELETE_SELF))
        forget_watch(event->wd);
}

int main(int argc, char **argv)
{
    char buffer[64 * 1024];
    ssize_t length;
    size_t offset;

    if (argc != 2 || !is_real_dir(argv[1])) {
        fprintf(stderr, "usage: vide-watch PROJECT_ROOT\n");
        return 2;
    }
    notify_fd = inotify_init1(IN_CLOEXEC);
    if (notify_fd < 0)
        die("cannot initialize inotify");
    signal(SIGPIPE, SIG_IGN);
    add_tree(argv[1], 0);
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
        }
    }
}
