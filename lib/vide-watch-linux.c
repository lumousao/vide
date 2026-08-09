/* Linux backend implementation lives in vide-watch.c while the migration to
 * vide-watch-main.c is kept source-compatible.  Keeping this translation unit
 * available gives downstream packagers a stable backend name without making
 * the production Linux binary link two competing main functions. */
#include "vide-watch.h"
