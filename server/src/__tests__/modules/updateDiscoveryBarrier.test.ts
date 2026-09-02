import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import { ChatModel } from "@in/server/db/models/chats"
import { chats, updates, UpdateBucket } from "@in/server/db/schema"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import {
  acquireUpdateDiscoveryWriterFence,
  captureUpdateDiscoveryWatermark,
} from "@in/server/modules/updates/updateDiscoveryBarrier"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { setupTestLifecycle, testUtils } from "../setup"

const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((ready) => { resolve = ready })
  return { promise, resolve }
}

const persistChatUpdate = async (chatId: number, afterInsert?: () => Promise<void>) =>
  await db.transaction(async (tx) => {
    const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)
    if (!chat) throw new Error("Fixture chat disappeared")
    const persisted = await UpdatesModel.insertUpdate(tx, {
      bucket: UpdateBucket.Chat,
      entity: chat,
      update: { oneofKind: "pinnedMessages", pinnedMessages: { chatId: BigInt(chatId), messageIds: [] } },
    })
    await tx.update(chats).set({ updateSeq: persisted.seq, lastUpdateDate: persisted.date }).where(eq(chats.id, chatId))
    await afterInsert?.()
  })

describe("update discovery commit barrier", () => {
  setupTestLifecycle()

  test("an exclusive watermark waits for a delayed writer transaction", async () => {
    let writerAcquired: (() => void) | undefined
    const acquired = new Promise<void>((resolve) => {
      writerAcquired = resolve
    })
    let releaseWriter: (() => void) | undefined
    const released = new Promise<void>((resolve) => {
      releaseWriter = resolve
    })

    const writer = db.transaction(async (tx) => {
      const writerDate = await acquireUpdateDiscoveryWriterFence(tx)
      writerAcquired?.()
      await released
      return writerDate
    })

    await acquired
    let watermarkResolved = false
    const watermarkPromise = captureUpdateDiscoveryWatermark().then((watermark) => {
      watermarkResolved = true
      return watermark
    })

    try {
      await Bun.sleep(25)
      expect(watermarkResolved).toBe(false)
    } finally {
      releaseWriter?.()
    }

    const [writerDate, watermark] = await Promise.all([writer, watermarkPromise])
    expect(watermark.getTime()).toBeGreaterThanOrEqual(writerDate.getTime())
  })

  test("a fresh checkpoint waits for a delayed user update and includes its sequence", async () => {
    const user = await testUtils.createUser("discovery-barrier-delayed-user@example.com")
    let updateAllocated: (() => void) | undefined
    const allocated = new Promise<void>((resolve) => {
      updateAllocated = resolve
    })
    let releaseWriter: (() => void) | undefined
    const released = new Promise<void>((resolve) => {
      releaseWriter = resolve
    })

    const writer = db.transaction(async (tx) => {
      await UserBucketUpdates.enqueue(
        {
          userId: user.id,
          update: {
            oneofKind: "userDialogArchived",
            userDialogArchived: {
              peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
              archived: true,
            },
          },
        },
        { tx },
      )
      updateAllocated?.()
      await released
    })

    await allocated
    let checkpointResolved = false
    const checkpointPromise = getUpdatesState(
      {},
      testUtils.functionContext({ userId: user.id }),
    ).then((result) => {
      checkpointResolved = true
      return result
    })

    try {
      await Bun.sleep(25)
      expect(checkpointResolved).toBe(false)
    } finally {
      releaseWriter?.()
    }

    const [, checkpoint] = await Promise.all([writer, checkpointPromise])
    expect(checkpoint).toMatchObject({ seq: 1, updatesFound: false })
  })

  test("a target committed after its resource scan is found by the inclusive follow-up", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers(
      "Discovery Barrier Follow-up",
      ["discovery-barrier-follow-up@example.com"],
    )
    const user = users[0]
    if (!user) throw new Error("Fixture creation failed")
    const chat = await testUtils.createChat(space.id, "Barrier Follow-up Chat", "thread", true)
    if (!chat) throw new Error("Fixture creation failed")

    const checkpoint = await getUpdatesState(
      {},
      testUtils.functionContext({ userId: user.id }),
    )

    const getUserChats = ChatModel.getUserChats
    const scan = spyOn(ChatModel, "getUserChats").mockImplementationOnce(async (input) => {
      const snapshot = await getUserChats(input)
      await persistChatUpdate(chat.id)
      return snapshot
    })
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      const missedInFlight = await getUpdatesState({ date: checkpoint.date }, testUtils.functionContext({ userId: user.id }))
      expect(missedInFlight.updatesFound).toBe(false)
      scan.mockRestore()
      const result = await getUpdatesState(
        { date: missedInFlight.date },
        testUtils.functionContext({ userId: user.id }),
      )
      const hints = push.mock.calls.flatMap(([, updates]) => updates)

      expect(result.date).toBeGreaterThanOrEqual(checkpoint.date)
      expect(result.updatesFound).toBe(true)
      expect(hints.some((hint) =>
        hint.update.oneofKind === "chatHasNewUpdates" &&
        hint.update.chatHasNewUpdates.chatId === BigInt(chat.id) &&
        hint.update.chatHasNewUpdates.updateSeq === 1,
      )).toBe(true)
    } finally {
      scan.mockRestore()
      push.mockRestore()
    }
  })

  test("discovery waits for an uncommitted newly-changed chat before scanning", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Delayed chat discovery", ["delayed-chat-discovery@example.com"])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Delayed chat", "thread", true)
    if (!user || !chat) throw new Error("Fixture missing")
    const inserted = deferred()
    const release = deferred()
    const writer = persistChatUpdate(chat.id, async () => { inserted.resolve(); await release.promise })
    await inserted.promise
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    let resolved = false
    const discovery = getUpdatesState({ date: 1n }, testUtils.functionContext({ userId: user.id })).then((result) => {
      resolved = true
      return result
    })
    try {
      await Bun.sleep(25)
      expect(resolved).toBe(false)
      release.resolve()
      await writer
      expect((await discovery).updatesFound).toBe(true)
      expect(push.mock.calls.flatMap(([, hints]) => hints).some((hint) =>
        hint.update.oneofKind === "chatHasNewUpdates" && hint.update.chatHasNewUpdates.chatId === BigInt(chat.id),
      )).toBe(true)
    } finally {
      release.resolve()
      await Promise.allSettled([writer, discovery])
      push.mockRestore()
    }
  })

  test("discovery does not queue an exclusive waiter in front of a row-owning writer", async () => {
    const chat = await testUtils.createChat(null, "Discovery lock cycle", "thread", false)
    if (!chat) throw new Error("Fixture creation failed")
    const rowLocked = deferred()
    const firstFenced = deferred()
    const requestRow = deferred()
    const secondFence = deferred()
    const secondWriter = db.transaction(async (tx) => {
      await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update")
      rowLocked.resolve()
      await secondFence.promise
      // An exclusive queued waiter used to prevent this shared acquisition,
      // while the already-fenced writer below was waiting for our row.
      await tx.execute(sql`select set_config('lock_timeout', '500ms', true)`)
      await acquireUpdateDiscoveryWriterFence(tx)
    })
    await rowLocked.promise
    const firstWriter = db.transaction(async (tx) => {
      await acquireUpdateDiscoveryWriterFence(tx)
      firstFenced.resolve()
      await requestRow.promise
      await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update")
    })
    await firstFenced.promise
    const watermark = captureUpdateDiscoveryWatermark()
    try {
      await Bun.sleep(30)
      requestRow.resolve()
      await Bun.sleep(30)
      secondFence.resolve()
      await Promise.all([firstWriter, secondWriter, watermark])
    } finally {
      requestRow.resolve()
      secondFence.resolve()
      await Promise.allSettled([firstWriter, secondWriter, watermark])
    }
  })

  test("a rolled-back writer releases the fence without publishing a user sequence", async () => {
    const user = await testUtils.createUser("discovery-barrier-rollback@example.com")
    const inserted = deferred()
    const rollback = deferred()
    const writer = db.transaction(async (tx) => {
      await UserBucketUpdates.enqueue({
        userId: user.id,
        update: { oneofKind: "userDialogArchived", userDialogArchived: {
          peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } }, archived: true,
        } },
      }, { tx })
      inserted.resolve()
      await rollback.promise
      throw new Error("intentional writer rollback")
    }).catch((error: unknown) => error)
    await inserted.promise
    const checkpoint = getUpdatesState({}, testUtils.functionContext({ userId: user.id }))
    try {
      await Bun.sleep(25)
    } finally {
      rollback.resolve()
    }
    expect(await writer).toMatchObject({ message: "intentional writer rollback" })
    expect((await checkpoint).seq).toBe(0)
    const rows = await db.select().from(updates).where(and(
      eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id),
    ))
    expect(rows).toHaveLength(0)
  })

  test("overlapping writer cohorts time out without returning or advancing a checkpoint", async () => {
    const user = await testUtils.createUser("discovery-barrier-timeout@example.com")
    const fenced = deferred()
    const release = deferred()
    const writer = db.transaction(async (tx) => {
      await acquireUpdateDiscoveryWriterFence(tx)
      fenced.resolve()
      await release.promise
    })
    await fenced.promise
    const checkpoint = getUpdatesState({}, testUtils.functionContext({ userId: user.id })).catch((error: unknown) => error)
    const replacementFenced = deferred()
    const releaseReplacement = deferred()
    const replacementWriter = db.transaction(async (tx) => {
      await acquireUpdateDiscoveryWriterFence(tx)
      replacementFenced.resolve()
      await releaseReplacement.promise
    })
    try {
      await replacementFenced.promise
      // New shared writers remain free to join. With no empty cohort the
      // best-effort date barrier deliberately fails, never invents progress.
      release.resolve()
      await writer
      expect(await checkpoint).toMatchObject({ message: "Timed out waiting for durable update discovery writers" })
    } finally {
      release.resolve()
      releaseReplacement.resolve()
      await Promise.allSettled([writer, replacementWriter, checkpoint])
    }
    expect((await getUpdatesState({}, testUtils.functionContext({ userId: user.id }))).seq).toBe(0)
  }, 10_000)
})
