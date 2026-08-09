/* Shared watcher protocol contract.
 *
 * Platform backends currently provide their own small main loop so they can
 * use native descriptor/event APIs without an emulation layer.  This file is
 * intentionally kept free of platform headers; it documents the common
 * backend boundary declared in vide-watch.h and is reserved for the next
 * linker-level consolidation.
 */
#include "vide-watch.h"
