import {
  Db,
  DbObjectKind,
  DbQueryPlanType,
  messageKey,
  messageWindowCursor,
  type Message,
} from "@inline/client/core"
import {
  chatId,
  messageId,
  userId,
  type ChatID,
} from "@inline/ids"

export type MessageWindowBenchmarkOptions = {
  environment: "browser-indexeddb" | "fake-indexeddb"
  totalMessages?: number
  messagesInTargetChat?: number
  latestLimit?: number
  aroundBeforeLimit?: number
  aroundAfterLimit?: number
  prependLimit?: number
}

export type MessageWindowBenchmarkResult = {
  environment: MessageWindowBenchmarkOptions["environment"]
  totalMessages: number
  messagesInTargetChat: number
  seedMs: number
  latest: {
    elapsedMs: number
    rowsRead: number
    residentMessages: number
  }
  around: {
    elapsedMs: number
    found: boolean
    residentMessages: number
  }
  prepend: {
    elapsedMs: number
    rowsRead: number
    residentMessages: number
  }
  release: {
    elapsedMs: number
    removedMessages: number
    residentMessages: number
  }
  rehydrate: {
    elapsedMs: number
    rowsRead: number
    residentMessages: number
  }
  measuredLongTasks: Array<{ duration: number; startTime: number }>
  usedJsHeapBytes?: number
}

const benchmarkMessage = (
  targetChatId: ChatID,
  id: number,
  date: number,
): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(targetChatId, messageId(id)),
  messageId: messageId(id),
  chatId: targetChatId,
  fromId: userId(7),
  message: `benchmark message ${id}`,
  date,
})

const readResidentMessages = (db: Db, targetChatId: ChatID) =>
  db
    .queryCollection<
      DbObjectKind.Message,
      Message,
      DbQueryPlanType.Objects
    >(DbQueryPlanType.Objects, DbObjectKind.Message)
    .filter((message) => message.chatId === targetChatId)

const invariant = (condition: boolean, message: string) => {
  if (!condition) throw new Error(`Message-window benchmark failed: ${message}`)
}

const settleMeasurements = () =>
  new Promise<void>((resolve) => {
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(() => resolve())
    } else {
      queueMicrotask(resolve)
    }
  })

export async function runMessageWindowBenchmark(
  options: MessageWindowBenchmarkOptions,
): Promise<MessageWindowBenchmarkResult> {
  const totalMessages = options.totalMessages ?? 50_000
  const messagesInTargetChat = options.messagesInTargetChat ?? 10_000
  const latestLimit = options.latestLimit ?? 60
  const aroundBeforeLimit = options.aroundBeforeLimit ?? 30
  const aroundAfterLimit = options.aroundAfterLimit ?? 29
  const prependLimit = options.prependLimit ?? 100
  invariant(
    totalMessages >= messagesInTargetChat && messagesInTargetChat > 200,
    "the corpus must contain a substantial target chat",
  )

  const namespace = `message-window-benchmark-${crypto.randomUUID()}`
  const targetChatId = chatId(10)
  let writer: Db | undefined = new Db({
    autoHydrate: false,
    storageNamespace: namespace,
  })
  const seedStartedAt = performance.now()
  const baseDate = 1_700_000_000

  writer.batch(() => {
    for (let index = 1; index <= totalMessages; index++) {
      const inTargetChat = index <= messagesInTargetChat
      const messageChatId = inTargetChat
        ? targetChatId
        : chatId(20 + Math.floor((index - messagesInTargetChat - 1) / 1_000))
      const localId = inTargetChat
        ? index
        : ((index - messagesInTargetChat - 1) % 1_000) + 1
      writer!.insert(
        benchmarkMessage(
          messageChatId,
          localId,
          baseDate + index,
        ),
      )
    }
  })
  await writer.flushPersistence()
  const seedMs = performance.now() - seedStartedAt
  writer.collections = {}
  writer = undefined
  await settleMeasurements()

  const longTasks: Array<{ duration: number; startTime: number }> = []
  const LongTaskObserver = globalThis.PerformanceObserver
  const observer = LongTaskObserver
    ? new LongTaskObserver((list) => {
        for (const entry of list.getEntries()) {
          longTasks.push({
            duration: entry.duration,
            startTime: entry.startTime,
          })
        }
      })
    : undefined
  try {
    observer?.observe({ type: "longtask" })
  } catch {
    observer?.disconnect()
  }

  const reader = new Db({
    autoHydrate: false,
    storageNamespace: namespace,
  })
  const latestStartedAt = performance.now()
  const latestRowsRead = await reader.hydrateMessageWindow(
    targetChatId,
    { limit: latestLimit },
  )
  const latestElapsedMs = performance.now() - latestStartedAt
  const latestResident = readResidentMessages(reader, targetChatId)
  invariant(latestRowsRead === latestLimit, "latest read returned the wrong row count")
  invariant(latestResident.length === latestLimit, "latest read over-hydrated RAM")

  const anchorId = messageId(Math.floor(messagesInTargetChat / 2))
  const aroundStartedAt = performance.now()
  const found = await reader.loadLocalWindowAroundMessage(
    targetChatId,
    {
      messageId: anchorId,
      beforeLimit: aroundBeforeLimit,
      afterLimit: aroundAfterLimit,
    },
  )
  const aroundElapsedMs = performance.now() - aroundStartedAt
  const aroundResident = readResidentMessages(reader, targetChatId)
  invariant(found, "around-target read did not find its persisted anchor")
  invariant(
    aroundResident.length === aroundBeforeLimit + aroundAfterLimit + 1,
    "around-target read did not replace RAM with the bounded window",
  )
  invariant(
    aroundResident.some((message) => message.messageId === anchorId),
    "around-target resident window omitted its anchor",
  )

  const firstAroundMessage = aroundResident
    .slice()
    .sort((left, right) => (left.date ?? 0) - (right.date ?? 0))[0]
  invariant(firstAroundMessage != null, "around-target window is empty")
  const prependStartedAt = performance.now()
  const prependRowsRead = await reader.hydrateMessageWindow(
    targetChatId,
    {
      limit: prependLimit,
      before: messageWindowCursor(firstAroundMessage!),
    },
  )
  const prependElapsedMs = performance.now() - prependStartedAt
  const prependResident = readResidentMessages(reader, targetChatId)
  invariant(prependRowsRead === prependLimit, "prepend returned the wrong row count")
  invariant(
    prependResident.length ===
      aroundBeforeLimit + aroundAfterLimit + 1 + prependLimit,
    "prepend resident window has the wrong size",
  )

  const releaseStartedAt = performance.now()
  const removedMessages =
    reader.releaseResidentMessageWindow(targetChatId)
  const releaseElapsedMs = performance.now() - releaseStartedAt
  const releasedResident = readResidentMessages(
    reader,
    targetChatId,
  )
  invariant(
    removedMessages === prependResident.length,
    "inactive release did not remove the complete unpinned window",
  )
  invariant(
    releasedResident.length === 0,
    "inactive release retained unneeded history in RAM",
  )

  const rehydrateStartedAt = performance.now()
  const rehydratedRowsRead = await reader.hydrateMessageWindow(
    targetChatId,
    { limit: latestLimit },
  )
  const rehydrateElapsedMs =
    performance.now() - rehydrateStartedAt
  const rehydratedResident = readResidentMessages(
    reader,
    targetChatId,
  )
  invariant(
    rehydratedRowsRead === latestLimit &&
      rehydratedResident.length === latestLimit,
    "released durable history did not selectively rehydrate",
  )

  await settleMeasurements()
  observer?.disconnect()
  const memory = performance as Performance & {
    memory?: { usedJSHeapSize?: number }
  }

  return {
    environment: options.environment,
    totalMessages,
    messagesInTargetChat,
    seedMs,
    latest: {
      elapsedMs: latestElapsedMs,
      rowsRead: latestRowsRead,
      residentMessages: latestResident.length,
    },
    around: {
      elapsedMs: aroundElapsedMs,
      found,
      residentMessages: aroundResident.length,
    },
    prepend: {
      elapsedMs: prependElapsedMs,
      rowsRead: prependRowsRead,
      residentMessages: prependResident.length,
    },
    release: {
      elapsedMs: releaseElapsedMs,
      removedMessages,
      residentMessages: releasedResident.length,
    },
    rehydrate: {
      elapsedMs: rehydrateElapsedMs,
      rowsRead: rehydratedRowsRead,
      residentMessages: rehydratedResident.length,
    },
    measuredLongTasks: longTasks,
    ...(memory.memory?.usedJSHeapSize == null
      ? {}
      : { usedJsHeapBytes: memory.memory.usedJSHeapSize }),
  }
}
