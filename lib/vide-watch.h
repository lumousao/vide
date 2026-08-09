#ifndef VIDE_WATCH_H
#define VIDE_WATCH_H

/* Platform helpers emit the same length-framed P<event><bytes>:<path>
 * protocol consumed by src/vide.vim. */
struct watch_backend {
    int (*init)(const char *root);
    int (*add_tree)(const char *path, int announce_files);
    int (*read_events)(void (*handler)(const char *type, const char *path));
    void (*cleanup)(void);
};

extern const struct watch_backend *vide_watch_backend;

#endif
