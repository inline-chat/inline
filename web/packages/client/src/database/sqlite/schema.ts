import type { Database } from "@sqlite.org/sqlite-wasm"
import { decodeInlineModel } from "../model-codec"

export const INLINE_SQLITE_SCHEMA_VERSION = 5

type InlineSqliteMigration = {
  version: number
  name: string
  sql: string
  /** Data step run after `sql`, inside the same transaction. */
  backfill?: (db: Database) => void
}

/**
 * Version 4 indexes deferred updates by kind so a newly projected kind can
 * replay its raw rows without scanning the whole log. Rows written before
 * carry the kind only in their payload; read it from there. A payload that
 * does not decode keeps a NULL kind and stays retained (invariant 7).
 */
const backfillDeferredUpdateTypes = (db: Database) => {
  const rows = db.exec({
    sql: "SELECT id, payload FROM deferred_update WHERE update_type IS NULL",
    rowMode: "object",
    returnValue: "resultRows",
  })
  const statement = db.prepare(
    "UPDATE deferred_update SET update_type = ? WHERE id = ?",
  )
  try {
    for (const row of rows) {
      if (!(row.payload instanceof Uint8Array)) continue
      let updateType: unknown
      try {
        const model = decodeInlineModel(row.payload)
        updateType =
          "updateType" in model ? model.updateType : undefined
      } catch {
        continue
      }
      if (typeof updateType !== "string") continue
      statement.bind([updateType, String(row.id)]).stepReset()
      statement.clearBindings()
    }
  } finally {
    statement.finalize()
  }
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
  {
    // Invariant 5: certified history ranges per chat, apart from the message
    // rows. No row means nothing is certified, which is the right start for
    // every chat already in an older replica.
    version: 3,
    name: "message_history_coverage",
    sql: `
      CREATE TABLE message_history_coverage (
        chat_id INTEGER PRIMARY KEY,
        payload BLOB NOT NULL
      );
    `,
  },
  {
    // Models for update kinds that were stored raw: space members, chat
    // participants and group grants, user groups, dialog folders and the
    // account's settings. Dialog, chat and space fields added at the same
    // time live in their payloads. Every table starts empty; raw rows of the
    // newly projected kinds are replayed into them by the update layer.
    version: 4,
    name: "membership_and_settings_models",
    sql: `
      CREATE TABLE space_member (
        space_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        member_id INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(space_id, user_id)
      ) WITHOUT ROWID;
      CREATE INDEX space_member_user_idx ON space_member(user_id, space_id);

      CREATE TABLE chat_participant (
        chat_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(chat_id, user_id)
      ) WITHOUT ROWID;

      CREATE TABLE chat_participant_group (
        chat_id INTEGER NOT NULL,
        group_id INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(chat_id, group_id)
      ) WITHOUT ROWID;

      CREATE TABLE user_group (
        id INTEGER PRIMARY KEY,
        space_id INTEGER NOT NULL,
        payload BLOB NOT NULL
      );
      CREATE INDEX user_group_space_idx ON user_group(space_id, id);

      CREATE TABLE dialog_folder (
        id INTEGER PRIMARY KEY,
        payload BLOB NOT NULL
      );

      CREATE TABLE user_settings (
        id INTEGER PRIMARY KEY CHECK(id = 0),
        payload BLOB NOT NULL
      );

      ALTER TABLE deferred_update ADD COLUMN update_type TEXT;
      CREATE INDEX deferred_update_type_idx
        ON deferred_update(update_type, seq, date, id)
        WHERE update_type IS NOT NULL;
    `,
    backfill: backfillDeferredUpdateTypes,
  },
  {
    // Local message search (`src/search/README.md`). An FTS5 index over
    // message text, folded and tokenized in TypeScript (the tokenizer only
    // splits on spaces), kept in the replica so it commits with the rows it
    // indexes. The message payload is a blob, so the store writes entries
    // (`MessageSearchIndexWriter.put`) and triggers remove them whatever
    // deletes a message row. Messages already stored are indexed afterwards
    // in bounded batches; the progress lives in `inline_replica_metadata`.
    version: 5,
    name: "message_search_index",
    sql: `
      CREATE TABLE message_search_doc (
        id INTEGER PRIMARY KEY,
        chat_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        hash INTEGER NOT NULL
      );
      CREATE UNIQUE INDEX message_search_doc_message_idx
        ON message_search_doc(chat_id, message_id);

      CREATE VIRTUAL TABLE message_search USING fts5(
        body,
        chat,
        content = '',
        contentless_delete = 1,
        tokenize = "unicode61 remove_diacritics 0 categories 'L* N* M* P* S* C*'",
        prefix = '2 3'
      );

      CREATE TRIGGER message_search_doc_ad
        AFTER DELETE ON message_search_doc
      BEGIN
        DELETE FROM message_search WHERE rowid = old.id;
      END;

      CREATE TRIGGER message_search_message_ad
        AFTER DELETE ON message
      BEGIN
        DELETE FROM message_search_doc
          WHERE chat_id = old.chat_id AND message_id = old.message_id;
      END;
    `,
    backfill: (db) => {
      const rows = db.exec({
        sql: "SELECT EXISTS(SELECT 1 FROM message) AS any",
        rowMode: "object",
        returnValue: "resultRows",
      })
      const hasMessages = Number(rows[0]?.any ?? 0) !== 0
      db.exec({
        sql: `INSERT INTO inline_replica_metadata(key, value, updated_at)
          VALUES ('message_search', ?, ?)
          ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = excluded.updated_at`,
        bind: [
          JSON.stringify({
            version: 1,
            state: hasMessages ? "building" : "ready",
          }),
          Date.now(),
        ],
      })
    },
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

/**
 * Invariant 9. The replica was written by a newer schema than this build
 * knows. Thrown before anything is written; the store never opens it, so an
 * older build never becomes the replica's writer. The host shows the
 * "outdated" phase (reload to get the newer build). The name and message
 * stay those of `InlineSqliteMigrationError` for existing callers.
 */
export class InlineSqliteSchemaTooNewError extends InlineSqliteMigrationError {
  readonly outdated = true

  constructor(
    readonly storedVersion: number,
    readonly supportedVersion: number,
  ) {
    super(
      `database version ${storedVersion} is newer than supported ${supportedVersion}`,
      undefined,
    )
  }
}

export const isInlineSqliteSchemaTooNew = (
  error: unknown,
): error is InlineSqliteSchemaTooNewError =>
  error instanceof InlineSqliteSchemaTooNewError ||
  (error instanceof Error && error.cause instanceof InlineSqliteSchemaTooNewError)

/**
 * Bring the replica forward to `INLINE_SQLITE_SCHEMA_VERSION`, one
 * transaction per migration. `throughVersion` stops earlier; it exists so
 * tests can build every earlier schema version and upgrade it.
 */
export const migrateInlineSqlite = (
  db: Database,
  throughVersion = INLINE_SQLITE_SCHEMA_VERSION,
): number => {
  db.exec("PRAGMA foreign_keys = ON")
  db.exec("PRAGMA trusted_schema = OFF")
  db.exec("PRAGMA temp_store = MEMORY")
  db.exec("PRAGMA synchronous = FULL")
  db.exec(migrationTableSql)

  let version = currentVersion(db)
  if (version > INLINE_SQLITE_SCHEMA_VERSION) {
    throw new InlineSqliteSchemaTooNewError(
      version,
      INLINE_SQLITE_SCHEMA_VERSION,
    )
  }

  for (const migration of migrations) {
    if (migration.version <= version) continue
    if (migration.version > throughVersion) break
    db.exec("BEGIN IMMEDIATE")
    try {
      db.exec(migration.sql)
      migration.backfill?.(db)
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
