import type { Database } from "@sqlite.org/sqlite-wasm"

export const INLINE_SQLITE_SCHEMA_VERSION = 2

type InlineSqliteMigration = {
  version: number
  name: string
  sql: string
}

const migrations: readonly InlineSqliteMigration[] = [
  {
    version: 1,
    name: "initial_inline_replica",
    sql: `
      CREATE TABLE user (
        id INTEGER PRIMARY KEY,
        payload BLOB NOT NULL
      );

      CREATE TABLE space (
        id INTEGER PRIMARY KEY,
        date INTEGER NOT NULL,
        payload BLOB NOT NULL
      );

      CREATE TABLE chat (
        id INTEGER PRIMARY KEY,
        space_id INTEGER,
        last_message_id INTEGER,
        date INTEGER,
        payload BLOB NOT NULL
      );
      CREATE INDEX chat_space_date_idx
        ON chat(space_id, date DESC, id DESC);

      CREATE TABLE dialog (
        id INTEGER PRIMARY KEY,
        chat_id INTEGER NOT NULL,
        space_id INTEGER,
        is_open INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        is_archived INTEGER NOT NULL DEFAULT 0,
        is_chat_list_hidden INTEGER NOT NULL DEFAULT 0,
        sidebar_order TEXT,
        pinned_order TEXT,
        payload BLOB NOT NULL
      );
      CREATE UNIQUE INDEX dialog_chat_id_idx ON dialog(chat_id);
      CREATE INDEX dialog_inbox_idx ON dialog(
        is_archived,
        is_chat_list_hidden,
        is_open,
        is_pinned,
        pinned_order,
        sidebar_order
      );

      CREATE TABLE message (
        chat_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        date_order INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(chat_id, message_id)
      ) WITHOUT ROWID;
      CREATE INDEX message_chat_window_idx
        ON message(chat_id, date_order, message_id);

      CREATE TABLE sync_global_state (
        id INTEGER PRIMARY KEY CHECK(id = 0),
        last_sync_date INTEGER NOT NULL,
        payload BLOB NOT NULL
      );

      CREATE TABLE sync_bucket_state (
        id TEXT PRIMARY KEY,
        seq INTEGER NOT NULL,
        date INTEGER NOT NULL,
        payload BLOB NOT NULL
      ) WITHOUT ROWID;

      CREATE TABLE deferred_update (
        id TEXT PRIMARY KEY,
        bucket_id TEXT NOT NULL,
        target_key TEXT,
        seq INTEGER,
        date INTEGER,
        payload BLOB NOT NULL
      ) WITHOUT ROWID;
      CREATE INDEX deferred_update_target_idx
        ON deferred_update(target_key, seq, date, id)
        WHERE target_key IS NOT NULL;
      CREATE INDEX deferred_update_bucket_idx
        ON deferred_update(bucket_id, seq, date, id);

      CREATE TABLE pending_transaction (
        id TEXT PRIMARY KEY,
        transaction_type TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        payload BLOB NOT NULL
      ) WITHOUT ROWID;
      CREATE INDEX pending_transaction_created_idx
        ON pending_transaction(status, created_at, id);

      CREATE TABLE reserved_chat_id (
        chat_id INTEGER PRIMARY KEY,
        expires_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        payload BLOB NOT NULL
      );
      CREATE INDEX reserved_chat_id_expiry_idx
        ON reserved_chat_id(expires_at, created_at, chat_id);

      CREATE TABLE message_draft (
        id TEXT PRIMARY KEY,
        peer_kind TEXT NOT NULL,
        peer_user_id INTEGER,
        peer_thread_id INTEGER,
        revision INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        payload BLOB NOT NULL,
        CHECK(
          (peer_kind = 'user' AND peer_user_id IS NOT NULL AND peer_thread_id IS NULL)
          OR
          (peer_kind = 'chat' AND peer_user_id IS NULL AND peer_thread_id IS NOT NULL)
        )
      ) WITHOUT ROWID;
      CREATE INDEX message_draft_updated_idx
        ON message_draft(updated_at, id);
    `,
  },
  {
    version: 2,
    name: "replica_import_metadata",
    sql: `
      CREATE TABLE inline_replica_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      ) WITHOUT ROWID;
    `,
  },
]

const migrationTableSql = `
  CREATE TABLE IF NOT EXISTS inline_schema_migration (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    applied_at INTEGER NOT NULL
  );
`

const currentVersion = (db: Database): number => {
  const rows = db.exec({
    sql: "SELECT COALESCE(MAX(version), 0) AS version FROM inline_schema_migration",
    rowMode: "object",
    returnValue: "resultRows",
  })
  const version = rows[0]?.version
  if (typeof version === "bigint") return Number(version)
  return typeof version === "number" ? version : 0
}

export class InlineSqliteMigrationError extends Error {
  constructor(
    readonly migration: string,
    cause: unknown,
  ) {
    super(`Inline SQLite migration failed: ${migration}`, { cause })
    this.name = "InlineSqliteMigrationError"
  }
}

export const migrateInlineSqlite = (db: Database): number => {
  db.exec("PRAGMA foreign_keys = ON")
  db.exec("PRAGMA trusted_schema = OFF")
  db.exec("PRAGMA temp_store = MEMORY")
  db.exec("PRAGMA synchronous = FULL")
  db.exec(migrationTableSql)

  let version = currentVersion(db)
  if (version > INLINE_SQLITE_SCHEMA_VERSION) {
    throw new InlineSqliteMigrationError(
      `database version ${version} is newer than supported ${INLINE_SQLITE_SCHEMA_VERSION}`,
      undefined,
    )
  }

  for (const migration of migrations) {
    if (migration.version <= version) continue
    db.exec("BEGIN IMMEDIATE")
    try {
      db.exec(migration.sql)
      db.exec({
        sql: `
          INSERT INTO inline_schema_migration(version, name, applied_at)
          VALUES (?, ?, ?)
        `,
        bind: [migration.version, migration.name, Date.now()],
      })
      db.exec("COMMIT")
      version = migration.version
    } catch (cause) {
      try {
        db.exec("ROLLBACK")
      } catch {
        // Preserve the migration failure; SQLite may already have rolled back.
      }
      throw new InlineSqliteMigrationError(migration.name, cause)
    }
  }

  return version
}
