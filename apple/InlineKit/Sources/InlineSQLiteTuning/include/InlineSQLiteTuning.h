#ifndef INLINE_SQLITE_TUNING_H
#define INLINE_SQLITE_TUNING_H

/// Turns off SQLite's global memory statistics. Must run before the first SQLCipher connection opens.
/// With statistics on (the build default), every sqlite3_malloc and sqlite3_free in the process takes one
/// global mutex, so reader and writer connections on different threads serialize on allocation.
/// Returns SQLITE_OK, or SQLITE_MISUSE when SQLite is already initialized (the setting is then unchanged).
int inline_sqlite_disable_memstatus(void);

typedef struct sqlite3 sqlite3;

/// Turns on the query planner stability guarantee for one connection (SQLITE_DBCONFIG_ENABLE_QPSG).
/// SQLCipher is built with STAT4, so without it a statement whose plan looked at a bound value is
/// recompiled on the first step after that binding changes, which defeats statement caching.
/// Returns SQLITE_OK on success.
int inline_sqlite_enable_qpsg(sqlite3 *db);

#endif
