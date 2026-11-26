#include "InlineSQLiteTuning.h"
#include <SQLCipher/sqlite3.h>
#include <string.h>

int inline_sqlite_disable_memstatus(void) {
  return sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 0);
}

int inline_sqlite_enable_qpsg(sqlite3 *db) {
  int enabled = 0;
  return sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_QPSG, 1, &enabled);
}

int inline_sqlite_read_file_prefix(const char *path, void *buffer, int length) {
  if (path == NULL || buffer == NULL || length <= 0) return -1;
  sqlite3_vfs *vfs = sqlite3_vfs_find(NULL);
  if (vfs == NULL) return -1;
  sqlite3_file *file = sqlite3_malloc(vfs->szOsFile);
  if (file == NULL) return -1;
  memset(file, 0, (size_t)vfs->szOsFile);
  int result = -1;
  int outFlags = 0;
  if (vfs->xOpen(vfs, path, file, SQLITE_OPEN_READONLY | SQLITE_OPEN_MAIN_DB, &outFlags) == SQLITE_OK) {
    int rc = file->pMethods->xRead(file, buffer, length, 0);
    if (rc == SQLITE_OK) {
      result = length;
    } else if (rc == SQLITE_IOERR_SHORT_READ) {
      result = 0;
    }
  }
  // A failed xOpen may still leave methods set; xClose is then required to release the descriptor.
  if (file->pMethods != NULL) file->pMethods->xClose(file);
  sqlite3_free(file);
  return result;
}
