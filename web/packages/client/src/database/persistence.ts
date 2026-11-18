import type { ChatID, MessageID } from "@inline/ids"
import type { DbModel, DbModels, DbObjectKind } from "./models"
import type { MessageWindowCursor } from "./message-window"

/**
 * Durable collection operations required by Inline's resident cache.
 *
 * This is intentionally an Inline-shaped contract rather than a generic
 * database API. Implementations may use SQLite/OPFS or a test
 * store, but the cache only asks for the indexed reads its bootstrap, sync,
 * and message-window paths actually need.
 */
export type InlinePersistenceCollection<
  O extends { id: number | string },
> = {
  init: () => Promise<void>
  get: (id: O["id"]) => Promise<O | undefined>
  getMany?: (ids: O["id"][]) => Promise<O[]>
  getAll: () => Promise<O[]>
  getDeferredUpdatesByTargetKeys?: (
    targetKeys: string[],
  ) => Promise<O[]>
  /** Deferred updates of these kinds, oldest first (schema version 4). */
  getDeferredUpdatesByUpdateTypes?: (
    updateTypes: string[],
  ) => Promise<O[]>
  getMessageWindowByChatId?: (
    chatId: ChatID,
    limit: number,
    before?: MessageWindowCursor,
    after?: MessageWindowCursor,
  ) => Promise<O[]>
  getMessageWindowAroundMessageId?: (
    chatId: ChatID,
    messageId: MessageID,
    beforeLimit: number,
    afterLimit: number,
  ) => Promise<O[]>
  /**
   * A chat's stored messages with server IDs below `beforeMessageId`,
   * newest first, that pass `match` (`chatMedia`). Walks the primary key
   * `(chat_id, message_id)` backwards and stops after `limit` matches or
   * `maxScanned` rows, whichever comes first.
   */
  scanChatMessages?: (
    chatId: ChatID,
    match: (object: O) => boolean,
    options: ChatMessageScanOptions,
  ) => Promise<ChatMessageScan<O>>
  deleteAllByChatId?: (chatId: ChatID) => Promise<void>
  put: (object: O) => Promise<void>
  delete: (id: O["id"]) => Promise<void>
}

export type ChatMessageScanOptions = {
  limit: number
  /** Rows read (decoded) at most, matching or not. */
  maxScanned: number
  /** Exclusive upper bound; omitted: from the newest. */
  beforeMessageId?: MessageID
}

export type ChatMessageScan<O> = {
  matches: O[]
  scanned: number
  /** No stored message with a server ID is left below the last one read. */
  exhausted: boolean
  /** The lowest message ID read: the next scan's `beforeMessageId`. */
  lowest?: MessageID
}

export type InlinePersistenceOperation =
  | { type: "put"; object: DbModel }
  | {
      type: "delete"
      kind: DbObjectKind
      id: DbModel["id"]
    }
  | {
      type: "deleteMessagesByChat"
      chatId: ChatID
    }
  | {
      /**
       * Delete a chat's stored messages with IDs in [fromId, toId] except
       * `keep`. A certified history page proves those rows no longer exist.
       */
      type: "deleteMessagesInRange"
      chatId: ChatID
      fromId: MessageID
      toId: MessageID
      keep: MessageID[]
    }

export type InlinePersistenceScanPage<K extends DbObjectKind> = {
  objects: DbModels[K][]
  nextId?: DbModels[K]["id"]
  done: boolean
}

/**
 * One account-owned persistence writer. `write` must apply the complete
 * operation list atomically across Inline object kinds.
 */
export interface InlinePersistenceStore {
  /** Open and migrate this account store before any product hydration. */
  open(): Promise<void>
  collection<K extends DbObjectKind>(
    kind: K,
  ): InlinePersistenceCollection<DbModels[K]>
  write(
    operations: readonly InlinePersistenceOperation[],
  ): Promise<void>
  /** Bounded source scan used only by forward replica import tooling. */
  scan?<K extends DbObjectKind>(
    kind: K,
    afterId: DbModels[K]["id"] | undefined,
    limit: number,
  ): Promise<InlinePersistenceScanPage<K>>
  /**
   * Account-replica coordination metadata. Adapters which participate in a
   * storage-engine cutover must implement both methods; ordinary in-memory
   * projections do not need them.
   */
  getReplicaMetadata?(key: string): Promise<string | undefined>
  setReplicaMetadata?(key: string, value: string): Promise<void>
  /**
   * Release this account owner's handles without deleting data. Collection
   * facades remain valid and may reopen when the same owner starts again.
   */
  close(): Promise<void>
}
