import {
  Update,
} from "@inline-chat/protocol/core"
import {
  chatId,
  dialogId,
  inlineIdOrderKey,
  messageId,
  photoId,
  spaceId,
  userId,
  type ChatID,
  type InlineIDInput,
  type MessageID,
} from "@inline/ids"
import {
  DbModels,
  DbObjectKind,
  type Message,
  messageDraftKey,
  messageKey,
} from "./models"
import {
  messageWindowDate,
  type MessageWindowCursor,
} from "./message-window"
import type {
  InlinePersistenceCollection,
  InlinePersistenceOperation,
  InlinePersistenceScanPage,
  InlinePersistenceStore,
} from "./persistence"
import { preparePersistedModel } from "./persisted-model"

/** @deprecated Import InlinePersistenceCollection from ./persistence. */
export type CollectionStorage<
  O extends { id: number | string },
> = InlinePersistenceCollection<O>
/** @deprecated Import InlinePersistenceOperation from ./persistence. */
export type DatabaseStorageOperation = InlinePersistenceOperation
/** @deprecated Import InlinePersistenceStore from ./persistence. */
export type DatabaseStorage = InlinePersistenceStore

const DEFAULT_DB_NAME = "inline-client-db"
const DEFAULT_STORE_NAME = "objects"
const DEFAULT_KIND_INDEX = "kind"
const LEGACY_MESSAGE_CHAT_ID_INDEX = "message-chat-id"
const DEFAULT_MESSAGE_CHAT_WINDOW_INDEX =
  "message-chat-window"
const DEFAULT_DEFERRED_TARGET_INDEX = "deferred-target-key"
const DEFAULT_REPLICA_METADATA_STORE = "replica-metadata"
const INLINE_INDEXED_DB_IDENTITY_SCHEMA_VERSION = 6
export const INLINE_INDEXED_DB_SCHEMA_VERSION = 7
const MIN_MESSAGE_DATE = Number.MIN_SAFE_INTEGER
const MAX_MESSAGE_DATE = Number.MAX_SAFE_INTEGER
const MIN_MESSAGE_ORDER_KEY = "00000000000000000000"
const MAX_MESSAGE_ORDER_KEY = "18446744073709551615"
const MESSAGE_ORDER_FIELD = "_messageIdOrder"
const MESSAGE_DATE_FIELD = "_messageDateOrder"

type StoredObject = DbModels[DbObjectKind] & {
  [MESSAGE_ORDER_FIELD]?: string
  [MESSAGE_DATE_FIELD]?: number
}

type UnknownRecord = Record<string, unknown>

const deferredMessageTargetKey = (
  payloadType: unknown,
  payload: unknown,
): string | undefined => {
  if (payloadType !== "Update" || !ArrayBuffer.isView(payload)) {
    return undefined
  }
  try {
    const bytes = new Uint8Array(
      payload.buffer,
      payload.byteOffset,
      payload.byteLength,
    )
    const update = Update.fromBinary(bytes)
    switch (update.update.oneofKind) {
      case "updateReaction": {
        const reaction = update.update.updateReaction.reaction
        return reaction
          ? messageKey(chatId(reaction.chatId), messageId(reaction.messageId))
          : undefined
      }
      case "deleteReaction":
        return messageKey(
          chatId(update.update.deleteReaction.chatId),
          messageId(update.update.deleteReaction.messageId),
        )
      case "messageAttachment": {
        const attachment = update.update.messageAttachment
        if (attachment.chatId <= 0n || attachment.messageId <= 0n) {
          return undefined
        }
        return messageKey(
          chatId(attachment.chatId),
          messageId(attachment.messageId),
        )
      }
      default:
        return undefined
    }
  } catch {
    return undefined
  }
}

export class IndexedDbIdentityMigrationError extends Error {
  constructor(readonly field: string, readonly value: unknown) {
    super(`Cannot migrate lossy Inline ID in ${field}`)
    this.name = "IndexedDbIdentityMigrationError"
  }
}

const idInput = (value: unknown, field: string): InlineIDInput => {
  if (
    typeof value !== "string" &&
    typeof value !== "number" &&
    typeof value !== "bigint"
  ) {
    throw new IndexedDbIdentityMigrationError(field, value)
  }
  return value
}

const requiredId = <T>(
  value: unknown,
  field: string,
  convert: (input: InlineIDInput) => T,
): T => {
  try {
    return convert(idInput(value, field))
  } catch (error) {
    if (error instanceof IndexedDbIdentityMigrationError) throw error
    throw new IndexedDbIdentityMigrationError(field, value)
  }
}

const optionalId = <T>(
  value: unknown,
  field: string,
  convert: (input: InlineIDInput) => T,
): T | undefined =>
  value == null ? undefined : requiredId(value, field, convert)

const optionalIds = <T>(
  value: unknown,
  field: string,
  convert: (input: InlineIDInput) => T,
): T[] | undefined => {
  if (value == null) return undefined
  if (!Array.isArray(value)) {
    throw new IndexedDbIdentityMigrationError(field, value)
  }
  return value.map((item, index) =>
    requiredId(item, `${field}[${index}]`, convert),
  )
}

const migratePendingContext = (
  type: unknown,
  value: unknown,
): unknown => {
  if (!value || typeof value !== "object") return value
  const context = { ...(value as UnknownRecord) }

  switch (type) {
    case "send_message":
      context.chatId = requiredId(context.chatId, "transaction.chatId", chatId)
      context.replyToMsgId = optionalId(
        context.replyToMsgId,
        "transaction.replyToMsgId",
        messageId,
      )
      context.temporaryMessageId = optionalId(
        context.temporaryMessageId,
        "transaction.temporaryMessageId",
        messageId,
      )
      return context
    case "read_messages":
      context.maxId = optionalId(
        context.maxId,
        "transaction.maxId",
        messageId,
      )
      return context
    case "pin_message":
      context.messageId = requiredId(
        context.messageId,
        "transaction.messageId",
        messageId,
      )
      context.previousPinnedMessageIds =
        context.previousPinnedMessageIds === null
          ? null
          : optionalIds(
              context.previousPinnedMessageIds,
              "transaction.previousPinnedMessageIds",
              messageId,
            )
      context.optimisticPinnedMessageIds = optionalIds(
        context.optimisticPinnedMessageIds,
        "transaction.optimisticPinnedMessageIds",
        messageId,
      )
      return context
    default:
      return context
  }
}

/**
 * Converts pre-v4 rows to the canonical web domain representation. Unsafe
 * JavaScript numbers abort the upgrade; silently rounding an Inline ID would
 * corrupt cache identity and is never an acceptable recovery strategy.
 */
export const migrateStoredIdentity = (input: unknown): StoredObject => {
  if (!input || typeof input !== "object") {
    throw new IndexedDbIdentityMigrationError("object", input)
  }
  const value = { ...(input as UnknownRecord) }

  switch (value.kind) {
    case DbObjectKind.User:
      value.id = requiredId(value.id, "user.id", userId)
      if (value.profilePhoto && typeof value.profilePhoto === "object") {
        const profilePhoto = {
          ...(value.profilePhoto as UnknownRecord),
        }
        profilePhoto.photoId = optionalId(
          profilePhoto.photoId,
          "user.profilePhoto.photoId",
          photoId,
        )
        value.profilePhoto = profilePhoto
      }
      break
    case DbObjectKind.Dialog:
      value.id = requiredId(value.id, "dialog.id", dialogId)
      value.chatId = requiredId(value.chatId, "dialog.chatId", chatId)
      value.peerUserId = optionalId(
        value.peerUserId,
        "dialog.peerUserId",
        userId,
      )
      value.peerThreadId = optionalId(
        value.peerThreadId,
        "dialog.peerThreadId",
        chatId,
      )
      value.spaceId = optionalId(value.spaceId, "dialog.spaceId", spaceId)
      value.readMaxId = optionalId(
        value.readMaxId,
        "dialog.readMaxId",
        messageId,
      )
      break
    case DbObjectKind.Chat:
      value.id = requiredId(value.id, "chat.id", chatId)
      value.spaceId = optionalId(value.spaceId, "chat.spaceId", spaceId)
      value.lastMsgId = optionalId(
        value.lastMsgId,
        "chat.lastMsgId",
        messageId,
      )
      value.createdBy = optionalId(value.createdBy, "chat.createdBy", userId)
      value.peerUserId = optionalId(
        value.peerUserId,
        "chat.peerUserId",
        userId,
      )
      value.parentChatId = optionalId(
        value.parentChatId,
        "chat.parentChatId",
        chatId,
      )
      value.parentMessageId = optionalId(
        value.parentMessageId,
        "chat.parentMessageId",
        messageId,
      )
      value.pinnedMessageIds = optionalIds(
        value.pinnedMessageIds,
        "chat.pinnedMessageIds",
        messageId,
      )
      break
    case DbObjectKind.ReservedChatID:
      value.id = requiredId(
        value.id,
        "reservedChatID.id",
        chatId,
      )
      value.chatId = requiredId(
        value.chatId,
        "reservedChatID.chatId",
        chatId,
      )
      if (
        value.id !== value.chatId ||
        typeof value.expiresAt !== "number" ||
        !Number.isSafeInteger(value.expiresAt) ||
        typeof value.createdAt !== "number" ||
        !Number.isSafeInteger(value.createdAt)
      ) {
        throw new IndexedDbIdentityMigrationError(
          "reservedChatID",
          value,
        )
      }
      break
    case DbObjectKind.Message: {
      const legacyId =
        value.messageId ??
        (typeof value.id === "number" || typeof value.id === "bigint"
          ? value.id
          : undefined)
      const exactChatId = requiredId(value.chatId, "message.chatId", chatId)
      const exactMessageId = requiredId(
        legacyId,
        "message.messageId",
        messageId,
      )
      value.chatId = exactChatId
      value.messageId = exactMessageId
      value.id = messageKey(exactChatId, exactMessageId)
      value.fromId = requiredId(value.fromId, "message.fromId", userId)
      value.peerUserId = optionalId(
        value.peerUserId,
        "message.peerUserId",
        userId,
      )
      value.replyToMsgId = optionalId(
        value.replyToMsgId,
        "message.replyToMsgId",
        messageId,
      )
      value[MESSAGE_ORDER_FIELD] = inlineIdOrderKey(exactMessageId)
      value[MESSAGE_DATE_FIELD] = messageWindowDate(
        typeof value.date === "number" ? value.date : undefined,
      )
      break
    }
    case DbObjectKind.Space:
      value.id = requiredId(value.id, "space.id", spaceId)
      break
    case DbObjectKind.MessageDraft: {
      const peerUserId = optionalId(
        value.peerUserId,
        "draft.peerUserId",
        userId,
      )
      const peerThreadId = optionalId(
        value.peerThreadId,
        "draft.peerThreadId",
        chatId,
      )
      if (value.peerKind === "user" && peerUserId != null) {
        value.peerUserId = peerUserId
        value.peerThreadId = undefined
        value.id = messageDraftKey({
          peerKind: "user",
          peerUserId,
        })
      } else if (
        value.peerKind === "chat" &&
        peerThreadId != null
      ) {
        value.peerUserId = undefined
        value.peerThreadId = peerThreadId
        value.id = messageDraftKey({
          peerKind: "chat",
          peerThreadId,
        })
      } else {
        throw new IndexedDbIdentityMigrationError(
          "draft.peer",
          value,
        )
      }
      break
    }
    case DbObjectKind.PendingTransaction:
      if (typeof value.id !== "string") {
        throw new IndexedDbIdentityMigrationError("transaction.id", value.id)
      }
      value.context = migratePendingContext(value.type, value.context)
      break
    case DbObjectKind.SyncGlobalState:
      if (value.id !== 0) {
        throw new IndexedDbIdentityMigrationError("syncGlobal.id", value.id)
      }
      break
    case DbObjectKind.SyncBucketState:
      if (typeof value.id !== "string") {
        throw new IndexedDbIdentityMigrationError("syncBucket.id", value.id)
      }
      break
    case DbObjectKind.DeferredUpdate:
      if (
        typeof value.id !== "string" ||
        typeof value.bucketId !== "string" ||
        (value.payloadType !== "Update" &&
          value.payloadType !== "UserGroup") ||
        typeof value.updateType !== "string" ||
        !ArrayBuffer.isView(value.payload)
      ) {
        throw new IndexedDbIdentityMigrationError(
          "deferredUpdate",
          value,
        )
      }
      value.payload = new Uint8Array(
        value.payload.buffer,
        value.payload.byteOffset,
        value.payload.byteLength,
      )
      value.targetKey =
        typeof value.targetKey === "string"
          ? value.targetKey
          : deferredMessageTargetKey(
              value.payloadType,
              value.payload,
            )
      break
    default:
      throw new IndexedDbIdentityMigrationError("kind", value.kind)
  }

  return value as unknown as StoredObject
}

const encodeStoredObject = <O extends DbModels[DbObjectKind]>(
  object: O,
): StoredObject => {
  if (object.kind !== DbObjectKind.Message) return object
  const persistedMessage = preparePersistedModel(object)
  return {
    ...persistedMessage,
    [MESSAGE_ORDER_FIELD]: inlineIdOrderKey(object.messageId),
    [MESSAGE_DATE_FIELD]: messageWindowDate(object.date),
  } as StoredObject
}

const decodeStoredObject = <O>(value: unknown): O | undefined => {
  if (!value || typeof value !== "object") return undefined
  const {
    [MESSAGE_ORDER_FIELD]: _messageOrder,
    [MESSAGE_DATE_FIELD]: _messageDate,
    ...object
  } = value as UnknownRecord
  return object as O
}

class IndexedDbStorage<K extends DbObjectKind, O extends DbModels[K]> implements CollectionStorage<O> {
  private dbPromise: Promise<IDBDatabase> | null = null

  constructor(
    private kind: K,
    private dbName: string = DEFAULT_DB_NAME,
    private storeName: string = DEFAULT_STORE_NAME,
    private kindIndex: string = DEFAULT_KIND_INDEX,
    private messageChatWindowIndex: string =
      DEFAULT_MESSAGE_CHAT_WINDOW_INDEX,
    private deferredTargetIndex: string =
      DEFAULT_DEFERRED_TARGET_INDEX,
  ) {}

  async init(): Promise<void> {
    await this.open()
  }

  async get(id: O["id"]): Promise<O | undefined> {
    const stored = await this.read((store) => store.get([this.kind, id]))
    return decodeStoredObject<O>(stored)
  }

  async getMany(ids: O["id"][]): Promise<O[]> {
    if (ids.length === 0) return []
    const db = await this.open()

    return await new Promise<O[]>((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readonly")
      const store = transaction.objectStore(this.storeName)
      const objects: O[] = []

      for (const id of ids) {
        const request = store.get([this.kind, id])
        request.onsuccess = () => {
          const object = decodeStoredObject<O>(request.result)
          if (object) objects.push(object)
        }
        request.onerror = () => reject(request.error)
      }

      transaction.oncomplete = () => resolve(objects)
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  async getAll(): Promise<O[]> {
    const values = await this.read((store) =>
      store.index(this.kindIndex).getAll(this.kind),
    )
    return (values as unknown[])
      .map((value) => decodeStoredObject<O>(value))
      .filter((value): value is O => value != null)
  }

  async getDeferredUpdatesByTargetKeys(
    targetKeys: string[],
  ): Promise<O[]> {
    if (
      this.kind !== DbObjectKind.DeferredUpdate ||
      targetKeys.length === 0
    ) {
      return []
    }
    const db = await this.open()
    return await new Promise<O[]>((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readonly")
      const index = transaction
        .objectStore(this.storeName)
        .index(this.deferredTargetIndex)
      const objects: O[] = []

      for (const targetKey of new Set(targetKeys)) {
        const request = index.getAll([
          DbObjectKind.DeferredUpdate,
          targetKey,
        ])
        request.onsuccess = () => {
          for (const value of request.result as unknown[]) {
            const object = decodeStoredObject<O>(value)
            if (object) objects.push(object)
          }
        }
        request.onerror = () => transaction.abort()
      }

      transaction.oncomplete = () => resolve(objects)
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  async getMessageWindowByChatId(
    chatId: ChatID,
    limit: number,
    before?: MessageWindowCursor,
    after?: MessageWindowCursor,
  ): Promise<O[]> {
    if (
      this.kind !== DbObjectKind.Message ||
      limit <= 0 ||
      (before != null && after != null)
    ) {
      return []
    }

    const range = IDBKeyRange.bound(
      [
        this.kind,
        chatId,
        after?.date ?? MIN_MESSAGE_DATE,
        after == null
          ? MIN_MESSAGE_ORDER_KEY
          : inlineIdOrderKey(after.messageId),
      ],
      [
        this.kind,
        chatId,
        before?.date ?? MAX_MESSAGE_DATE,
        before == null
          ? MAX_MESSAGE_ORDER_KEY
          : inlineIdOrderKey(before.messageId),
      ],
      after != null,
      before != null,
    )
    const db = await this.open()

    return await new Promise<O[]>((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readonly")
      const store = transaction.objectStore(this.storeName)
      const request = store
        .index(this.messageChatWindowIndex)
        .openCursor(range, after == null ? "prev" : "next")
      const objects: O[] = []

      request.onsuccess = () => {
        const cursor = request.result
        if (!cursor || objects.length >= limit) {
          resolve(after == null ? objects.reverse() : objects)
          return
        }
        const object = decodeStoredObject<O>(cursor.value)
        if (object) objects.push(object)
        cursor.continue()
      }
      request.onerror = () => reject(request.error)
    })
  }

  async getMessageWindowAroundMessageId(
    chatId: ChatID,
    anchorMessageId: MessageID,
    beforeLimit: number,
    afterLimit: number,
  ): Promise<O[]> {
    if (
      this.kind !== DbObjectKind.Message ||
      beforeLimit < 0 ||
      afterLimit < 0
    ) {
      return []
    }

    const db = await this.open()
    return await new Promise<O[]>((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readonly")
      const store = transaction.objectStore(this.storeName)
      const index = store.index(this.messageChatWindowIndex)
      const targetRequest = store.get([
        this.kind,
        messageKey(chatId, anchorMessageId),
      ])
      const olderOrTarget: O[] = []
      const newer: O[] = []
      let targetFound = false

      targetRequest.onsuccess = () => {
        const target = decodeStoredObject<O>(targetRequest.result)
        if (!target) return
        targetFound = true
        const targetMessage = target as unknown as Message
        const anchorKey = [
          this.kind,
          chatId,
          messageWindowDate(targetMessage.date),
          inlineIdOrderKey(targetMessage.messageId),
        ]

        const olderRequest = index.openCursor(
          IDBKeyRange.bound(
            [
              this.kind,
              chatId,
              MIN_MESSAGE_DATE,
              MIN_MESSAGE_ORDER_KEY,
            ],
            anchorKey,
          ),
          "prev",
        )
        olderRequest.onsuccess = () => {
          const cursor = olderRequest.result
          if (!cursor || olderOrTarget.length >= beforeLimit + 1) return
          const object = decodeStoredObject<O>(cursor.value)
          if (object) olderOrTarget.push(object)
          cursor.continue()
        }
        olderRequest.onerror = () => transaction.abort()

        if (afterLimit > 0) {
          const newerRequest = index.openCursor(
            IDBKeyRange.bound(
              anchorKey,
              [
                this.kind,
                chatId,
                MAX_MESSAGE_DATE,
                MAX_MESSAGE_ORDER_KEY,
              ],
              true,
            ),
            "next",
          )
          newerRequest.onsuccess = () => {
            const cursor = newerRequest.result
            if (!cursor || newer.length >= afterLimit) return
            const object = decodeStoredObject<O>(cursor.value)
            if (object) newer.push(object)
            cursor.continue()
          }
          newerRequest.onerror = () => transaction.abort()
        }
      }
      targetRequest.onerror = () => transaction.abort()
      transaction.oncomplete = () =>
        resolve(
          targetFound
            ? olderOrTarget.reverse().concat(newer)
            : [],
        )
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  async put(object: O): Promise<void> {
    await this.write((store) => {
      store.put(encodeStoredObject(object))
    })
  }

  async delete(id: O["id"]): Promise<void> {
    await this.write((store) => {
      store.delete([this.kind, id])
    })
  }

  async deleteAllByChatId(chatId: ChatID): Promise<void> {
    if (this.kind !== DbObjectKind.Message) return

    const range = IDBKeyRange.bound(
      [
        this.kind,
        chatId,
        MIN_MESSAGE_DATE,
        MIN_MESSAGE_ORDER_KEY,
      ],
      [
        this.kind,
        chatId,
        MAX_MESSAGE_DATE,
        MAX_MESSAGE_ORDER_KEY,
      ],
    )
    const db = await this.open()

    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readwrite")
      const store = transaction.objectStore(this.storeName)
      const request = store
        .index(this.messageChatWindowIndex)
        .openCursor(range)

      request.onsuccess = () => {
        const cursor = request.result
        if (!cursor) return
        cursor.delete()
        cursor.continue()
      }
      request.onerror = () => reject(request.error)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  private open(): Promise<IDBDatabase> {
    if (!this.dbPromise) {
      this.dbPromise = new Promise((resolve, reject) => {
        const request = indexedDB.open(
          this.dbName,
          INLINE_INDEXED_DB_SCHEMA_VERSION,
        )
        let settled = false
        let upgradeError: unknown
        request.onupgradeneeded = (event) => {
          const db = request.result
          if (
            !db.objectStoreNames.contains(
              DEFAULT_REPLICA_METADATA_STORE,
            )
          ) {
            db.createObjectStore(DEFAULT_REPLICA_METADATA_STORE, {
              keyPath: "key",
            })
          }
          let store: IDBObjectStore
          if (!db.objectStoreNames.contains(this.storeName)) {
            store = db.createObjectStore(this.storeName, { keyPath: ["kind", "id"] })
          } else {
            store = request.transaction!.objectStore(this.storeName)
          }
          if (!store.indexNames.contains(this.kindIndex)) {
            store.createIndex(this.kindIndex, "kind", { unique: false })
          }
          if (
            !store.indexNames.contains(this.deferredTargetIndex)
          ) {
            store.createIndex(
              this.deferredTargetIndex,
              ["kind", "targetKey"],
              { unique: false },
            )
          }
          if (event.oldVersion < INLINE_INDEXED_DB_IDENTITY_SCHEMA_VERSION) {
            if (
              store.indexNames.contains(
                LEGACY_MESSAGE_CHAT_ID_INDEX,
              )
            ) {
              store.deleteIndex(LEGACY_MESSAGE_CHAT_ID_INDEX)
            }
            if (
              store.indexNames.contains(
                this.messageChatWindowIndex,
              )
            ) {
              store.deleteIndex(this.messageChatWindowIndex)
            }
            store.createIndex(
              this.messageChatWindowIndex,
              [
                "kind",
                "chatId",
                MESSAGE_DATE_FIELD,
                MESSAGE_ORDER_FIELD,
              ],
              { unique: false },
            )

            const legacyObjects = store.openCursor()
            legacyObjects.onsuccess = () => {
              const cursor = legacyObjects.result
              if (!cursor) return
              try {
                const previous = cursor.value as UnknownRecord
                const migrated = migrateStoredIdentity(previous)
                const previousKey = cursor.primaryKey as [unknown, unknown]
                if (
                  previousKey[0] === migrated.kind &&
                  previousKey[1] === migrated.id
                ) {
                  cursor.update(migrated)
                } else {
                  cursor.delete()
                  store.put(migrated)
                }
                cursor.continue()
              } catch (error) {
                upgradeError = error
                request.transaction?.abort()
              }
            }
          } else if (
            !store.indexNames.contains(
              this.messageChatWindowIndex,
            )
          ) {
            store.createIndex(
              this.messageChatWindowIndex,
              [
                "kind",
                "chatId",
                MESSAGE_DATE_FIELD,
                MESSAGE_ORDER_FIELD,
              ],
              { unique: false },
            )
          }
        }
        request.onsuccess = () => {
          if (settled) {
            request.result.close()
            return
          }
          settled = true
          request.result.onversionchange = () => request.result.close()
          resolve(request.result)
        }
        request.onerror = () => {
          if (settled) return
          settled = true
          reject(upgradeError ?? request.error)
        }
        request.onblocked = () => {
          if (settled) return
          settled = true
          reject(new Error(`IndexedDB upgrade blocked for ${this.dbName}`))
        }
      })
    }
    return this.dbPromise
  }

  database(): Promise<IDBDatabase> {
    return this.open()
  }

  async close(): Promise<void> {
    const promise = this.dbPromise
    this.dbPromise = null
    if (!promise) return
    const database = await promise.catch(() => undefined)
    database?.close()
  }

  private async read<T>(fn: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await this.open()
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readonly")
      const store = transaction.objectStore(this.storeName)
      const request = fn(store)
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }

  private async write(fn: (store: IDBObjectStore) => void): Promise<void> {
    const db = await this.open()
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(this.storeName, "readwrite")
      const store = transaction.objectStore(this.storeName)
      fn(store)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }
}

class IndexedDbPersistenceStore implements InlinePersistenceStore {
  private readonly storageByKind = new Map<
    DbObjectKind,
    IndexedDbStorage<DbObjectKind, DbModels[DbObjectKind]>
  >()
  private readonly batchStorage: IndexedDbStorage<
    DbObjectKind.User,
    DbModels[DbObjectKind.User]
  >

  constructor(private readonly dbName: string) {
    this.batchStorage = new IndexedDbStorage(
      DbObjectKind.User,
      this.dbName,
    )
  }

  async open(): Promise<void> {
    await this.batchStorage.init()
  }

  collection<K extends DbObjectKind>(
    kind: K,
  ): CollectionStorage<DbModels[K]> {
    let storage = this.storageByKind.get(kind)
    if (!storage) {
      storage = new IndexedDbStorage(
        kind,
        this.dbName,
      ) as IndexedDbStorage<
        DbObjectKind,
        DbModels[DbObjectKind]
      >
      this.storageByKind.set(kind, storage)
    }
    return storage as unknown as CollectionStorage<DbModels[K]>
  }

  async write(
    operations: readonly InlinePersistenceOperation[],
  ): Promise<void> {
    if (operations.length === 0) return
    const database = await this.batchStorage.database()

    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction(
        DEFAULT_STORE_NAME,
        "readwrite",
      )
      const store = transaction.objectStore(DEFAULT_STORE_NAME)
      const messageIndex = store.index(
        DEFAULT_MESSAGE_CHAT_WINDOW_INDEX,
      )

      try {
        for (const operation of operations) {
          switch (operation.type) {
            case "put":
              store.put(encodeStoredObject(operation.object))
              break
            case "delete":
              store.delete([operation.kind, operation.id])
              break
            case "deleteMessagesByChat": {
              const range = IDBKeyRange.bound(
                [
                  DbObjectKind.Message,
                  operation.chatId,
                  MIN_MESSAGE_DATE,
                  MIN_MESSAGE_ORDER_KEY,
                ],
                [
                  DbObjectKind.Message,
                  operation.chatId,
                  MAX_MESSAGE_DATE,
                  MAX_MESSAGE_ORDER_KEY,
                ],
              )
              const request = messageIndex.openCursor(range)
              request.onsuccess = () => {
                const cursor = request.result
                if (!cursor) return
                cursor.delete()
                cursor.continue()
              }
              request.onerror = () => transaction.abort()
              break
            }
          }
        }
      } catch (error) {
        transaction.abort()
        reject(error)
      }

      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  async scan<K extends DbObjectKind>(
    kind: K,
    afterId: DbModels[K]["id"] | undefined,
    limit: number,
  ): Promise<InlinePersistenceScanPage<K>> {
    if (!Number.isSafeInteger(limit) || limit <= 0) {
      return { objects: [], done: true }
    }
    const database = await this.batchStorage.database()
    return new Promise((resolve, reject) => {
      const transaction = database.transaction(
        DEFAULT_STORE_NAME,
        "readonly",
      )
      const store = transaction.objectStore(DEFAULT_STORE_NAME)
      const lower = afterId === undefined
        ? [kind]
        : [kind, afterId]
      const range = IDBKeyRange.bound(
        lower,
        [kind, []],
        afterId !== undefined,
      )
      const request = store.openCursor(range)
      const objects: DbModels[K][] = []
      let hasMore = false

      request.onsuccess = () => {
        const cursor = request.result
        if (!cursor) return
        if (objects.length === limit) {
          hasMore = true
          return
        }
        const object = decodeStoredObject<DbModels[K]>(cursor.value)
        if (object) objects.push(object)
        cursor.continue()
      }
      request.onerror = () => reject(request.error)
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
      transaction.oncomplete = () => {
        resolve({
          objects,
          nextId: hasMore ? objects.at(-1)?.id : undefined,
          done: !hasMore,
        })
      }
    })
  }

  async getReplicaMetadata(key: string): Promise<string | undefined> {
    const database = await this.batchStorage.database()
    return new Promise((resolve, reject) => {
      const transaction = database.transaction(
        DEFAULT_REPLICA_METADATA_STORE,
        "readonly",
      )
      const request = transaction
        .objectStore(DEFAULT_REPLICA_METADATA_STORE)
        .get(key)
      request.onsuccess = () => {
        const value = request.result as
          | { key?: unknown; value?: unknown }
          | undefined
        resolve(
          typeof value?.value === "string"
            ? value.value
            : undefined,
        )
      }
      request.onerror = () => reject(request.error)
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  async setReplicaMetadata(key: string, value: string): Promise<void> {
    const database = await this.batchStorage.database()
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction(
        DEFAULT_REPLICA_METADATA_STORE,
        "readwrite",
      )
      transaction.objectStore(DEFAULT_REPLICA_METADATA_STORE).put({
        key,
        value,
        updatedAt: Date.now(),
      })
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  async close(): Promise<void> {
    const storages = new Set([
      this.batchStorage,
      ...this.storageByKind.values(),
    ])
    await Promise.all(
      Array.from(storages, (storage) => storage.close()),
    )
  }
}

const supportsIndexedDb = () => typeof indexedDB !== "undefined" && typeof indexedDB.open === "function"

export const createIndexedDbPersistenceStore = (
  namespace?: string,
): InlinePersistenceStore | null => {
  if (!supportsIndexedDb()) return null
  const dbName = namespace
    ? `${DEFAULT_DB_NAME}:${namespace}`
    : DEFAULT_DB_NAME
  return new IndexedDbPersistenceStore(dbName)
}

/** @deprecated Use the explicit IndexedDB adapter factory. */
export const createDatabaseStorage =
  createIndexedDbPersistenceStore

const createCollectionStorage = <K extends DbObjectKind, O extends DbModels[K]>(
  kind: K,
  namespace?: string,
): CollectionStorage<O> | null => {
  if (supportsIndexedDb()) {
    const dbName = namespace ? `${DEFAULT_DB_NAME}:${namespace}` : DEFAULT_DB_NAME
    return new IndexedDbStorage(kind, dbName)
  }
  return null
}

export { createCollectionStorage }
