import { describe, expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import { chats, dialogs, members, spaces, updates, UpdateBucket, users } from "@in/server/db/schema"
import { createChat } from "@in/server/functions/messages.createChat"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { GetUpdatesResult_ResultType } from "@inline-chat/protocol/core"
import { and, asc, eq } from "drizzle-orm"

const legacyContext = (userId: number) => ({ currentUserId: userId, currentSessionId: 1, ip: undefined })

describe("createSpace", () => {
  setupTestLifecycle()

  test("names the primary chat after the space", async () => {
    const owner = await testUtils.createUser("space-primary-chat-owner@example.com")

    const result = await createSpace({ name: "Town Hall" }, legacyContext(owner.id))

    expect(result.space.name).toBe("Town Hall")
    expect(result.chats).toHaveLength(1)
    expect(result.chats[0]?.title).toBe("Town Hall")
    expect(result.dialogs).toHaveLength(1)
    expect(result.dialogs[0]?.open).toBe(true)
    expect(result.dialogs[0]?.order).toBeString()
  })

  test("consumes the space counter for the primary chat", async () => {
    const owner = await testUtils.createUser("space-primary-thread-number-owner@example.com")
    const result = await createSpace({ name: "Numbered Town Hall" }, legacyContext(owner.id))

    expect(result.chats[0]?.number).toBe(1)

    const created = await createChat(
      {
        title: "Second Thread",
        spaceId: BigInt(result.space.id),
        isPublic: true,
      },
      { currentUserId: owner.id, currentSessionId: 1 },
    )

    expect(created.chat.number).toBe(2)

    const [storedSpace] = await db
      .select({ nextThreadNumber: spaces.nextThreadNumber })
      .from(spaces)
      .where(eq(spaces.id, result.space.id))
      .limit(1)
    expect(storedSpace?.nextThreadNumber).toBe(3)
  })

  test("commits a contiguous complete user projection and fans it out in one cross-session batch", async () => {
    const owner = await testUtils.createUser("space-projection-owner@example.com")
    const pushed: Array<Parameters<typeof RealtimeUpdates.pushToUser>> = []
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (...args) => {
      pushed.push(args)
    })
    const result = await (async () => {
      try {
        return await createSpace({ name: "Projected Town Hall" }, legacyContext(owner.id))
      } finally {
        push.mockRestore()
      }
    })()

    const spaceId = Number(result.space.id)
    const userUpdates = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, owner.id)))
      .orderBy(asc(updates.seq))
    expect(userUpdates.map((row) => row.seq)).toEqual([1, 2, 3])
    const payloads = userUpdates.map((row) => UpdatesModel.decrypt(row).payload.update)
    expect(payloads.map((payload) => payload.oneofKind)).toEqual([
      "userJoinSpace",
      "userAddedToChat",
      "userChatOpen",
    ])
    const chatOpen = payloads[2]
    if (chatOpen?.oneofKind !== "userChatOpen") throw new Error("Expected userChatOpen")
    expect(chatOpen.userChatOpen.chat?.permissions?.canUpdateInfo).toBe(true)
    expect(chatOpen.userChatOpen.chat?.acknowledgements?.cursors).toEqual([])
    expect(chatOpen.userChatOpen.dialog?.unreadCount).toBe(0)

    expect(
      await db
        .select()
        .from(updates)
        .where(and(eq(updates.bucket, UpdateBucket.Space), eq(updates.entityId, spaceId))),
    ).toHaveLength(0)
    const [storedSpace] = await db.select().from(spaces).where(eq(spaces.id, spaceId)).limit(1)
    expect(storedSpace?.updateSeq).toBe(0)

    expect(pushed).toHaveLength(1)
    const [recipient, liveUpdates, options] = pushed[0]!
    expect(recipient).toBe(owner.id)
    expect(liveUpdates.map((update) => update.seq)).toEqual([1, 2, 3])
    expect(liveUpdates.map((update) => update.update.oneofKind)).toEqual([
      "joinSpace",
      "userAddedToChat",
      "chatOpen",
    ])
    expect(options).toBeUndefined()

    const catchUp = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 3n,
        totalLimit: 100,
        limit: 100,
      },
      { currentUserId: owner.id, currentSessionId: 2 },
    )
    expect(catchUp.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(catchUp.final).toBe(true)
    expect(catchUp.seq).toBe(3n)
    expect(catchUp.updates.map((update) => update.update.oneofKind)).toEqual([
      "joinSpace",
      "userAddedToChat",
      "chatOpen",
    ])
  })

  test("rolls back space, owner, primary chat, dialog, and user sequence on projection failure", async () => {
    const owner = await testUtils.createUser("space-projection-rollback-owner@example.com")
    const originalEnqueue = UserBucketUpdates.enqueue
    let enqueueCount = 0
    const enqueue = spyOn(UserBucketUpdates, "enqueue").mockImplementation(async (input, options) => {
      enqueueCount += 1
      if (enqueueCount === 3) {
        throw new Error("injected create-space projection failure")
      }
      return originalEnqueue(input, options)
    })
    try {
      await expect(createSpace({ name: "Rollback Town Hall" }, legacyContext(owner.id))).rejects.toMatchObject({
        type: "INTERNAL",
      })
    } finally {
      enqueue.mockRestore()
    }

    expect(await db.select().from(spaces).where(eq(spaces.name, "Rollback Town Hall"))).toHaveLength(0)
    expect(await db.select().from(members).where(eq(members.userId, owner.id))).toHaveLength(0)
    expect(await db.select().from(chats).where(eq(chats.title, "Rollback Town Hall"))).toHaveLength(0)
    expect(await db.select().from(dialogs).where(eq(dialogs.userId, owner.id))).toHaveLength(0)
    expect(
      await db
        .select()
        .from(updates)
        .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, owner.id))),
    ).toHaveLength(0)
    const [storedOwner] = await db.select().from(users).where(eq(users.id, owner.id)).limit(1)
    expect(storedOwner?.updateSeq).toBe(0)
  })
})
