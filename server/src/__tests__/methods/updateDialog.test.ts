import { describe, test, expect, spyOn } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { handler } from "../../methods/updateDialog"
import type { HandlerContext } from "../../controllers/helpers"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel, type DecryptedUpdate } from "@in/server/db/models/updates"
import { db } from "../../db"
import { chats, dialogs as dialogsTable, members, messages, users } from "../../db/schema"
import type { ServerUpdate } from "@in/server/protocol/server"
import { and, eq, sql } from "drizzle-orm"
import { createChat } from "@in/server/functions/messages.createChat"
import { getChat } from "@in/server/functions/messages.getChat"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { InlineError } from "@in/server/types/errors"

describe("updateDialog", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  const getArchiveUpdates = async (userId: number) => {
    const updates = await db.query.updates.findMany({
      where: { bucket: UpdateBucket.User, entityId: userId },
    })
    return updates
      .map((update) => UpdatesModel.decrypt(update))
      .filter((update) => update.payload.update.oneofKind === "userDialogArchived")
  }

  test("an invitee archives an empty home group before a dialog is materialized", async () => {
    const owner = await testUtils.createUser("empty-archive-owner@example.test")
    const invitee = await testUtils.createUser("empty-archive-invitee@example.test")
    const created = await createChat(
      { title: "Empty group", participants: [{ userId: BigInt(invitee.id) }] },
      testUtils.functionContext({ userId: owner.id }),
    )
    const chatId = Number(created.chat.id)
    const input = { peerThreadId: String(chatId), archived: true }
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } }

    expect(await db.query.chatParticipants.findFirst({ where: { chatId, userId: invitee.id } })).toBeDefined()
    expect(await db.query.dialogs.findFirst({ where: { chatId, userId: invitee.id } })).toBeUndefined()
    expect(await db.query.messages.findMany({ where: { chatId } })).toHaveLength(0)

    const response = await handler(input, makeContext(invitee.id))
    expect(response.dialog.archived).toBe(true)
    await handler(input, makeContext(invitee.id))

    const snapshot = await getChat({ peerId }, testUtils.functionContext({ userId: invitee.id }))
    expect(snapshot.dialog?.archived).toBe(true)
    const stored = await db.query.dialogs.findMany({ where: { chatId, userId: invitee.id } })
    expect(stored).toHaveLength(1)
    expect(stored[0]?.archived).toBe(true)
    expect(stored[0]?.open).toBeNull()
    expect(stored[0]?.followMode).toBeNull()
    expect(stored[0]?.peerUserId).toBeNull()
    expect(stored[0]?.spaceId).toBeNull()
    expect(await db.query.chatParticipants.findFirst({ where: { chatId, userId: invitee.id } })).toBeDefined()
    const archiveUpdates = await getArchiveUpdates(invitee.id)
    expect(archiveUpdates).toHaveLength(1)
    const update = archiveUpdates[0]?.payload.update
    if (update?.oneofKind !== "userDialogArchived") throw new Error("Missing durable archive update")
    expect(update.userDialogArchived).toEqual({ peerId, archived: true })
  })

  test("missing-dialog archive denies outsiders and revoked Space members without side effects", async () => {
    const owner = await testUtils.createUser("denied-archive-owner@example.test")
    const outsider = await testUtils.createUser("denied-archive-outsider@example.test")
    const home = await createChat(
      { title: "Private empty group", participants: [{ userId: BigInt(owner.id) }] },
      testUtils.functionContext({ userId: owner.id }),
    )
    const { space, users: [spaceOwner, formerMember] } = await testUtils.createSpaceWithMembers(
      "Archived Space", ["space-archive-owner@example.test", "space-archive-former@example.test"],
    )
    const spaceChat = await createChat(
      {
        title: "Private Space group",
        spaceId: BigInt(space.id),
        isPublic: false,
        participants: [{ userId: BigInt(formerMember.id) }],
      },
      testUtils.functionContext({ userId: spaceOwner.id }),
    )
    // Keep the participant projection to prove it does not override current Space membership.
    await db.delete(members).where(and(eq(members.spaceId, space.id), eq(members.userId, formerMember.id)))

    const pushes = spyOn(RealtimeUpdates, "pushToUser")
    try {
      for (const [chatId, userId] of [
        [Number(home.chat.id), outsider.id],
        [Number(spaceChat.chat.id), formerMember.id],
        [2_147_483_647, outsider.id],
      ]) {
        if (chatId === undefined || userId === undefined) throw new Error("Missing test actor")
        await expect(handler({ peerThreadId: String(chatId), archived: true }, makeContext(userId)))
          .rejects.toMatchObject({ type: InlineError.ApiError.PEER_INVALID[0], code: 400 })
        expect(await db.query.dialogs.findFirst({ where: { chatId, userId } })).toBeUndefined()
        expect(await getArchiveUpdates(userId)).toHaveLength(0)
      }
      expect(pushes.mock.calls).toHaveLength(0)
    } finally {
      pushes.mockRestore()
    }
    expect(await db.query.chatParticipants.findFirst({
      where: { chatId: Number(spaceChat.chat.id), userId: formerMember.id },
    })).toBeDefined()
  })

  test("archiving a missing linked-child dialog preserves inherited access and visibility defaults", async () => {
    const owner = await testUtils.createUser("linked-archive-owner@example.test")
    const invitee = await testUtils.createUser("linked-archive-invitee@example.test")
    const parent = await createChat(
      { title: "Parent group", participants: [{ userId: BigInt(invitee.id) }] },
      testUtils.functionContext({ userId: owner.id }),
    )
    const [child] = await db.insert(chats).values({
      type: "thread", title: "Linked child", createdBy: owner.id, parentChatId: Number(parent.chat.id),
    }).returning()
    if (!child) throw new Error("Missing linked child")

    await handler({ peerThreadId: String(child.id), archived: true }, makeContext(invitee.id))
    const dialog = await db.query.dialogs.findFirst({ where: { chatId: child.id, userId: invitee.id } })
    expect(dialog?.archived).toBe(true)
    expect(dialog?.chatListHidden).toBe(true)
    expect(dialog?.open).toBeNull()
    expect(dialog?.followMode).toBeNull()
    expect(await db.query.chatParticipants.findFirst({ where: { chatId: child.id, userId: invitee.id } })).toBeUndefined()
    expect(await db.query.chatParticipants.findFirst({ where: { chatId: Number(parent.chat.id), userId: invitee.id } })).toBeDefined()
    expect(await getArchiveUpdates(invitee.id)).toHaveLength(1)
  })

  test("an invitee can archive and pin a missing Space dialog in one request", async () => {
    const { space, users: [owner, invitee] } = await testUtils.createSpaceWithMembers(
      "Combined archive and pin", ["combined-archive-owner@example.test", "combined-archive-invitee@example.test"],
    )
    const created = await createChat(
      {
        title: "Empty Space group",
        spaceId: BigInt(space.id),
        isPublic: false,
        participants: [{ userId: BigInt(invitee.id) }],
      },
      testUtils.functionContext({ userId: owner.id }),
    )
    const chatId = Number(created.chat.id)
    await handler({ peerThreadId: String(chatId), archived: true, pinned: true }, makeContext(invitee.id))
    const dialog = await db.query.dialogs.findFirst({ where: { chatId, userId: invitee.id } })
    expect(dialog?.archived).toBe(true)
    expect(dialog?.pinned).toBe(true)
    expect(dialog?.open).toBe(true)
    expect(dialog?.order).toBeTruthy()
    expect(dialog?.pinnedOrder).toBeTruthy()
    expect(dialog?.spaceId).toBe(space.id)
    expect(dialog?.followMode).toBeNull()
    expect(await getArchiveUpdates(invitee.id)).toHaveLength(1)
  })

  test("archive serializes a competing archive and pin after getChat materializes the dialog", async () => {
    const owner = await testUtils.createUser("concurrent-archive-owner@example.test")
    const invitee = await testUtils.createUser("concurrent-archive-invitee@example.test")
    const created = await createChat(
      { title: "Concurrent empty group", participants: [{ userId: BigInt(invitee.id) }] },
      testUtils.functionContext({ userId: owner.id }),
    )
    const chatId = Number(created.chat.id)
    const access = AccessGuards.ensureChatAccess
    let signalAuthorized: (() => void) | undefined
    const authorized = new Promise<void>((resolve) => { signalAuthorized = resolve })
    let releaseArchive: (() => void) | undefined
    const archiveReleased = new Promise<void>((resolve) => { releaseArchive = resolve })
    let held = false
    let archivePid = 0
    const accessSpy = spyOn(AccessGuards, "ensureChatAccess").mockImplementation(async (chat, userId, query) => {
      await access(chat, userId, query)
      if (!held && query !== undefined && chat.id === chatId && userId === invitee.id) {
        held = true
        const [backend] = await query.select({ pid: sql<number>`pg_backend_pid()` }).from(users).where(eq(users.id, userId))
        if (!backend) throw new Error("Missing archive backend")
        archivePid = backend.pid
        signalAuthorized?.()
        await archiveReleased
      }
    })
    const archive = handler({ peerThreadId: String(chatId), archived: true }, makeContext(invitee.id))
    // If authorization is never reached, surface the operation failure instead of hanging at the barrier.
    const reachedAuthorization = Promise.race([authorized, archive.then(() => { throw new Error("Archive missed barrier") })])
    let competing: ReturnType<typeof handler> | undefined
    let ownerWait: Promise<void> | undefined
    let observingOwner = true
    try {
      await reachedAuthorization
      const snapshot = await getChat(
        { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } } },
        testUtils.functionContext({ userId: invitee.id }),
      )
      expect(snapshot.dialog?.archived).toBe(false)
      const winner = await db.query.dialogs.findFirst({ where: { chatId, userId: invitee.id } })
      expect(winner).toBeDefined()
      competing = handler({ peerThreadId: String(chatId), archived: true, pinned: true }, makeContext(invitee.id))
      const waitForOwner = async () => {
        const deadline = performance.now() + 5_000
        while (observingOwner && performance.now() < deadline) {
          const [row] = await db.execute<{ blocked: boolean }>(sql`
            select exists(select 1 from pg_stat_activity
              where datname = current_database() and ${archivePid} = any(pg_blocking_pids(pid))) as blocked
          `)
          if (row?.blocked) return
          await Bun.sleep(10)
        }
        throw new Error("Competing archive did not wait for the user owner")
      }
      ownerWait = waitForOwner()
      await Promise.race([ownerWait, competing.then(() => { throw new Error("Competing archive bypassed the user owner") })])
      releaseArchive?.()
      expect((await archive).dialog.archived).toBe(true)
      expect((await competing).dialog.pinned).toBe(true)
      const dialogs = await db.query.dialogs.findMany({ where: { chatId, userId: invitee.id } })
      expect(dialogs).toHaveLength(1)
      expect(dialogs[0]?.id).toBe(winner?.id)
      expect(dialogs[0]?.archived).toBe(true)
      expect(dialogs[0]?.pinned).toBe(true)
      expect(dialogs[0]?.open).toBe(true)
      expect(dialogs[0]?.pinnedOrder).toBeTruthy()
      expect(await getArchiveUpdates(invitee.id)).toHaveLength(1)
    } finally {
      observingOwner = false
      releaseArchive?.()
      await Promise.allSettled([archive, reachedAuthorization, competing, ownerWait])
      accessSpy.mockRestore()
    }
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
