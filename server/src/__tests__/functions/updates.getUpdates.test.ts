import { describe, test, expect } from "bun:test"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import { updates, UpdateBucket } from "../../db/schema/updates"
import { DialogNotificationSettings_Mode, GetUpdatesResult_ResultType, InputPeer } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { UpdatesModel } from "@in/server/db/models/updates"
import { dialogs } from "@in/server/db/schema"
import { handler as readMessages } from "@in/server/methods/readMessages"
import { and, desc, eq } from "drizzle-orm"

const insertServerUpdate = async (params: {
  bucket: UpdateBucket
  entityId: number
  seq: number
  payload: ServerUpdate["update"]
}) => {
  const now = new Date()
  const serverUpdate: ServerUpdate = {
    seq: params.seq,
    date: encodeDateStrict(now),
    update: params.payload,
  }
  const record = UpdatesModel.build(serverUpdate)
  await db.insert(updates).values({
    bucket: params.bucket,
    entityId: params.entityId,
    seq: params.seq,
    payload: record.encrypted,
    date: now,
  })
}

describe("getUpdates", () => {
  setupTestLifecycle()

  test("returns TOO_LONG with correct seq when gap is too large", async () => {
    // 1. Setup User and Chat
    const { users, space } = await testUtils.createSpaceWithMembers("Test Space", ["user@example.com"])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Test Chat", "thread")
    if (!chat) throw new Error("Chat creation failed")

    // 2. Insert updates (seq 1 to 10)
    // We just need dummy payload
    const dummyPayload = Buffer.from([1, 2, 3])
    
    for (let i = 1; i <= 10; i++) {
      await db.insert(updates).values({
        bucket: UpdateBucket.Chat,
        entityId: chat.id,
        seq: i,
        payload: dummyPayload,
      })
    }

    // 3. Call getUpdates with fast-forward parameters
    // startSeq=0, totalLimit=1
    const inputPeer: InputPeer = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chat.id) }
      }
    }
    
    const result = await getUpdates({
      bucket: {
        type: {
          oneofKind: "chat",
          chat: { peerId: inputPeer }
        }
      },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 1
    }, { currentUserId: user.id } as any)

    // 4. Verify result
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(Number(result.seq)).toBe(10) 
  })

  test("respects seqEnd for sliced getUpdates", async () => {
    const { users } = await testUtils.createSpaceWithMembers("SeqEnd Slice", ["seqend@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    for (let seq = 1; seq <= 5; seq += 1) {
      await insertServerUpdate({
        bucket: UpdateBucket.User,
        entityId: user.id,
        seq,
        payload: {
          oneofKind: "userChatParticipantDelete",
          userChatParticipantDelete: {
            chatId: BigInt(seq),
          },
        },
      })
    }

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 3n,
      totalLimit: 1000
    }, { currentUserId: user.id } as any)

    expect(Number(result.seq)).toBe(3)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.length).toBe(3)
  })

  test("caps totalLimit to MAX_TOTAL_LIMIT", async () => {
    const { users } = await testUtils.createSpaceWithMembers("TotalLimit Cap", ["cap@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    const dummyPayload = Buffer.from([1, 2, 3])
    await db.insert(updates).values({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1501,
      payload: dummyPayload,
    })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 5000
    }, { currentUserId: user.id } as any)

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
  })

  test("advances seq when updates cannot be inflated", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Unhandled Update", ["skip@example.com"])
    const user = users[0]
    if (!user || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Skip Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: BigInt(chat.id),
        },
      },
    })

    const inputPeer: InputPeer = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chat.id) },
      },
    }

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: { peerId: inputPeer },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.updates).toHaveLength(0)
    expect(result.seq).toBe(1n)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.EMPTY)
  })

  test("inflates userReadMaxId to updateReadMaxId in user bucket", async () => {
    const user = await testUtils.createUser("read-max@example.com")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userReadMaxId",
        userReadMaxId: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 123n },
            },
          },
          readMaxId: 42n,
          unreadCount: 3,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(1)
    expect(result.updates).toHaveLength(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("updateReadMaxId")
    if (first.update.oneofKind !== "updateReadMaxId") throw new Error("Unexpected update type")
    expect(first.update.updateReadMaxId.readMaxId).toBe(42n)
    expect(first.update.updateReadMaxId.unreadCount).toBe(3)
  })

  test("inflates userMarkAsUnread to markAsUnread in user bucket", async () => {
    const user = await testUtils.createUser("unread-mark@example.com")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userMarkAsUnread",
        userMarkAsUnread: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 123n },
            },
          },
          unreadMark: true,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(1)
    expect(result.updates).toHaveLength(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("markAsUnread")
    if (first.update.oneofKind !== "markAsUnread") throw new Error("Unexpected update type")
    expect(first.update.markAsUnread.unreadMark).toBe(true)
  })

  test("inflates userDialogNotificationSettings to dialogNotificationSettings in user bucket", async () => {
    const user = await testUtils.createUser("dialog-settings@sync.com")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userDialogNotificationSettings",
        userDialogNotificationSettings: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 123n },
            },
          },
          notificationSettings: {
            mode: DialogNotificationSettings_Mode.MENTIONS,
          },
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(1)
    expect(result.updates).toHaveLength(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("dialogNotificationSettings")
    if (first.update.oneofKind !== "dialogNotificationSettings") throw new Error("Unexpected update type")
    expect(first.update.dialogNotificationSettings.notificationSettings?.mode).toBe(
      DialogNotificationSettings_Mode.MENTIONS,
    )
  })

  test("integration: readMessages persists userReadMaxId and getUpdates inflates updateReadMaxId", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("ReadState Integration", ["readstate@sync.com"])
    const user = users[0]
    if (!space || !user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "ReadState Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await db.insert(dialogs).values({ userId: user.id, chatId: chat.id, spaceId: space.id }).execute()

    const [beforeRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    const beforeSeq = beforeRow?.seq ?? 0

    await readMessages(
      { peerThreadId: chat.id.toString(), maxId: 1 },
      { currentUserId: user.id, currentSessionId: 1, ip: undefined },
    )

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: BigInt(beforeSeq),
        seqEnd: 0n,
        totalLimit: 1000,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(beforeSeq + 1)
    expect(result.updates.length).toBe(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("updateReadMaxId")
    if (first.update.oneofKind !== "updateReadMaxId") throw new Error("Unexpected update type")
    expect(first.update.updateReadMaxId.readMaxId).toBe(1n)
    expect(first.update.updateReadMaxId.unreadCount).toBe(0)

    const peerType = first.update.updateReadMaxId.peerId?.type
    if (!peerType || peerType.oneofKind !== "chat") throw new Error("Expected chat peer for thread")
    expect(peerType.chat.chatId).toBe(BigInt(chat.id))
  })

  test("readMessages does not regress readInboxMaxId when called with a stale smaller maxId", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("ReadState No Regress", ["noregress@sync.com"])
    const user = users[0]
    if (!space || !user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "No Regress Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await db
      .insert(dialogs)
      .values({ userId: user.id, chatId: chat.id, spaceId: space.id, readInboxMaxId: 10, unreadMark: false })
      .execute()

    const [beforeRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    const beforeSeq = beforeRow?.seq ?? 0

    await readMessages(
      { peerThreadId: chat.id.toString(), maxId: 1 },
      { currentUserId: user.id, currentSessionId: 1, ip: undefined },
    )

    const [dialogRow] = await db
      .select({ readInboxMaxId: dialogs.readInboxMaxId, unreadMark: dialogs.unreadMark })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)

    expect(dialogRow?.readInboxMaxId).toBe(10)
    expect(dialogRow?.unreadMark).toBe(false)

    const [afterRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    const afterSeq = afterRow?.seq ?? 0
    expect(afterSeq).toBe(beforeSeq)
  })

  test("readMessages clears unreadMark without regressing readInboxMaxId when maxId is stale", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("ReadState Clear Mark", ["clearmark@sync.com"])
    const user = users[0]
    if (!space || !user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Clear Mark Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await db
      .insert(dialogs)
      .values({ userId: user.id, chatId: chat.id, spaceId: space.id, readInboxMaxId: 10, unreadMark: true })
      .execute()

    const [beforeRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    const beforeSeq = beforeRow?.seq ?? 0

    await readMessages(
      { peerThreadId: chat.id.toString(), maxId: 1 },
      { currentUserId: user.id, currentSessionId: 1, ip: undefined },
    )

    const [dialogRow] = await db
      .select({ readInboxMaxId: dialogs.readInboxMaxId, unreadMark: dialogs.unreadMark })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)

    expect(dialogRow?.readInboxMaxId).toBe(10)
    expect(dialogRow?.unreadMark).toBe(false)

    const [afterRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    expect(afterRow).toBeTruthy()
    expect(afterRow!.seq).toBeGreaterThan(beforeSeq)

    const decrypted = UpdatesModel.decrypt(afterRow!)
    expect(decrypted.payload.update.oneofKind).toBe("userMarkAsUnread")
    if (decrypted.payload.update.oneofKind === "userMarkAsUnread") {
      expect(decrypted.payload.update.userMarkAsUnread.unreadMark).toBe(false)
    }
  })
})
