import { describe, test, expect } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { handler } from "../../methods/updateDialog"
import type { HandlerContext } from "../../controllers/helpers"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel, type DecryptedUpdate } from "@in/server/db/models/updates"
import { db } from "../../db"
import { chats, dialogs as dialogsTable, messages, updates } from "../../db/schema"
import type { ServerUpdate } from "@in/server/protocol/server"
import { and, eq } from "drizzle-orm"

import { InlineError } from "@in/server/types/errors"

describe("updateDialog", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("an authorized empty group can be archived before a dialog exists, while outsiders cannot materialize it", async () => {
    const owner = await testUtils.createUser("empty-archive-owner@example.test")
    const invited = await testUtils.createUser("empty-archive-invited@example.test")
    const outsider = await testUtils.createUser("empty-archive-outsider@example.test")
    const chat = await testUtils.createChat(null, "Empty group", "thread", false, owner.id)
    if (!chat) throw new Error("Archive group missing")
    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, invited.id)
    await expect(
      handler({ peerThreadId: String(chat.id), archived: true }, makeContext(outsider.id)),
    ).rejects.toMatchObject({ type: InlineError.ApiError.PEER_INVALID[0] })
    expect(await db.select().from(dialogsTable).where(eq(dialogsTable.chatId, chat.id))).toHaveLength(0)
    const result = await handler({ peerThreadId: String(chat.id), archived: true }, makeContext(invited.id))
    expect(result.dialog.archived).toBe(true)
    const [stored] = await db
      .select()
      .from(dialogsTable)
      .where(and(eq(dialogsTable.chatId, chat.id), eq(dialogsTable.userId, invited.id)))
    expect(stored?.archived).toBe(true)
    expect(stored?.followMode).toBeNull()
    const rows = await db.query.updates.findMany({ where: { bucket: UpdateBucket.User, entityId: invited.id } })
    expect(rows.map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)).toEqual(["userDialogArchived"])
  })

  test("a retained dialog does not preserve access after private participation is removed", async () => {
    const owner = await testUtils.createUser("archive-revoke-owner@example.test")
    const former = await testUtils.createUser("archive-revoke-former@example.test")
    const chat = await testUtils.createChat(null, "Private group", "thread", false, owner.id)
    if (!chat) throw new Error("Archive group missing")
    await testUtils.addParticipant(chat.id, owner.id)
    await db.insert(dialogsTable).values({ chatId: chat.id, userId: former.id, archived: false })
    await expect(
      handler({ peerThreadId: String(chat.id), archived: true }, makeContext(former.id)),
    ).rejects.toMatchObject({ type: InlineError.ApiError.PEER_INVALID[0] })
    const [stored] = await db
      .select()
      .from(dialogsTable)
      .where(and(eq(dialogsTable.chatId, chat.id), eq(dialogsTable.userId, former.id)))
    expect(stored?.archived).toBe(false)
    expect(
      await db
        .select()
        .from(updates)
        .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, former.id))),
    ).toHaveLength(0)
  })

  test("archives and unarchives dialogs while enqueuing user updates", async () => {
    type UserDialogArchivedUpdate = Extract<ServerUpdate["update"], { oneofKind: "userDialogArchived" }>
    type DecryptedUserDialogArchivedUpdate = DecryptedUpdate & {
      payload: ServerUpdate & { update: UserDialogArchivedUpdate }
    }

    const isUserDialogArchivedUpdate = (
      update: DecryptedUpdate,
    ): update is DecryptedUserDialogArchivedUpdate => update.payload.update.oneofKind === "userDialogArchived"

    const userA = await testUtils.createUser("archive-owner@example.com")
    const userB = await testUtils.createUser("archive-peer@example.com")
    if (!userA || !userB) throw new Error("Failed to create users")

    await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })

    await handler({ peerUserId: String(userB.id), archived: true }, makeContext(userA.id))
    await handler({ peerUserId: String(userB.id), archived: false }, makeContext(userA.id))

    const userUpdates = await db.query.updates.findMany({
      where: {
        bucket: UpdateBucket.User,
        entityId: userA.id,
      },
    })

    const archivedUpdates = userUpdates
      .map((update) => UpdatesModel.decrypt(update))
      .filter(isUserDialogArchivedUpdate)
      .sort((a, b) => a.seq - b.seq)

    expect(archivedUpdates).toHaveLength(2)
    expect(archivedUpdates[0]?.payload.update.oneofKind).toBe("userDialogArchived")
    expect(archivedUpdates[0]?.payload.update.userDialogArchived.archived).toBe(true)
    const peerType = archivedUpdates[0]?.payload.update.userDialogArchived.peerId?.type
    expect(peerType?.oneofKind).toBe("user")
    if (peerType?.oneofKind !== "user") {
      throw new Error("Expected archived update peer to be a user")
    }
    expect(peerType.user.userId).toBe(BigInt(userB.id))
    expect(archivedUpdates[1]?.payload.update.oneofKind).toBe("userDialogArchived")
    expect(archivedUpdates[1]?.payload.update.userDialogArchived.archived).toBe(false)
  })

  test("promotes hidden linked-subthread dialogs when pinning or unarchiving", async () => {
    const owner = await testUtils.createUser("thread-dialog-owner@example.com")
    const participant = await testUtils.createUser("thread-dialog-participant@example.com")
    if (!owner || !participant) throw new Error("Failed to create users")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) throw new Error("Failed to create parent chat")

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) throw new Error("Failed to create child chat")

    await db.insert(dialogsTable).values({
      userId: participant.id,
      chatId: childChat.id,
      chatListHidden: true,
      pinned: false,
      archived: true,
    })

    await handler({ peerThreadId: String(childChat.id), pinned: true }, makeContext(participant.id))

    let [dialogAfterPin] = await db
      .select()
      .from(dialogsTable)
      .where(and(eq(dialogsTable.chatId, childChat.id), eq(dialogsTable.userId, participant.id)))
      .limit(1)

    expect(dialogAfterPin?.chatListHidden).toBeNull()
    expect(dialogAfterPin?.pinned).toBe(true)
    expect(dialogAfterPin?.open).toBe(true)
    expect(dialogAfterPin?.order).toBeTruthy()
    expect(dialogAfterPin?.pinnedOrder).toBeTruthy()

    await db
      .update(dialogsTable)
      .set({ chatListHidden: true, archived: true, pinned: false, open: false, openedDate: null })
      .where(and(eq(dialogsTable.chatId, childChat.id), eq(dialogsTable.userId, participant.id)))

    await handler({ peerThreadId: String(childChat.id), archived: false }, makeContext(participant.id))

    let [dialogAfterUnarchive] = await db
      .select()
      .from(dialogsTable)
      .where(and(eq(dialogsTable.chatId, childChat.id), eq(dialogsTable.userId, participant.id)))
      .limit(1)

    expect(dialogAfterUnarchive?.chatListHidden).toBeNull()
    expect(dialogAfterUnarchive?.archived).toBe(false)
    expect(dialogAfterUnarchive?.open).toBe(false)
  })

  test("preserves order when pinning an already-open dialog", async () => {
    const owner = await testUtils.createUser("open-pin-owner@example.com")
    const participant = await testUtils.createUser("open-pin-participant@example.com")
    if (!owner || !participant) throw new Error("Failed to create users")

    const chat = await testUtils.createChat(null, "Pinned Inbox Thread", "thread", false, owner.id)
    if (!chat) throw new Error("Failed to create chat")

    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, participant.id)

    const order = "P"
    await db.insert(dialogsTable).values({
      userId: participant.id,
      chatId: chat.id,
      open: true,
      order,
      pinned: false,
    })

    await handler({ peerThreadId: String(chat.id), pinned: true }, makeContext(participant.id))

    const [dialog] = await db
      .select()
      .from(dialogsTable)
      .where(and(eq(dialogsTable.chatId, chat.id), eq(dialogsTable.userId, participant.id)))
      .limit(1)

    expect(dialog?.pinned).toBe(true)
    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBe(order)
    expect(dialog?.pinnedOrder).toBeTruthy()
  })
})
