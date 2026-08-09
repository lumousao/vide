#include "vide-watch-hashmap.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static size_t hash_key(int key)
{
    uint32_t x = (uint32_t)key;
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    return (size_t)(x ^ (x >> 16));
}

static int map_allocate(struct vide_wd_map *map, size_t capacity)
{
    map->keys = calloc(capacity, sizeof(*map->keys));
    map->values = calloc(capacity, sizeof(*map->values));
    map->used = calloc(capacity, sizeof(*map->used));
    if (!map->keys || !map->values || !map->used) {
        vide_wd_map_destroy(map);
        return -1;
    }
    map->capacity = capacity;
    map->count = 0;
    return 0;
}

int vide_wd_map_init(struct vide_wd_map *map, size_t capacity)
{
    memset(map, 0, sizeof(*map));
    if (capacity < 16)
        capacity = 16;
    return map_allocate(map, capacity);
}

void vide_wd_map_destroy(struct vide_wd_map *map)
{
    free(map->keys);
    free(map->values);
    free(map->used);
    memset(map, 0, sizeof(*map));
}

static int map_rehash(struct vide_wd_map *map, size_t capacity)
{
    struct vide_wd_map grown;
    size_t i;
    if (map_allocate(&grown, capacity) < 0)
        return -1;
    for (i = 0; i < map->capacity; ++i) {
        if (map->used[i])
            vide_wd_map_set(&grown, map->keys[i], map->values[i]);
    }
    vide_wd_map_destroy(map);
    *map = grown;
    return 0;
}

int vide_wd_map_get(const struct vide_wd_map *map, int key, size_t *value)
{
    size_t slot;
    size_t probes = 0;
    if (!map->capacity)
        return 0;
    slot = hash_key(key) % map->capacity;
    while (probes++ < map->capacity) {
        if (!map->used[slot])
            return 0;
        if (map->keys[slot] == key) {
            if (value)
                *value = map->values[slot];
            return 1;
        }
        slot = (slot + 1) % map->capacity;
    }
    return 0;
}

int vide_wd_map_set(struct vide_wd_map *map, int key, size_t value)
{
    size_t slot;
    size_t probes = 0;
    if (!map->capacity && vide_wd_map_init(map, 16) < 0)
        return -1;
    if ((map->count + 1) * 10 > map->capacity * 7) {
        if (map_rehash(map, map->capacity * 2) < 0)
            return -1;
    }
    slot = hash_key(key) % map->capacity;
    while (probes++ < map->capacity) {
        if (!map->used[slot]) {
            map->used[slot] = 1;
            map->keys[slot] = key;
            map->values[slot] = value;
            ++map->count;
            return 0;
        }
        if (map->keys[slot] == key) {
            map->values[slot] = value;
            return 0;
        }
        slot = (slot + 1) % map->capacity;
    }
    return -1;
}

void vide_wd_map_remove(struct vide_wd_map *map, int key)
{
    size_t slot;
    size_t probes = 0;
    if (!map->capacity)
        return;
    slot = hash_key(key) % map->capacity;
    while (probes++ < map->capacity && map->used[slot]) {
        if (map->keys[slot] == key) {
            size_t next = (slot + 1) % map->capacity;
            map->used[slot] = 0;
            --map->count;
            while (map->used[next]) {
                int moved_key = map->keys[next];
                size_t moved_value = map->values[next];
                map->used[next] = 0;
                --map->count;
                vide_wd_map_set(map, moved_key, moved_value);
                next = (next + 1) % map->capacity;
            }
            return;
        }
        slot = (slot + 1) % map->capacity;
    }
}
