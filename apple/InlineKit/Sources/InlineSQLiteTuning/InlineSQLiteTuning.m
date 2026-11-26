#include "InlineSQLiteTuning.h"
#include <SQLCipher/sqlite3.h>

int inline_sqlite_disable_memstatus(void) {
  return sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 0);
}

int inline_sqlite_enable_qpsg(sqlite3 *db) {
  int enabled = 0;
  return sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_QPSG, 1, &enabled);
}
