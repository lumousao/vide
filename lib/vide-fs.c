#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static void fail_with_context(const char *operation, const char *path,
                              const char *detail)
{
    int saved = errno;
    if (detail && *detail)
        fprintf(stderr, "%s: %s: %s: %s\n", operation, path, detail,
                strerror(saved));
    else
        fprintf(stderr, "%s: %s: %s\n", operation, path, strerror(saved));
    exit(1);
}

static int valid_component(const char *part)
{
    return *part && strcmp(part, ".") && strcmp(part, "..");
}

static int open_root(const char *path)
{
    return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

static int open_child_dir(int parent, const char *name, int create)
{
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd >= 0)
        return fd;
    if (!create || errno != ENOENT)
        return -1;
    if (mkdirat(parent, name, 0777) < 0 && errno != EEXIST)
        return -1;
    return openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

static int split_relative(const char *relative, char *parent, size_t parent_size,
                          char *base, size_t base_size)
{
    char copy[PATH_MAX];
    char *slash;
    char *part;
    char *save;
    if (!relative || !*relative || relative[0] == '/' || strlen(relative) >= sizeof(copy))
        return -1;
    strcpy(copy, relative);
    slash = strrchr(copy, '/');
    if (slash) {
        *slash = '\0';
        if (!*copy || strlen(copy) >= parent_size)
            return -1;
        strcpy(parent, copy);
        if (strlen(slash + 1) >= base_size)
            return -1;
        strcpy(base, slash + 1);
    } else {
        parent[0] = '\0';
        if (strlen(copy) >= base_size)
            return -1;
        strcpy(base, copy);
    }
    if (!valid_component(base))
        return -1;
    for (part = strtok_r(parent, "/", &save); part; part = strtok_r(NULL, "/", &save))
        if (!valid_component(part))
            return -1;
    return 0;
}

static int open_parent(int root, const char *relative, int create, char *base)
{
    char parent[PATH_MAX];
    char copy[PATH_MAX];
    char *part;
    char *save;
    int current = -1;
    if (split_relative(relative, parent, sizeof(parent), base, PATH_MAX) < 0)
        return -1;
    current = dup(root);
    if (current < 0)
        return -1;
    if (!parent[0])
        return current;
    if (strlen(parent) >= sizeof(copy)) {
        close(current);
        return -1;
    }
    strcpy(copy, parent);
    for (part = strtok_r(copy, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        int next = open_child_dir(current, part, create);
        close(current);
        current = next;
        if (current < 0)
            return -1;
    }
    return current;
}

static int remove_entry(int parent, const char *name)
{
    struct stat st;
    int child;
    DIR *dir;
    struct dirent *entry;
    if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) < 0)
        return -1;
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode))
        return unlinkat(parent, name, 0);
    child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (child < 0)
        return -1;
    dir = fdopendir(dup(child));
    if (!dir) {
        close(child);
        return -1;
    }
    while ((entry = readdir(dir)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        if (remove_entry(child, entry->d_name) < 0) {
            closedir(dir);
            close(child);
            return -1;
        }
    }
    closedir(dir);
    close(child);
    return unlinkat(parent, name, AT_REMOVEDIR);
}

static int rename_no_replace(int old_parent, const char *old_name,
                             int new_parent, const char *new_name)
{
#ifdef SYS_renameat2
    int result = syscall(SYS_renameat2, old_parent, old_name, new_parent, new_name,
                         RENAME_NOREPLACE);
    if (result < 0 && errno == ENOSYS) {
        struct stat st;
        if (fstatat(new_parent, new_name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
            errno = EEXIST;
            return -1;
        }
        if (errno != ENOENT)
            return -1;
        return renameat(old_parent, old_name, new_parent, new_name);
    }
    return result;
#else
    return renameat(old_parent, old_name, new_parent, new_name);
#endif
}

int main(int argc, char **argv)
{
    int root;
    int parent;
    int other;
    char base[PATH_MAX];
    char other_base[PATH_MAX];
    int result = -1;

    if (argc < 4 || argc > 5) {
        fprintf(stderr, "usage: vide-fs ROOT create-file|create-dir|delete PATH\n");
        fprintf(stderr, "       vide-fs ROOT rename OLD NEW\n");
        return 2;
    }
    root = open_root(argv[1]);
    if (root < 0)
        fail_with_context("open", argv[1], "cannot open project root");
    if (!strcmp(argv[2], "create-file") || !strcmp(argv[2], "create-dir")) {
        parent = open_parent(root, argv[3], 1, base);
        if (parent < 0)
            fail_with_context(argv[2], argv[3], "cannot open safe parent");
        if (!strcmp(argv[2], "create-file")) {
            int fd = openat(parent, base, O_WRONLY | O_CREAT | O_EXCL |
                            O_CLOEXEC | O_NOFOLLOW, 0666);
            if (fd >= 0) {
                close(fd);
                result = 0;
            }
        } else {
            result = mkdirat(parent, base, 0777);
        }
        close(parent);
    } else if (!strcmp(argv[2], "delete")) {
        parent = open_parent(root, argv[3], 0, base);
        if (parent >= 0) {
            result = remove_entry(parent, base);
            close(parent);
        }
    } else if (!strcmp(argv[2], "rename") && argc == 5) {
        parent = open_parent(root, argv[3], 0, base);
        other = open_parent(root, argv[4], 0, other_base);
        if (parent >= 0 && other >= 0)
            result = rename_no_replace(parent, base, other, other_base);
        if (parent >= 0)
            close(parent);
        if (other >= 0)
            close(other);
    } else {
        errno = EINVAL;
    }
    close(root);
    if (result < 0) {
        if (!strcmp(argv[2], "rename") && argc == 5) {
            char rename_path[PATH_MAX * 2];
            snprintf(rename_path, sizeof(rename_path), "%s -> %s", argv[3], argv[4]);
            fail_with_context(argv[2], rename_path, "filesystem operation failed");
        }
        fail_with_context(argv[2], argv[3], "filesystem operation failed");
    }
    puts("OK");
    return 0;
}
