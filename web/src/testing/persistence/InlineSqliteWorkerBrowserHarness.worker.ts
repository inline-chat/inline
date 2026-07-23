import {
  assertInlineLegacyFallbackAllowed,
  createIndexedDbPersistenceStore,
  DbObjectKind,
  InlinePersistenceFallbackOpenError,
  InlinePersistenceReplicaPromotedError,
  InlineStartupPersistenceStore,
  messageDraftKey,
  messageKey,
  type InlinePersistenceOperation,
  type InlinePersistenceStore,
  type Message,
} from "@inline/client/core"
import {
  createOpfsSqlitePersistenceStore,
  InlineSqliteUnavailableError,
  isInlineSqliteStartupFallbackSafe,
} from "@inline/client/sqlite"
import {
  chatId,
  messageId,
  userId,
} from "@inline/ids"
import {
  createInlinePersistenceStore,
} from "../../inline/data/createInlinePersistenceStore"
import { createInlineWorkerPersistenceStore } from "../../inline/data/createInlineWorkerPersistenceStore"

type HarnessPhase = "warmup" | "seed" | "verify" | "selection"

type HarnessRequest = {
  phase: HarnessPhase
}

// Bump only when the persistent browser harness schema/cutover generation
// changes so a run exercises a genuinely fresh account replica.
const accountId = userId("900000000000000021")
const senderId = userId("900000000000000002")
const legacyUserId = userId("900000000000000004")
const targetChatId = chatId("900000000000000003")
const targetMessageCount = 10_000
const totalMessageCount = 50_000
const batchSize = 1_000

const startupFailureStore = (
  error: InlineSqliteUnavailableError,
): InlinePersistenceStore => ({
  open: async () => {
    throw error
  },
  collection: () => {
    throw new Error("A failed startup store has no collections")
  },
  write: async () => {
    throw new Error("A failed startup store cannot write")
  },
  close: async () => {},
})

const otherChatId = (index: number) =>
  chatId(900_000 + Math.floor(index / 1_000))

const messageForIndex = (index: number): Message => {
  const inTarget = index < targetMessageCount
  const localIndex = inTarget
    ? index + 1
    : ((index - targetMessageCount) % 1_000) + 1
  const ownerChatId = inTarget
    ? targetChatId
    : otherChatId(index - targetMessageCount)
  const id = messageId(localIndex)
  return {
    kind: DbObjectKind.Message,
    id: messageKey(ownerChatId, id),
    chatId: ownerChatId,
    messageId: id,
    fromId: senderId,
    date: 1_700_000_000 + localIndex,
    message: `SQLite message ${index + 1}`,
    randomId: BigInt(index + 1),
  }
}

const databaseBytes = async (
  store: ReturnType<typeof createOpfsSqlitePersistenceStore>,
) => {
  const database = await store.database()
  const result = database.exec({
    sql: "SELECT page_count * page_size AS bytes FROM pragma_page_count(), pragma_page_size()",
    rowMode: "object",
    returnValue: "resultRows",
  })[0]?.bytes
  return typeof result === "bigint" ? Number(result) : result
}

const readProof = async (
  store: ReturnType<typeof createOpfsSqlitePersistenceStore>,
) => {
  const messageCollection = store.collection(DbObjectKind.Message)
  const latestStartedAt = performance.now()
  const latest = await messageCollection.getMessageWindowByChatId!(
    targetChatId,
    60,
  )
  const latestMs = performance.now() - latestStartedAt
  const aroundStartedAt = performance.now()
  const around = await messageCollection.getMessageWindowAroundMessageId!(
    targetChatId,
    messageId(5_000),
    30,
    29,
  )
  const aroundMs = performance.now() - aroundStartedAt
  const [user, transaction, sync] = await Promise.all([
    store.collection(DbObjectKind.User).get(senderId),
    store
      .collection(DbObjectKind.PendingTransaction)
      .get("sqlite-browser-outbox"),
    store.collection(DbObjectKind.SyncGlobalState).get(0),
  ])
  return {
    latestMs,
    aroundMs,
    latestCount: latest.length,
    latestFirstId: latest[0]?.messageId,
    latestLastId: latest.at(-1)?.messageId,
    aroundCount: around.length,
    aroundFirstId: around[0]?.messageId,
    aroundLastId: around.at(-1)?.messageId,
    exactUserId: user?.id,
    transactionId: transaction?.id,
    lastSyncDate: sync?.lastSyncDate,
    databaseBytes: await databaseBytes(store),
  }
}

const seed = async (
  store: InlinePersistenceStore,
) => {
  const cleanupChatIds = [
    targetChatId,
    ...Array.from({ length: 40 }, (_, index) => otherChatId(index * 1_000)),
  ]
  await store.write(
    cleanupChatIds.map((target) => ({
      type: "deleteMessagesByChat" as const,
      chatId: target,
    })),
  )

  const startedAt = performance.now()
  let longestBatchMs = 0
  for (let offset = 0; offset < totalMessageCount; offset += batchSize) {
    const operations: InlinePersistenceOperation[] = []
    for (
      let index = offset;
      index < Math.min(totalMessageCount, offset + batchSize);
      index += 1
    ) {
      operations.push({ type: "put", object: messageForIndex(index) })
    }
    const batchStartedAt = performance.now()
    await store.write(operations)
    longestBatchMs = Math.max(
      longestBatchMs,
      performance.now() - batchStartedAt,
    )
  }
  const seedMs = performance.now() - startedAt

  await store.write([
    {
      type: "put",
      object: {
        kind: DbObjectKind.User,
        id: senderId,
        firstName: "SQLite",
        lastName: "Worker",
      },
    },
    {
      type: "put",
      object: {
        kind: DbObjectKind.PendingTransaction,
        id: "sqlite-browser-outbox",
        type: "send_message",
        replayPolicy: "idempotent",
        context: {
          chatId: targetChatId,
          randomId: 9223372036854775807n,
        },
        createdAt: 1_700_000_000_000,
        status: "pending",
      },
    },
    {
      type: "put",
      object: {
        kind: DbObjectKind.SyncGlobalState,
        id: 0,
        lastSyncDate: 1_700_000_123,
      },
    },
  ])
  return { seedMs, longestBatchMs }
}

const selectionProof = async () => {
  const legacySource = createIndexedDbPersistenceStore(
    `user-${accountId}`,
  )
  if (!legacySource) throw new Error("Worker IndexedDB is unavailable")
  const legacySeed = await seed(legacySource)
  const legacyDraftId = messageDraftKey({
    peerKind: "chat",
    peerThreadId: targetChatId,
  })
  await legacySource.write([
    {
      type: "put",
      object: {
        kind: DbObjectKind.User,
        id: legacyUserId,
        firstName: "Legacy",
        lastName: "IndexedDB",
      },
    },
    {
      type: "put",
      object: {
        kind: DbObjectKind.MessageDraft,
        id: legacyDraftId,
        peerKind: "chat",
        peerThreadId: targetChatId,
        text: "Imported before realtime",
        revision: 3,
        updatedAt: 1_700_000_002_000,
      },
    },
    {
      type: "put",
      object: {
        kind: DbObjectKind.PendingTransaction,
        id: "legacy-cutover-outbox",
        type: "send_message",
        replayPolicy: "idempotent",
        context: { randomId: 9223372036854775806n },
        createdAt: 1_700_000_002_000,
        status: "pending",
      },
    },
  ])
  await legacySource.close()

  const primary = createInlineWorkerPersistenceStore({ accountId })
  const primaryOpenStartedAt = performance.now()
  await primary.open()
  const primaryOpenMs = performance.now() - primaryOpenStartedAt
  const primaryPhase = primary.getSelectionSnapshot().phase
  const [importedUser, importedDraft, importedOutbox] = await Promise.all([
    primary.collection(DbObjectKind.User).get(legacyUserId),
    primary.collection(DbObjectKind.MessageDraft).get(legacyDraftId),
    primary
      .collection(DbObjectKind.PendingTransaction)
      .get("legacy-cutover-outbox"),
  ])
  await primary.close()

  const changedLegacySource = createIndexedDbPersistenceStore(
    `user-${accountId}`,
  )
  if (!changedLegacySource) {
    throw new Error("Worker IndexedDB is unavailable after import")
  }
  await changedLegacySource.write([
    {
      type: "put",
      object: {
        kind: DbObjectKind.User,
        id: legacyUserId,
        firstName: "Changed after marker",
      },
    },
  ])
  await changedLegacySource.close()
  const primaryRestart = createInlineWorkerPersistenceStore({ accountId })
  await primaryRestart.open()
  const markedUser = await primaryRestart
    .collection(DbObjectKind.User)
    .get(legacyUserId)
  await primaryRestart.close()

  const unsupported = new InlineSqliteUnavailableError(
    "opfs-unsupported",
  )
  const promotedFallback = new InlineStartupPersistenceStore({
    primary: () => startupFailureStore(unsupported),
    fallback: () =>
      createIndexedDbPersistenceStore(`user-${accountId}`),
    prepareFallback: assertInlineLegacyFallbackAllowed,
    canFallback: isInlineSqliteStartupFallbackSafe,
  })
  const promotedFallbackError = await promotedFallback.open().then(
    () => undefined,
    (error: unknown) => error,
  )
  const promotedFallbackRefused =
    promotedFallbackError instanceof InlinePersistenceFallbackOpenError &&
    promotedFallbackError.fallbackError instanceof
      InlinePersistenceReplicaPromotedError
  const promotedFallbackPhase =
    promotedFallback.getSelectionSnapshot().phase
  await promotedFallback.close()

  const currentRuntime = createInlinePersistenceStore({ accountId })
  if (!currentRuntime) {
    throw new Error("Current IndexedDB runtime is unavailable")
  }
  const currentRuntimeError = await currentRuntime.open().then(
    () => undefined,
    (error: unknown) => error,
  )
  const currentRuntimeRefused =
    currentRuntimeError instanceof InlinePersistenceReplicaPromotedError
  await currentRuntime.close()

  const fallbackNamespace = `sqlite-selection-${accountId}`
  const fallbackFactory = () => {
    const store = createIndexedDbPersistenceStore(fallbackNamespace)
    if (!store) throw new Error("Worker IndexedDB is unavailable")
    return store
  }
  const createFallbackProofStore = () =>
    new InlineStartupPersistenceStore({
      primary: () => startupFailureStore(unsupported),
      fallback: fallbackFactory,
      canFallback: isInlineSqliteStartupFallbackSafe,
    })
  const fallback = createFallbackProofStore()
  await fallback.open()
  await fallback.write([
    {
      type: "put",
      object: {
        kind: DbObjectKind.User,
        id: senderId,
        firstName: "Fallback",
        lastName: "Worker",
      },
    },
    {
      type: "put",
      object: {
        kind: DbObjectKind.PendingTransaction,
        id: "sqlite-selection-outbox",
        type: "send_message",
        replayPolicy: "idempotent",
        context: { randomId: 9223372036854775807n },
        createdAt: 1_700_000_001_000,
        status: "pending",
      },
    },
  ])
  const fallbackPhase = fallback.getSelectionSnapshot().phase
  await fallback.close()

  const restartedFallback = createFallbackProofStore()
  await restartedFallback.open()
  const [persistedUser, persistedOutbox] = await Promise.all([
    restartedFallback.collection(DbObjectKind.User).get(senderId),
    restartedFallback
      .collection(DbObjectKind.PendingTransaction)
      .get("sqlite-selection-outbox"),
  ])
  const restartPhase = restartedFallback.getSelectionSnapshot().phase
  await restartedFallback.close()

  let unsafeFallbackCreated = false
  const unsafeError = new InlineSqliteUnavailableError(
    "opfs-initialization-failed",
  )
  const failClosed = new InlineStartupPersistenceStore({
    primary: () => startupFailureStore(unsafeError),
    fallback: () => {
      unsafeFallbackCreated = true
      return fallbackFactory()
    },
    canFallback: isInlineSqliteStartupFallbackSafe,
  })
  const refusedReason = await failClosed.open().then(
    () => "opened",
    (error: unknown) =>
      error instanceof InlineSqliteUnavailableError
        ? error.reason
        : "unexpected-error",
  )
  await failClosed.close()

  return {
    phase: "selection" as const,
    primaryPhase,
    legacySeedMs: legacySeed.seedMs,
    legacyLongestBatchMs: legacySeed.longestBatchMs,
    primaryOpenMs,
    importedUserName: importedUser?.firstName,
    importedDraftText: importedDraft?.text,
    importedOutboxId: importedOutbox?.id,
    importedOutboxRandomId:
      typeof importedOutbox?.context === "object" &&
      importedOutbox.context &&
      "randomId" in importedOutbox.context
        ? String(importedOutbox.context.randomId)
        : undefined,
    markedUserName: markedUser?.firstName,
    promotedFallbackRefused,
    promotedFallbackPhase,
    currentRuntimeRefused,
    fallbackPhase,
    restartPhase,
    fallbackUserId: persistedUser?.id,
    fallbackOutboxId: persistedOutbox?.id,
    fallbackOutboxRandomId:
      typeof persistedOutbox?.context === "object" &&
      persistedOutbox.context &&
      "randomId" in persistedOutbox.context
        ? String(persistedOutbox.context.randomId)
        : undefined,
    refusedReason,
    unsafeFallbackCreated,
  }
}

const run = async (phase: HarnessPhase) => {
  if (phase === "warmup") return { phase: "warmup" as const }
  if (phase === "selection") return selectionProof()
  const store = createOpfsSqlitePersistenceStore(accountId)
  const openStartedAt = performance.now()
  try {
    await store.database()
    const openMs = performance.now() - openStartedAt
    const seeded = phase === "seed" ? await seed(store) : undefined
    return {
      phase,
      openMs,
      ...seeded,
      ...(await readProof(store)),
    }
  } finally {
    await store.close()
  }
}

self.addEventListener("message", (event: MessageEvent<HarnessRequest>) => {
  void run(event.data.phase).then(
    (result) => self.postMessage({ type: "result", result }),
    (error: unknown) =>
      self.postMessage({
        type: "error",
        error:
          error instanceof Error
            ? {
                name: error.name,
                message: error.message,
                stack: error.stack,
              }
            : { name: "Error", message: String(error) },
      }),
  )
})
