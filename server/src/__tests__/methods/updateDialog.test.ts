import { describe, test, expect } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { handler } from "../../methods/updateDialog"
import type { HandlerContext } from "../../controllers/helpers"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel, type DecryptedUpdate } from "@in/server/db/models/updates"
import { db } from "../../db"
import { chats, dialogs as dialogsTable, messages } from "../../db/schema"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { and, eq } from "drizzle-orm"

describe("updateDialog", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
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
      sidebarVisible: false,
      pinned: false,
      archived: true,
    })

    await handler({ peerThreadId: String(childChat.id), pinned: true }, makeContext(participant.id))

    let [dialogAfterPin] = await db
      .select()
      .from(dialogsTable)
      .where(and(eq(dialogsTable.chatId, childChat.id), eq(dialogsTable.userId, participant.id)))
      .limit(1)

    expect(dialogAfterPin?.sidebarVisible).toBe(true)
    expect(dialogAfterPin?.pinned).toBe(true)

    await db
      .update(dialogsTable)
      .set({ sidebarVisible: false, archived: true, pinned: false })
      .where(and(eq(dialogsTable.chatId, childChat.id), eq(dialogsTable.userId, participant.id)))

    await handler({ peerThreadId: String(childChat.id), archived: false }, makeContext(participant.id))

    let [dialogAfterUnarchive] = await db
      .select()
      .from(dialogsTable)
      .where(and(eq(dialogsTable.chatId, childChat.id), eq(dialogsTable.userId, participant.id)))
      .limit(1)

    expect(dialogAfterUnarchive?.sidebarVisible).toBe(true)
    expect(dialogAfterUnarchive?.archived).toBe(false)
  })
})
