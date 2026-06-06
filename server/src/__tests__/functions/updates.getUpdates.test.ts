import { describe, test, expect } from "bun:test"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import { updates, UpdateBucket } from "../../db/schema/updates"
import {
  DialogNotificationSettings_Mode,
  GetUpdatesResult_ResultType,
  InputPeer,
  Member_Role,
} from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { UpdatesModel } from "@in/server/db/models/updates"
import { chats, dialogs, members, messages, spaces } from "@in/server/db/schema"
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
      totalLimit: 1,
      limit: 0,
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
      totalLimit: 1000,
      limit: 0,
    }, { currentUserId: user.id } as any)

    expect(Number(result.seq)).toBe(3)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.length).toBe(3)
  })

  test("uses request limit as page size", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Page Limit", ["page-limit@example.com"])
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
      seqEnd: 0n,
      totalLimit: 1000,
      limit: 2,
    }, { currentUserId: user.id } as any)

    expect(Number(result.seq)).toBe(2)
    expect(result.final).toBe(false)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.length).toBe(2)
  })

  test("sanitizes public space member add updates for regular members", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Update Space", [
      "regular-public-updates@example.com",
      "new-public-updates@example.com",
    ])
    const [regularUser, newUser] = users
    await db.update(spaces).set({ isPublic: true }).where(eq(spaces.id, space.id))
    const [newMember] = await db
      .select()
      .from(members)
      .where(and(eq(members.spaceId, space.id), eq(members.userId, newUser.id)))
      .limit(1)
    if (!newMember) throw new Error("missing member")

    await insertServerUpdate({
      bucket: UpdateBucket.Space,
      entityId: space.id,
      seq: 1,
      payload: {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: {
          member: {
            id: BigInt(newMember.id),
            spaceId: BigInt(space.id),
            userId: BigInt(newUser.id),
            role: Member_Role.MEMBER,
            date: 1n,
            canAccessPublicChats: true,
          },
          user: {
            id: BigInt(newUser.id),
            firstName: "New",
            email: "new-public-updates@example.com",
            phoneNumber: "+15555550100",
            timeZone: "UTC",
          },
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "space", space: { spaceId: BigInt(space.id) } } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 10,
      },
      { currentUserId: regularUser.id } as any,
    )

    const update = result.updates[0]?.update
    expect(update?.oneofKind).toBe("spaceMemberAdd")
    if (update?.oneofKind !== "spaceMemberAdd") throw new Error("missing member add update")
    expect(update.spaceMemberAdd.user?.id).toBe(BigInt(newUser.id))
    expect(update.spaceMemberAdd.user?.email).toBeUndefined()
    expect(update.spaceMemberAdd.user?.phoneNumber).toBeUndefined()
    expect(update.spaceMemberAdd.user?.timeZone).toBeUndefined()
    expect(update.spaceMemberAdd.user?.min).toBe(true)
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
      totalLimit: 5000,
      limit: 0,
    }, { currentUserId: user.id } as any)

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
  })

  test("does not advance seq when a required message cannot be inflated", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Missing Message Update", ["missing@example.com"])
    const user = users[0]
    if (!user || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Missing Message Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 1n,
        },
      },
    })
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 2,
      fromId: user.id,
      text: "this should not be delivered before seq 1 inflates",
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 2,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 2n,
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
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.updates).toHaveLength(0)
    expect(result.seq).toBe(0n)
    expect(result.final).toBe(false)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.EMPTY)
    expect(result.sidecars).toBeUndefined()
  })

  test("advances over skippable chat updates with chatSkipPts", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Skippable Chat Update", ["skip@example.com"])
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
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 2,
      fromId: user.id,
      text: "valid after skippable update",
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 2,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 2n,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(chat.id) },
                },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["chatSkipPts", "newMessage"])
  })

  test("returns required sidecars for chat message catch-up", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Sidecar Updates", [
      "sidecar-sender@example.com",
      "sidecar-viewer@example.com",
    ])
    const sender = users[0]
    const viewer = users[1]
    if (!sender || !viewer || !space) throw new Error("Fixture creation failed")

    const parentChat = await testUtils.createChat(space.id, "Sidecar Parent Thread", "thread", true)
    if (!parentChat) throw new Error("Parent chat creation failed")
    const chat = await testUtils.createChat(space.id, "Sidecar Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")
    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: sender.id,
      text: "parent anchor",
    })
    await db
      .update(chats)
      .set({ parentChatId: parentChat.id, parentMessageId: 1 })
      .where(eq(chats.id, chat.id))
    const forwardedChat = await testUtils.createChat(space.id, "Forwarded Source", "thread", false)
    if (!forwardedChat) throw new Error("Forwarded chat creation failed")
    await testUtils.addParticipant(chat.id, sender.id)
    await testUtils.addParticipant(chat.id, viewer.id)

    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: sender.id,
      text: "hello from sidecar test",
      fwdFromPeerChatId: forwardedChat.id,
      fwdFromMessageId: 99,
      fwdFromSenderId: sender.id,
    })

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 1n,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(chat.id) },
                },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: viewer.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(result.seq).toBe(1n)
    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.update.oneofKind).toBe("newMessage")

    const sidecarChatIds = result.sidecars?.chats.map((sidecar) => sidecar.id) ?? []
    expect(sidecarChatIds).toContain(BigInt(parentChat.id))
    expect(sidecarChatIds).toContain(BigInt(chat.id))
    expect(sidecarChatIds).not.toContain(BigInt(forwardedChat.id))
    expect(sidecarChatIds.indexOf(BigInt(parentChat.id))).toBeLessThan(sidecarChatIds.indexOf(BigInt(chat.id)))
    expect(result.sidecars?.spaces.map((sidecar) => sidecar.id)).toContain(BigInt(space.id))
    const senderSidecar = result.sidecars?.users.find((user) => user.id === BigInt(sender.id))
    expect(senderSidecar).toBeDefined()
    expect(senderSidecar?.min).toBe(true)
    expect(senderSidecar?.email).toBeUndefined()
    expect(result.sidecars?.dialogs).toEqual([])
  })

  test("returns sidecars only for the delivered contiguous prefix", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Prefix Sidecars", [
      "prefix-one@example.com",
      "prefix-two@example.com",
      "prefix-viewer@example.com",
    ])
    const firstSender = users[0]
    const withheldSender = users[1]
    const viewer = users[2]
    if (!firstSender || !withheldSender || !viewer || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Prefix Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")
    await testUtils.addParticipant(chat.id, firstSender.id)
    await testUtils.addParticipant(chat.id, withheldSender.id)
    await testUtils.addParticipant(chat.id, viewer.id)

    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: firstSender.id,
      text: "delivered",
    })
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 3,
      fromId: withheldSender.id,
      text: "inflated but withheld behind missing seq 2",
    })

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 1n,
        },
      },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 2,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 2n,
        },
      },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 3,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 3n,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(chat.id) },
                },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: viewer.id } as any,
    )

    expect(result.seq).toBe(1n)
    expect(result.final).toBe(false)
    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.update.oneofKind).toBe("newMessage")

    expect(result.sidecars?.users.map((user) => user.id)).toContain(BigInt(firstSender.id))
    expect(result.sidecars?.users.map((user) => user.id)).not.toContain(BigInt(withheldSender.id))
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
        limit: 0,
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
        limit: 0,
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
        limit: 0,
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
        limit: 0,
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
