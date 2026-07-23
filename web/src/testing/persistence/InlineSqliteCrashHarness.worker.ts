import {
  Db,
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type InlinePersistenceOperation,
  type Message,
} from "@inline/client/core"
import {
  createOpfsSqlitePersistenceStore,
  type InlineSqliteWriteCheckpoint,
} from "@inline/client/sqlite"
import { chatId, messageId, userId } from "@inline/ids"
import type {
  InlineSqliteCrashHarnessRequest,
  InlineSqliteCrashHarnessResponse,
  InlineSqliteCrashSnapshot,
} from "./InlineSqliteCrashHarnessProtocol"

type CrashWorkerScope = {
  postMessage(message: InlineSqliteCrashHarnessResponse): void
  addEventListener(
    type: "message",
    listener: (event: MessageEvent<InlineSqliteCrashHarnessRequest>) => void,
  ): void
}

const scope = self as unknown as CrashWorkerScope
const targetChatId = chatId("900000000000000041")
const senderId = userId("900000000000000042")
const temporaryMessageId = messageId(-41)
const finalMessageId = messageId(4100)
const temporaryKey = messageKey(targetChatId, temporaryMessageId)
const finalKey = messageKey(targetChatId, finalMessageId)
const outboxId = "sqlite-crash-outbox"
const bucketId = `chat:${targetChatId}`

const temporaryMessage: Message = {
  kind: DbObjectKind.Message,
  id: temporaryKey,
  chatId: targetChatId,
  messageId: temporaryMessageId,
  fromId: senderId,
  date: 1_700_000_100,
  message: "Accepted before crash",
  out: true,
  randomId: 9223372036854775700n,
  status: MessageSendingStatus.Sending,
}

const finalMessage: Message = {
  ...temporaryMessage,
  id: finalKey,
  messageId: finalMessageId,
  date: 1_700_000_200,
  status: MessageSendingStatus.Sent,
}

const baselineOperations: InlinePersistenceOperation[] = [
  { type: "delete", kind: DbObjectKind.Message, id: temporaryKey },
  { type: "delete", kind: DbObjectKind.Message, id: finalKey },
  {
    type: "delete",
    kind: DbObjectKind.PendingTransaction,
    id: outboxId,
  },
  { type: "delete", kind: DbObjectKind.SyncGlobalState, id: 0 },
  {
    type: "delete",
    kind: DbObjectKind.SyncBucketState,
    id: bucketId,
  },
  { type: "put", object: temporaryMessage },
  {
    type: "put",
    object: {
      kind: DbObjectKind.PendingTransaction,
      id: outboxId,
      type: "send_message",
      replayPolicy: "idempotent",
      context: {
        chatId: targetChatId,
        randomId: temporaryMessage.randomId,
        temporaryMessageId,
      },
      createdAt: 1_700_000_100_000,
      status: "pending",
    },
  },
  {
    type: "put",
    object: {
      kind: DbObjectKind.SyncGlobalState,
      id: 0,
      lastSyncDate: 100,
    },
  },
  {
    type: "put",
    object: {
      kind: DbObjectKind.SyncBucketState,
      id: bucketId,
      seq: 1,
      date: 100,
    },
  },
]

const snapshot = async (
  store: ReturnType<typeof createOpfsSqlitePersistenceStore>,
): Promise<InlineSqliteCrashSnapshot> => {
  const [temporary, final, outbox, global, bucket] = await Promise.all([
    store.collection(DbObjectKind.Message).get(temporaryKey),
    store.collection(DbObjectKind.Message).get(finalKey),
    store
      .collection(DbObjectKind.PendingTransaction)
      .get(outboxId),
    store.collection(DbObjectKind.SyncGlobalState).get(0),
    store.collection(DbObjectKind.SyncBucketState).get(bucketId),
  ])
  return {
    temporaryStatus: temporary?.status,
    finalStatus: final?.status,
    outboxStatus: outbox?.status,
    lastSyncDate: global?.lastSyncDate,
    bucketSeq: bucket?.seq,
    bucketDate: bucket?.date,
  }
}

const run = async (request: InlineSqliteCrashHarnessRequest) => {
  const targetCheckpoint = request.checkpoint
  const store = createOpfsSqlitePersistenceStore(
    userId(request.accountId),
    targetCheckpoint
      ? {
          onWriteCheckpoint: async (
            checkpoint: InlineSqliteWriteCheckpoint,
          ) => {
            if (checkpoint.phase !== targetCheckpoint) return
            scope.postMessage({
              type: "checkpoint",
              checkpoint: targetCheckpoint,
              operationCount: checkpoint.operationCount,
            })
            await new Promise<void>(() => undefined)
          },
        }
      : undefined,
  )
  try {
    await store.open()
    switch (request.action) {
      case "seed":
        await store.write(baselineOperations)
        return {
          type: "result" as const,
          action: request.action,
          snapshot: await snapshot(store),
        }
      case "transition":
        {
          const db = new Db({
            autoHydrate: false,
            persistenceStore: store,
          })
          await db.hydrateKinds([
            DbObjectKind.PendingTransaction,
            DbObjectKind.SyncGlobalState,
            DbObjectKind.SyncBucketState,
          ])
          await db.hydrateMessageWindow(targetChatId, { limit: 20 })
          await db.commit(() => {
            db.delete(db.ref(DbObjectKind.Message, temporaryKey))
            db.insert(finalMessage)
            db.delete(
              db.ref(DbObjectKind.PendingTransaction, outboxId),
            )
            db.replace({
              kind: DbObjectKind.SyncGlobalState,
              id: 0,
              lastSyncDate: 200,
            })
            db.replace({
              kind: DbObjectKind.SyncBucketState,
              id: bucketId,
              seq: 2,
              date: 200,
            })
          })
        }
        throw new Error(
          `SQLite crash transition passed ${String(targetCheckpoint)}`,
        )
      case "verify":
        return {
          type: "result" as const,
          action: request.action,
          snapshot: await snapshot(store),
        }
    }
  } finally {
    await store.close()
  }
}

scope.addEventListener("message", (event) => {
  void run(event.data).then(
    (result) => scope.postMessage(result),
    (error: unknown) =>
      scope.postMessage({
        type: "error",
        name: error instanceof Error ? error.name : "Error",
        message: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : undefined,
      }),
  )
})
