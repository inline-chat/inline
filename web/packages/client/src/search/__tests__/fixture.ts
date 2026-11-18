import type { Database, SqlValue } from "@sqlite.org/sqlite-wasm"
import type { Update } from "@inline-chat/protocol/core"
import {
  chatId as makeChatId,
  messageId as makeMessageId,
  userId as makeUserId,
  type ChatID,
} from "@inline/ids"
import { Db } from "../../database"
import { decodeInlineModel } from "../../database/model-codec"
import { DbObjectKind, messageKey, type Message } from "../../database/models"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import {
  SQLitePersistenceStore,
  type SQLitePersistenceStoreOptions,
} from "../../database/sqlite/SQLitePersistenceStore"
import { MessageSearch, type MessageSearchOptions } from "../engine"
import { searchEntryOf } from "../index-writer"

export const SELF = makeUserId(1)

export const message = (
  chat: number | bigint,
  id: number | bigint,
  text: string | undefined,
  extra: Partial<Message> = {},
): Message => {
  const chatId = makeChatId(chat)
  const messageId = makeMessageId(id)
  return {
    kind: DbObjectKind.Message,
    id: messageKey(chatId, messageId),
    chatId,
    messageId,
    fromId: makeUserId(2),
    date: 1_700_000_000 + Number(id),
    ...(text !== undefined ? { message: text } : {}),
    ...extra,
  }
}

export const chatPeer = (chatId: bigint) => ({
  type: { oneofKind: "chat" as const, chat: { chatId } },
})

export const newMessageUpdate = (chat: bigint, id: bigint, text: string, date = 1_700_000_000n + id): Update =>
  ({
    update: {
      oneofKind: "newMessage",
      newMessage: {
        message: { id, chatId: chat, fromId: 2n, peerId: chatPeer(chat), out: false, date, message: text },
      },
    },
  }) as unknown as Update

export const editMessageUpdate = (chat: bigint, id: bigint, text: string): Update =>
  ({
    update: {
      oneofKind: "editMessage",
      editMessage: {
        message: { id, chatId: chat, fromId: 2n, peerId: chatPeer(chat), out: false, date: 1_700_000_000n + id, message: text },
      },
    },
  }) as unknown as Update

export const deleteMessagesUpdate = (chat: bigint, ids: bigint[]): Update =>
  ({
    update: { oneofKind: "deleteMessages", deleteMessages: { peerId: chatPeer(chat), messageIds: ids } },
  }) as unknown as Update

export const clearHistoryUpdate = (chat: bigint): Update =>
  ({
    update: {
      oneofKind: "clearChatHistory",
      clearChatHistory: { target: { oneofKind: "peerId", peerId: chatPeer(chat) } },
    },
  }) as unknown as Update

export const deleteChatUpdate = (chat: bigint): Update =>
  ({ update: { oneofKind: "deleteChat", deleteChat: { peerId: chatPeer(chat) } } }) as unknown as Update

/** A Db on a fresh in-memory replica, with its search engine. */
export const openSearchDb = async (
  options: Partial<Omit<MessageSearchOptions, "db" | "store">> & {
    store?: SQLitePersistenceStore
    storeOptions?: SQLitePersistenceStoreOptions
  } = {},
) => {
  const store = options.store ?? createSqliteMemoryPersistenceStore(options.storeOptions)
  await store.open()
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  const search = new MessageSearch({ pause: async () => {}, ...options, db, store })
  return {
    db,
    store,
    search,
    insertChat(id: number | bigint, extra: Record<string, unknown> = {}) {
      db.insert({ kind: DbObjectKind.Chat, id: makeChatId(id), title: `Chat ${id}`, ...extra })
    },
    async texts(query: string, extra: { chatId?: ChatID } = {}) {
      const page = await search.search({ query, limit: 100, ...extra })
      return page.hits.map((hit) => hit.text)
    },
    async close() {
      await search.stop()
      await db.flushPersistence().catch(() => undefined)
      await store.close()
    },
  }
}

/** One in-memory database shared by several store "processes". */
export const sharedDatabase = async (): Promise<{ database: Database; dispose: () => void }> => {
  const { default: initialize } = await import("@sqlite.org/sqlite-wasm")
  const sqlite3 = await initialize()
  const database = new sqlite3.oo1.DB(":memory:", "c")
  const close = database.close.bind(database)
  database.close = (() => database) as Database["close"]
  return { database, dispose: () => close() }
}

const all = (db: Database, sql: string, bind?: SqlValue[]): SqlValue[][] =>
  db.exec({ sql, ...(bind ? { bind } : {}), rowMode: "array", returnValue: "resultRows" }) as SqlValue[][]

/**
 * Every way the index can disagree with the message rows: an entry without
 * its message, a searchable server message without an entry or with a stale
 * one, an FTS row without a document or the reverse.
 */
export const indexDisagreements = (db: Database): string[] => {
  const problems: string[] = []
  const docs = new Map<string, { id: bigint; hash: number }>()
  for (const [id, chat, messageId, hash] of all(db, "SELECT id, chat_id, message_id, hash FROM message_search_doc")) {
    docs.set(`${chat}:${messageId}`, { id: BigInt(id as number | bigint), hash: Number(hash) })
  }
  const seen = new Set<string>()
  for (const [chat, id, payload] of all(db, "SELECT chat_id, message_id, payload FROM message")) {
    const key = `${chat}:${id}`
    seen.add(key)
    const model = decodeInlineModel(payload as Uint8Array) as Message
    const entry = BigInt(id as number | bigint) > 0n ? searchEntryOf(model) : undefined
    const doc = docs.get(key)
    if (entry && !doc) problems.push(`message ${key} is not indexed`)
    if (!entry && doc) problems.push(`message ${key} should not be indexed`)
    if (entry && doc && doc.hash !== entry.hash) problems.push(`message ${key} is indexed with stale text`)
  }
  for (const key of docs.keys()) {
    if (!seen.has(key)) problems.push(`entry ${key} has no message`)
  }
  const ftsRows = new Set(all(db, "SELECT rowid FROM message_search").map(([rowid]) => String(rowid)))
  const docRows = new Set([...docs.values()].map((doc) => String(doc.id)))
  for (const rowid of ftsRows) if (!docRows.has(rowid)) problems.push(`fts row ${rowid} has no document`)
  for (const rowid of docRows) if (!ftsRows.has(rowid)) problems.push(`document ${rowid} has no fts row`)
  return problems
}

export const disagreements = (store: SQLitePersistenceStore) => store.readSearchIndex(indexDisagreements)
