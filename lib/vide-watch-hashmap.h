#ifndef VIDE_WATCH_HASHMAP_H
#define VIDE_WATCH_HASHMAP_H

#include <stddef.h>

struct vide_wd_map {
    int *keys;
    size_t *values;
    unsigned char *used;
    size_t capacity;
    size_t count;
};

int vide_wd_map_init(struct vide_wd_map *map, size_t capacity);
void vide_wd_map_destroy(struct vide_wd_map *map);
int vide_wd_map_get(const struct vide_wd_map *map, int key, size_t *value);
int vide_wd_map_set(struct vide_wd_map *map, int key, size_t value);
void vide_wd_map_remove(struct vide_wd_map *map, int key);

#endif
