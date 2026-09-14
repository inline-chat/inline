import type {
  BindableValue,
  BindingSpec,
  Database,
  PreparedStatement,
  SqlValue,
} from "@sqlite.org/sqlite-wasm"
import {
  type ChatID,
  type MessageID,
} from "@inline/ids"
import { decodeInlineModel, encodeInlineModel } from "../model-codec"
import {
  DbObjectKind,
  type DbModel,
  type DbModels,
  type Message,
  messageKey,
} from "../models"
import type {
  InlinePersistenceCollection,
  InlinePersistenceOperation,
  InlinePersistenceStore,
} from "../persistence"
import {
  compareMessagesByWindow,
  messageWindowDate,
  type MessageWindowCursor,
} from "../message-window"
import { migrateInlineSqlite } from "./schema"

export type OpenInlineSqliteDatabase = () => Promise<Database>

export type InlineSqliteWriteCheckpoint =
  | { phase: "after-begin"; operationCount: number }
  | { phase: "before-commit"; operationCount: number }
  | { phase: "after-commit"; operationCount: number }

export type SQLitePersistenceStoreOptions = {
  /** Test/diagnostic crash barrier; production adapters leave this unset. */
  onWriteCheckpoint?: (
    checkpoint: InlineSqliteWriteCheckpoint,
  ) => Promise<void> | void
}

type PayloadRow = Record<string, SqlValue>

const tableByKind = {
  [DbObjectKind.User]: "user",
  [DbObjectKind.Space]: "space",
  [DbObjectKind.Chat]: "chat",
  [DbObjectKind.Dialog]: "dialog",
  [DbObjectKind.Message]: "message",
  [DbObjectKind.SyncGlobalState]: "sync_global_state",
  [DbObjectKind.SyncBucketState]: "sync_bucket_state",
  [DbObjectKind.DeferredUpdate]: "deferred_update",
  [DbObjectKind.PendingTransaction]: "pending_transaction",
  [DbObjectKind.ReservedChatID]: "reserved_chat_id",
  [DbObjectKind.MessageDraft]: "message_draft",
} as const satisfies Record<DbObjectKind, string>

const exactId = (value: string): bigint => BigInt(value)
const optionalExactId = (
  value: string | undefined,
): bigint | null => (value == null ? null : exactId(value))
const flag = (value: boolean | undefined): number =>
  value === true ? 1 : 0

const payloadFromRow = (row: PayloadRow): Uint8Array => {
  if (!(row.payload instanceof Uint8Array)) {
    throw new InlineSqliteCorruptionError(
      "SQLite row does not contain an Inline model payload",
    )
  }
  return row.payload
}

const assertModelIdentity = <K extends DbObjectKind>(
  kind: K,
  expectedId: DbModels[K]["id"] | undefined,
  model: DbModel,
): DbModels[K] => {
  if (model.kind !== kind) {
    throw new InlineSqliteCorruptionError(
      `SQLite ${tableByKind[kind]} row decoded as ${model.kind}`,
    )
  }
  if (
    expectedId !== undefined &&
    String(model.id) !== String(expectedId)
  ) {
    throw new InlineSqliteCorruptionError(
      `SQLite ${tableByKind[kind]} identity does not match its payload`,
    )
  }
  return model as DbModels[K]
}

const decodeRow = <K extends DbObjectKind>(
  kind: K,
  row: PayloadRow,
  expectedId?: DbModels[K]["id"],
): DbModels[K] =>
  assertModelIdentity(
    kind,
    expectedId,
    decodeInlineModel(payloadFromRow(row)),
  )

const rows = (
  db: Database,
  sql: string,
  bind?: BindingSpec,
): PayloadRow[] =>
  db.exec({
    sql,
    ...(bind ? { bind } : {}),
    rowMode: "object",
    returnValue: "resultRows",
  })

const firstRow = (
  db: Database,
  sql: string,
  bind?: BindingSpec,
): PayloadRow | undefined => rows(db, sql, bind)[0]

const getModel = <K extends DbObjectKind>(
  db: Database,
  kind: K,
  id: DbModels[K]["id"],
): DbModels[K] | undefined => {
  let row: PayloadRow | undefined
  if (kind === DbObjectKind.Message) {
    const [targetChatId, targetMessageId] = String(id).split(":")
    if (!targetChatId || !targetMessageId) return undefined
    row = firstRow(
      db,
      "SELECT payload FROM message WHERE chat_id = ? AND message_id = ?",
      [exactId(targetChatId), exactId(targetMessageId)],
    )
  } else {
    row = firstRow(
      db,
      `SELECT payload FROM ${tableByKind[kind]} WHERE ${
        kind === DbObjectKind.ReservedChatID ? "chat_id" : "id"
      } = ?`,
      [
        kind === DbObjectKind.SyncGlobalState
          ? id as number
          : kind === DbObjectKind.User ||
              kind === DbObjectKind.Space ||
              kind === DbObjectKind.Chat ||
              kind === DbObjectKind.Dialog ||
              kind === DbObjectKind.ReservedChatID
            ? exactId(String(id))
            : String(id),
      ],
    )
  }
  return row ? decodeRow(kind, row, id) : undefined
}

const allModels = <K extends DbObjectKind>(
  db: Database,
  kind: K,
): DbModels[K][] =>
  rows(
    db,
    `SELECT payload FROM ${tableByKind[kind]}`,
  ).map((row) => decodeRow(kind, row))

const messageWindow = (
  db: Database,
  targetChatId: ChatID,
  limit: number,
  before?: MessageWindowCursor,
  after?: MessageWindowCursor,
): Message[] => {
  if (!Number.isSafeInteger(limit) || limit <= 0 || (before && after)) {
    return []
  }

  const date = before?.date ?? after?.date
  const targetMessageId = before?.messageId ?? after?.messageId
  const direction = after ? "ASC" : "DESC"
  const comparator = after ? ">" : before ? "<" : undefined
  const result = rows(
    db,
    `
      SELECT payload
      FROM message
      WHERE chat_id = ?
      ${
        comparator
          ? `AND (date_order, message_id) ${comparator} (?, ?)`
          : ""
      }
      ORDER BY date_order ${direction}, message_id ${direction}
      LIMIT ?
    `,
    comparator
      ? [
          exactId(targetChatId),
          messageWindowDate(date),
          exactId(targetMessageId!),
          limit,
        ]
      : [exactId(targetChatId), limit],
  ).map((row) => decodeRow(DbObjectKind.Message, row))

  return after ? result : result.reverse()
}

const messageWindowAround = (
  db: Database,
  targetChatId: ChatID,
  targetMessageId: MessageID,
  beforeLimit: number,
  afterLimit: number,
): Message[] => {
  if (
    !Number.isSafeInteger(beforeLimit) ||
    !Number.isSafeInteger(afterLimit) ||
    beforeLimit < 0 ||
    afterLimit < 0
  ) {
    return []
  }
  const target = getModel(
    db,
    DbObjectKind.Message,
    messageKey(targetChatId, targetMessageId),
  )
  if (!target) return []
  const cursor = {
    date: messageWindowDate(target.date),
    messageId: target.messageId,
  }
  const older = rows(
    db,
    `
      SELECT payload
      FROM message
      WHERE chat_id = ?
        AND (date_order, message_id) <= (?, ?)
      ORDER BY date_order DESC, message_id DESC
      LIMIT ?
    `,
    [
      exactId(targetChatId),
      cursor.date,
      exactId(cursor.messageId),
      beforeLimit + 1,
    ],
  )
    .map((row) => decodeRow(DbObjectKind.Message, row))
    .reverse()
  const newer = afterLimit === 0
    ? []
    : messageWindow(db, targetChatId, afterLimit, undefined, cursor)
  return older.concat(newer).sort(compareMessagesByWindow)
}

type SqliteWrite = {
  sql: string
  bind: BindableValue[]
}

const putWrite = (model: DbModel): SqliteWrite => {
  const payload = encodeInlineModel(model)
  switch (model.kind) {
    case DbObjectKind.User:
      return {
        sql: `INSERT INTO user(id, payload) VALUES (?, ?)
          ON CONFLICT(id) DO UPDATE SET payload = excluded.payload`,
        bind: [exactId(model.id), payload],
      }
    case DbObjectKind.Space:
      return {
        sql: `INSERT INTO space(id, date, payload) VALUES (?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET date = excluded.date, payload = excluded.payload`,
        bind: [exactId(model.id), model.date, payload],
      }
    case DbObjectKind.Chat:
      return {
        sql: `INSERT INTO chat(id, space_id, last_message_id, date, payload)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            space_id = excluded.space_id,
            last_message_id = excluded.last_message_id,
            date = excluded.date,
            payload = excluded.payload`,
        bind: [
          exactId(model.id),
          optionalExactId(model.spaceId),
          optionalExactId(model.lastMsgId),
          model.date ?? null,
          payload,
        ],
      }
    case DbObjectKind.Dialog:
      return {
        sql: `INSERT INTO dialog(
            id, chat_id, space_id, is_open, is_pinned, is_archived,
            is_chat_list_hidden, sidebar_order, pinned_order, payload
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            chat_id = excluded.chat_id,
            space_id = excluded.space_id,
            is_open = excluded.is_open,
            is_pinned = excluded.is_pinned,
            is_archived = excluded.is_archived,
            is_chat_list_hidden = excluded.is_chat_list_hidden,
            sidebar_order = excluded.sidebar_order,
            pinned_order = excluded.pinned_order,
            payload = excluded.payload`,
        bind: [
          exactId(model.id),
          exactId(model.chatId),
          optionalExactId(model.spaceId),
          flag(model.open),
          flag(model.pinned),
          flag(model.archived),
          flag(model.chatListHidden),
          model.order ?? null,
          model.pinnedOrder ?? null,
          payload,
        ],
      }
    case DbObjectKind.Message:
      return {
        sql: `INSERT INTO message(chat_id, message_id, date_order, payload)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(chat_id, message_id) DO UPDATE SET
            date_order = excluded.date_order,
            payload = excluded.payload`,
        bind: [
          exactId(model.chatId),
          exactId(model.messageId),
          messageWindowDate(model.date),
          payload,
        ],
      }
    case DbObjectKind.SyncGlobalState:
      return {
        sql: `INSERT INTO sync_global_state(id, last_sync_date, payload)
          VALUES (?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            last_sync_date = excluded.last_sync_date,
            payload = excluded.payload`,
        bind: [model.id, model.lastSyncDate, payload],
      }
    case DbObjectKind.SyncBucketState:
      return {
        sql: `INSERT INTO sync_bucket_state(id, seq, date, payload)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            seq = excluded.seq,
            date = excluded.date,
            payload = excluded.payload`,
        bind: [model.id, model.seq, model.date, payload],
      }
    case DbObjectKind.DeferredUpdate:
      return {
        sql: `INSERT INTO deferred_update(
            id, bucket_id, target_key, seq, date, payload
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            bucket_id = excluded.bucket_id,
            target_key = excluded.target_key,
            seq = excluded.seq,
            date = excluded.date,
            payload = excluded.payload`,
        bind: [
          model.id,
          model.bucketId,
          model.targetKey ?? null,
          model.seq ?? null,
          model.date ?? null,
          payload,
        ],
      }
    case DbObjectKind.PendingTransaction:
      return {
        sql: `INSERT INTO pending_transaction(
            id, transaction_type, status, created_at, payload
          ) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            transaction_type = excluded.transaction_type,
            status = excluded.status,
            created_at = excluded.created_at,
            payload = excluded.payload`,
        bind: [
          model.id,
          model.type,
          model.status,
          model.createdAt,
          payload,
        ],
      }
    case DbObjectKind.ReservedChatID:
      return {
        sql: `INSERT INTO reserved_chat_id(
            chat_id, expires_at, created_at, payload
          ) VALUES (?, ?, ?, ?)
          ON CONFLICT(chat_id) DO UPDATE SET
            expires_at = excluded.expires_at,
            created_at = excluded.created_at,
            payload = excluded.payload`,
        bind: [
          exactId(model.chatId),
          model.expiresAt,
          model.createdAt,
          payload,
        ],
      }
    case DbObjectKind.MessageDraft:
      return {
        sql: `INSERT INTO message_draft(
            id, peer_kind, peer_user_id, peer_thread_id,
            revision, updated_at, payload
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            peer_kind = excluded.peer_kind,
            peer_user_id = excluded.peer_user_id,
            peer_thread_id = excluded.peer_thread_id,
            revision = excluded.revision,
            updated_at = excluded.updated_at,
            payload = excluded.payload`,
        bind: [
          model.id,
          model.peerKind,
          optionalExactId(model.peerUserId),
          optionalExactId(model.peerThreadId),
          model.revision,
          model.updatedAt,
          payload,
        ],
      }
  }
}

const deleteWrite = (
  kind: DbObjectKind,
  id: DbModel["id"],
): SqliteWrite => {
  if (kind === DbObjectKind.Message) {
    const [targetChatId, targetMessageId] = String(id).split(":")
    if (!targetChatId || !targetMessageId) {
      throw new InlineSqliteCorruptionError(
        `Invalid Inline message key ${String(id)}`,
      )
    }
    return {
      sql: "DELETE FROM message WHERE chat_id = ? AND message_id = ?",
      bind: [exactId(targetChatId), exactId(targetMessageId)],
    }
  }
  const value =
    kind === DbObjectKind.SyncGlobalState
      ? id as number
      : kind === DbObjectKind.User ||
          kind === DbObjectKind.Space ||
          kind === DbObjectKind.Chat ||
          kind === DbObjectKind.Dialog ||
          kind === DbObjectKind.ReservedChatID
        ? exactId(String(id))
        : String(id)
  return {
    sql: `DELETE FROM ${tableByKind[kind]} WHERE ${
      kind === DbObjectKind.ReservedChatID ? "chat_id" : "id"
    } = ?`,
    bind: [value],
  }
}

class StatementCache {
  private readonly statements = new Map<string, PreparedStatement>()

  constructor(private readonly db: Database) {}

  run(write: SqliteWrite) {
    let statement = this.statements.get(write.sql)
    if (!statement) {
      statement = this.db.prepare(write.sql)
      this.statements.set(write.sql, statement)
    }
    statement.bind(write.bind).stepReset()
    statement.clearBindings()
  }

  close() {
    for (const statement of this.statements.values()) {
      statement.finalize()
    }
    this.statements.clear()
  }
}

export class InlineSqliteCorruptionError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "InlineSqliteCorruptionError"
  }
}

class SQLiteCollection<K extends DbObjectKind>
  implements InlinePersistenceCollection<DbModels[K]>
{
  constructor(
    private readonly store: SQLitePersistenceStore,
    private readonly kind: K,
  ) {}

  async init() {
    await this.store.database()
  }

  async get(id: DbModels[K]["id"]) {
    return getModel(await this.store.database(), this.kind, id)
  }

  async getMany(ids: DbModels[K]["id"][]) {
    const db = await this.store.database()
    return ids.flatMap((id) => {
      const model = getModel(db, this.kind, id)
      return model ? [model] : []
    })
  }

  async getAll() {
    return allModels(await this.store.database(), this.kind)
  }

  async getDeferredUpdatesByTargetKeys(targetKeys: string[]) {
    if (
      this.kind !== DbObjectKind.DeferredUpdate ||
      targetKeys.length === 0
    ) {
      return []
    }
    const db = await this.store.database()
    const result: DbModels[K][] = []
    for (const targetKey of new Set(targetKeys)) {
      result.push(
        ...rows(
          db,
          `SELECT payload FROM deferred_update
           WHERE target_key = ?
           ORDER BY seq, date, id`,
          [targetKey],
        ).map((row) => decodeRow(this.kind, row)),
      )
    }
    return result
  }

  async getMessageWindowByChatId(
    targetChatId: ChatID,
    limit: number,
    before?: MessageWindowCursor,
    after?: MessageWindowCursor,
  ) {
    if (this.kind !== DbObjectKind.Message) return []
    return messageWindow(
      await this.store.database(),
      targetChatId,
      limit,
      before,
      after,
    ) as DbModels[K][]
  }

  async getMessageWindowAroundMessageId(
    targetChatId: ChatID,
    targetMessageId: MessageID,
    beforeLimit: number,
    afterLimit: number,
  ) {
    if (this.kind !== DbObjectKind.Message) return []
    return messageWindowAround(
      await this.store.database(),
      targetChatId,
      targetMessageId,
      beforeLimit,
      afterLimit,
    ) as DbModels[K][]
  }

  async deleteAllByChatId(targetChatId: ChatID) {
    if (this.kind !== DbObjectKind.Message) return
    await this.store.write([
      { type: "deleteMessagesByChat", chatId: targetChatId },
    ])
  }

  async put(object: DbModels[K]) {
    await this.store.write([{ type: "put", object }])
  }

  async delete(id: DbModels[K]["id"]) {
    await this.store.write([
      { type: "delete", kind: this.kind, id },
    ])
  }
}

export class SQLitePersistenceStore implements InlinePersistenceStore {
  private databasePromise: Promise<Database> | null = null
  private readonly collections = new Map<
    DbObjectKind,
    InlinePersistenceCollection<any>
  >()

  constructor(
    private readonly openDatabase: OpenInlineSqliteDatabase,
    private readonly options: SQLitePersistenceStoreOptions = {},
  ) {}

  async open(): Promise<void> {
    await this.database()
  }

  database(): Promise<Database> {
    if (!this.databasePromise) {
      this.databasePromise = this.openDatabase().then((db) => {
        try {
          migrateInlineSqlite(db)
          return db
        } catch (error) {
          db.close()
          throw error
        }
      })
    }
    return this.databasePromise
  }

  collection<K extends DbObjectKind>(kind: K) {
    let collection = this.collections.get(kind)
    if (!collection) {
      collection = new SQLiteCollection(this, kind)
      this.collections.set(kind, collection)
    }
    return collection as InlinePersistenceCollection<DbModels[K]>
  }

  async write(operations: readonly InlinePersistenceOperation[]) {
    if (operations.length === 0) return
    const db = await this.database()
    const writes = operations.map((operation): SqliteWrite => {
      switch (operation.type) {
        case "put":
          return putWrite(operation.object)
        case "delete":
          return deleteWrite(operation.kind, operation.id)
        case "deleteMessagesByChat":
          return {
            sql: "DELETE FROM message WHERE chat_id = ?",
            bind: [exactId(operation.chatId)],
          }
      }
    })
    const statements = new StatementCache(db)
    let committed = false
    db.exec("BEGIN IMMEDIATE")
    try {
      await this.options.onWriteCheckpoint?.({
        phase: "after-begin",
        operationCount: writes.length,
      })
      for (const write of writes) {
        statements.run(write)
      }
      await this.options.onWriteCheckpoint?.({
        phase: "before-commit",
        operationCount: writes.length,
      })
      db.exec("COMMIT")
      committed = true
      await this.options.onWriteCheckpoint?.({
        phase: "after-commit",
        operationCount: writes.length,
      })
    } catch (error) {
      if (!committed) {
        try {
          db.exec("ROLLBACK")
        } catch {
          // Preserve the original write failure.
        }
      }
      throw error
    } finally {
      statements.close()
    }
  }

  async getReplicaMetadata(key: string): Promise<string | undefined> {
    const row = firstRow(
      await this.database(),
      "SELECT value FROM inline_replica_metadata WHERE key = ?",
      [key],
    )
    return typeof row?.value === "string" ? row.value : undefined
  }

  async setReplicaMetadata(key: string, value: string): Promise<void> {
    const db = await this.database()
    db.exec({
      sql: `INSERT INTO inline_replica_metadata(key, value, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
          value = excluded.value,
          updated_at = excluded.updated_at`,
      bind: [key, value, Date.now()],
    })
  }

  async close() {
    const promise = this.databasePromise
    this.databasePromise = null
    if (!promise) return
    const db = await promise.catch(() => undefined)
    db?.close()
  }
}
