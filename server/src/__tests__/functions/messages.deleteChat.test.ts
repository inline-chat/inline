import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { db, schema } from "@in/server/db"
import { deleteChat, deleteEmptyUntitledThreadAfterClose } from "@in/server/functions/messages.deleteChat"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { setupTestLifecycle, testUtils } from "../setup"
import { RealtimeUpdates } from "@in/server/realtime/message"

import { RealtimeRpcError } from "@in/server/realtime/errors"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { UpdatesModel } from "@in/server/db/models/updates"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import { setDialogFollowModeForUsers } from "@in/server/modules/dialogFollow"
import { setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import { updateDialogOpen } from "@in/server/functions/messages.updateDialogOpen"
import { handler as updateDialog } from "@in/server/methods/updateDialog"
import { InlineError } from "@in/server/types/errors"

const inputPeerForChat = (chatId: number) => ({
  type: {
    oneofKind: "chat" as const,
    chat: { chatId: BigInt(chatId) },
  },
})

describe("messages.deleteChat", () => {
  setupTestLifecycle()

  async function placedThreadWithChild() {
    const owner = await testUtils.createUser("delete-placement-owner@example.test")
    const grandparent = await testUtils.createChat(null, "Grandparent", "thread", false, owner.id)
    const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
    const child = await testUtils.createChat(null, "Child", "thread", false, owner.id)
    if (!grandparent || !parent || !child) throw new Error("Delete fixture chats missing")
    for (const chat of [grandparent, parent, child]) await testUtils.addParticipant(chat.id, owner.id)
    const [placement] = await db
      .insert(schema.messages)
      .values({ chatId: grandparent.id, messageId: 1, fromId: owner.id, text: "Parent placement" })
      .returning()
    if (!placement) throw new Error("Delete fixture placement missing")
    await db.update(schema.chats).set({ parentChatId: grandparent.id }).where(eq(schema.chats.id, parent.id))
    await db.update(schema.chats).set({ parentChatId: parent.id }).where(eq(schema.chats.id, child.id))
    await db.update(schema.chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(schema.chats.id, grandparent.id))
    await db
      .insert(schema.subthreadParentMessages)
      .values({ childChatId: parent.id, parentMessageGlobalId: placement.globalId })
    await db.insert(schema.dialogs).values({ chatId: parent.id, userId: owner.id, open: true, followMode: "following" })
    return { owner, grandparent, parent, child, placement }
  }

  test("refuses a parent with children before deleting its own parent placement or personal state", async () => {
    const { owner, grandparent, parent, child, placement } = await placedThreadWithChild()
    await expect(
      deleteChat({ peer: inputPeerForChat(parent.id) }, testUtils.functionContext({ userId: owner.id })),
    ).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
      message: "Delete child chats before deleting their parent",
    })
    expect(
      await db.select().from(schema.messages).where(eq(schema.messages.globalId, placement.globalId)),
    ).toHaveLength(1)
    expect(
      await db
        .select()
        .from(schema.subthreadParentMessages)
        .where(eq(schema.subthreadParentMessages.childChatId, parent.id)),
    ).toHaveLength(1)
    const [savedParent] = await db.select().from(schema.chats).where(eq(schema.chats.id, parent.id))
    const [savedChild] = await db.select().from(schema.chats).where(eq(schema.chats.id, child.id))
    expect(savedParent?.parentChatId).toBe(grandparent.id)
    expect(savedChild?.parentChatId).toBe(parent.id)
    expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.chatId, parent.id))).toHaveLength(1)
    expect(await db.select().from(schema.updates)).toHaveLength(0)
  })

  test("a failure after prepared placement cleanup rolls back parent placement, pointers and chat deletion together", async () => {
    const { owner, grandparent, parent, child, placement } = await placedThreadWithChild()
    await db.delete(schema.chatParticipants).where(eq(schema.chatParticipants.chatId, child.id))
    await db.delete(schema.chats).where(eq(schema.chats.id, child.id))
    const enqueue = spyOn(UserBucketUpdates, "enqueueMany").mockImplementation(async () => {
      throw new Error("injected access update failure")
    })
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      await expect(
        deleteChat({ peer: inputPeerForChat(parent.id) }, testUtils.functionContext({ userId: owner.id })),
      ).rejects.toMatchObject({ code: RealtimeRpcError.Code.INTERNAL_ERROR })
      expect(
        await db.select().from(schema.messages).where(eq(schema.messages.globalId, placement.globalId)),
      ).toHaveLength(1)
      expect(await db.select().from(schema.chats).where(eq(schema.chats.id, parent.id))).toHaveLength(1)
      const [savedGrandparent] = await db.select().from(schema.chats).where(eq(schema.chats.id, grandparent.id))
      expect(savedGrandparent?.lastMsgId).toBe(1)
      expect(await db.select().from(schema.updates)).toHaveLength(0)
      expect(push.mock.calls).toHaveLength(0)
    } finally {
      enqueue.mockRestore()
      push.mockRestore()
    }
  })

  test("nested placement deletion refreshes the surviving parent's ancestor summary after commit", async () => {
    const { owner, grandparent, parent, child } = await placedThreadWithChild()
    const [childPlacement] = await db.insert(schema.messages)
      .values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "Child placement" }).returning()
    if (!childPlacement) throw new Error("Child placement missing")
    await db.insert(schema.subthreadParentMessages).values({ childChatId: child.id, parentMessageGlobalId: childPlacement.globalId })
    await db.update(schema.chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(schema.chats.id, parent.id))
    await deleteChat({ peer: inputPeerForChat(child.id) }, testUtils.functionContext({ userId: owner.id }))
    await applicationBackgroundWork.waitForIdle()
    const [savedParent] = await db.select().from(schema.chats).where(eq(schema.chats.id, parent.id))
    expect(savedParent?.lastMsgId).toBeNull()
    expect(await db.select().from(schema.messages).where(eq(schema.messages.globalId, childPlacement.globalId))).toHaveLength(0)
    const ancestorUpdates = await db.select().from(schema.updates)
      .where(and(eq(schema.updates.bucket, schema.UpdateBucket.Chat), eq(schema.updates.entityId, grandparent.id)))
    const edits = ancestorUpdates.map((row) => UpdatesModel.decrypt(row).payload.update)
      .filter((update) => update.oneofKind === "editMessage")
    expect(edits).toHaveLength(1)
    expect(edits[0]?.oneofKind === "editMessage" ? edits[0].editMessage.msgId : undefined).toBe(1n)
  })

  test("a waiting participant delete cannot use revoked access or stale empty-chat state", async () => {
    for (const revokeAccess of [false, true]) {
      const owner = await testUtils.createUser(`delete-current-owner-${revokeAccess}@example.test`)
      const actor = await testUtils.createUser(`delete-current-actor-${revokeAccess}@example.test`)
      const chat = await testUtils.createChat(null, "", "thread", false, owner.id)
      if (!chat) throw new Error("Delete current-state fixture missing")
      await testUtils.addParticipant(chat.id, owner.id)
      await testUtils.addParticipant(chat.id, actor.id)
      await db.update(schema.chats).set({ isUntitled: true }).where(eq(schema.chats.id, chat.id))
      const release = deferred<void>()
      const acquired = deferred<number>()
      const blocker = db.transaction(async (tx) => {
        await tx.select().from(schema.chats).where(eq(schema.chats.id, chat.id)).for("update")
        const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
        acquired.resolve(Number(pid!["pid"]))
        await release.promise
        if (revokeAccess) {
          await tx.delete(schema.chatParticipants).where(and(
            eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, actor.id),
          ))
        } else {
          await tx.insert(schema.messages).values({ chatId: chat.id, fromId: owner.id, messageId: 1, text: "Arrived before deletion" })
          await tx.update(schema.chats).set({ messageIdCounter: 1, lastMsgId: 1 }).where(eq(schema.chats.id, chat.id))
        }
      })
      const blockerPid = await acquired.promise
      const deletion = deleteChat({ peer: inputPeerForChat(chat.id) }, testUtils.functionContext({ userId: actor.id }))
        .then((value) => ({ value }), (error: unknown) => ({ error }))
      try {
        await waitForBlockedDelete(blockerPid)
        release.resolve()
        await blocker
        const outcome = await deletion
        expect("error" in outcome ? outcome.error : undefined).toMatchObject({ code: RealtimeRpcError.Code.UNAUTHENTICATED })
        expect(await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))).toHaveLength(1)
        expect(await db.select().from(schema.updates)).toHaveLength(0)
      } finally {
        release.resolve()
        await blocker
        await deletion
      }
    }
  })

  test("placement deletion completes using the only available pool connection", async () => {
    const { owner, parent, child, placement } = await placedThreadWithChild()
    await db.delete(schema.chatParticipants).where(eq(schema.chatParticipants.chatId, child.id))
    await db.delete(schema.chats).where(eq(schema.chats.id, child.id))
    const release = deferred<void>()
    const acquired = deferred<void>()
    let leased = 0
    const leases = Array.from({ length: 9 }, () => db.transaction(async (tx) => {
      await tx.execute(sql`select 1`)
      if (++leased === 9) acquired.resolve()
      await release.promise
    }))
    await acquired.promise
    const deletion = deleteChat({ peer: inputPeerForChat(parent.id) }, testUtils.functionContext({ userId: owner.id }))
      .then((value) => ({ value }), (error: unknown) => ({ error }))
    try {
      const result = await Promise.race([
        deletion,
        Bun.sleep(3_000).then(() => ({ timedOut: true as const })),
      ])
      expect("timedOut" in result).toBe(false)
      if ("error" in result) throw result.error
      expect("value" in result).toBe(true)
    } finally {
      release.resolve()
      await Promise.all(leases)
      await deletion
    }
    expect(await db.select().from(schema.chats).where(eq(schema.chats.id, parent.id))).toHaveLength(0)
    expect(await db.select().from(schema.messages).where(eq(schema.messages.globalId, placement.globalId))).toHaveLength(0)
  })

  for (const operation of ["follow", "open"] as const) {
    test(`chat deletion lets a missing dialog ${operation} finish before acquiring recipient ownership`, async () => {
      const owner = await testUtils.createUser(`delete-owner-${operation}-fk@example.test`)
      const chat = await testUtils.createChat(null, "Disposable task", "thread", false, owner.id)
      if (!chat) throw new Error("Chat missing")
      await testUtils.addParticipant(chat.id, owner.id)
      const acquired = deferred<number>()
      const resumeDialog = deferred<void>()
      const originalTransaction = db.transaction.bind(db)
      const transaction = spyOn(db, "transaction").mockImplementationOnce((callback, config) => originalTransaction(async (tx) => {
        await tx.select().from(schema.users).where(eq(schema.users.id, owner.id)).for("no key update")
        const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
        acquired.resolve(Number(pid!["pid"]))
        await resumeDialog.promise
        return callback(tx)
      }, config))
      const dialogMutation = (operation === "follow"
        ? setDialogFollowModeForUsers({ chat, userIds: [owner.id], followMode: "following", pushRealtime: false })
        : setDialogOpenForUsers({ chat, userIds: [owner.id], open: true }))
        .then((value) => ({ value }), (error: unknown) => ({ error }))
      const ownerPid = await acquired.promise
      const deletion = deleteChat({ peer: inputPeerForChat(chat.id) }, testUtils.functionContext({ userId: owner.id }))
        .then((value) => ({ value }), (error: unknown) => ({ error }))
      try {
        await waitForBlockedDelete(ownerPid)
        resumeDialog.resolve()
        const [dialogResult, deleteResult] = await Promise.all([dialogMutation, deletion])
        if ("error" in dialogResult) throw dialogResult.error
        if ("error" in deleteResult) throw deleteResult.error
        expect(await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))).toHaveLength(0)
        expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.chatId, chat.id))).toHaveLength(0)
      } finally {
        resumeDialog.resolve()
        transaction.mockRestore()
        await Promise.all([dialogMutation, deletion])
      }
    })
  }

  test("deleting a source chat deletes materialized backlink messages", async () => {
    const currentUser = await testUtils.createUser("delete-chat-graph-owner@example.com")
    const source = await testUtils.createChat(null, "Delete Chat Link Source", "thread", false, currentUser.id)
    const target = await testUtils.createChat(null, "Delete Chat Link Target", "thread", false, currentUser.id)
    if (!source || !target) {
      throw new Error("Graph delete-chat test chats not created")
    }

    await testUtils.addParticipant(source.id, currentUser.id)
    await testUtils.addParticipant(target.id, currentUser.id)

    const sent = await sendMessage(
      {
        peerId: inputPeerForChat(source.id),
        message: "see target",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.THREAD,
              offset: 4n,
              length: 6n,
              entity: {
                oneofKind: "thread",
                thread: { chatId: BigInt(target.id) },
              },
            },
          ],
        },
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const sentMessageId =
      sent.updates[0]?.update.oneofKind === "updateMessageId"
        ? sent.updates[0].update.updateMessageId.messageId
        : undefined
    expect(sentMessageId).toBeTruthy()

    const backlinkMessageGlobalId = await waitForThreadBacklink({
      fromChatId: source.id,
      fromMessageId: Number(sentMessageId),
      toChatId: target.id,
    })

    await deleteChat(
      {
        peer: inputPeerForChat(source.id),
      },
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const backlinkMessages = await db
      .select({ globalId: schema.messages.globalId })
      .from(schema.messages)
      .where(eq(schema.messages.globalId, backlinkMessageGlobalId))
    expect(backlinkMessages).toHaveLength(0)
  })

  test("conditionally deletes a closed empty anchored reply thread", async () => {
    const currentUser = await testUtils.createUser("delete-closed-reply-thread-owner@example.com")
    const parent = await testUtils.createChat(null, "Parent", "thread", false, currentUser.id)
    const replyThread = await testUtils.createChat(null, "", "thread", false, currentUser.id)
    if (!parent || !replyThread) {
      throw new Error("Conditional delete test chats not created")
    }

    await testUtils.addParticipant(parent.id, currentUser.id)
    await testUtils.addParticipant(replyThread.id, currentUser.id)
    await db.insert(schema.messages).values({
      chatId: parent.id,
      messageId: 1,
      fromId: currentUser.id,
      text: "parent message",
    })
    await db
      .update(schema.chats)
      .set({ isUntitled: true, parentChatId: parent.id, parentMessageId: 1 })
      .where(eq(schema.chats.id, replyThread.id))
    await db.insert(schema.dialogs).values({
      chatId: replyThread.id,
      userId: currentUser.id,
      open: false,
    })

    await deleteEmptyUntitledThreadAfterClose(
      replyThread.id,
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const [savedReplyThread] = await db
      .select()
      .from(schema.chats)
      .where(eq(schema.chats.id, replyThread.id))
      .limit(1)
    const [savedParentMessage] = await db
      .select()
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, parent.id), eq(schema.messages.messageId, 1)))
      .limit(1)

    expect(savedReplyThread).toBeUndefined()
    expect(savedParentMessage).toBeDefined()
  })

  test("conditional cleanup retains a closed thread that gained a message", async () => {
    const currentUser = await testUtils.createUser("retain-active-closed-thread-owner@example.com")
    const thread = await testUtils.createChat(null, "", "thread", false, currentUser.id)
    if (!thread) {
      throw new Error("Conditional retain test chat not created")
    }

    await testUtils.addParticipant(thread.id, currentUser.id)
    await db.update(schema.chats).set({ isUntitled: true }).where(eq(schema.chats.id, thread.id))
    await db.insert(schema.dialogs).values({
      chatId: thread.id,
      userId: currentUser.id,
      open: false,
    })
    await db.insert(schema.messages).values({
      chatId: thread.id,
      messageId: 1,
      fromId: currentUser.id,
      text: "arrived before cleanup",
    })

    await deleteEmptyUntitledThreadAfterClose(
      thread.id,
      testUtils.functionContext({ userId: currentUser.id }),
    )

    const [savedThread] = await db.select().from(schema.chats).where(eq(schema.chats.id, thread.id)).limit(1)
    expect(savedThread).toBeDefined()
  })

  for (const linked of [false, true]) {
    for (const operation of ["reopen", "pin"] as const) {
      for (const dialogWins of [true, false]) {
        test(`conditional cleanup ${dialogWins ? "preserves a committed" : "finishes before a waiting"} ${operation} for ${linked ? "a linked child without a user frontier" : "an independent task"}`, async () => {
          const other = await testUtils.createUser(`cleanup-recipient-${linked}-${operation}-${dialogWins}@example.test`)
          const owner = await testUtils.createUser(`cleanup-owner-${linked}-${operation}-${dialogWins}@example.test`)
          const parent = linked ? await testUtils.createChat(null, "Task parent", "thread", false, owner.id) : undefined
          const chat = await testUtils.createChat(null, "", "thread", false, owner.id)
          if (!chat || (linked && !parent)) throw new Error("Cleanup race chat missing")
          await testUtils.addParticipant(parent?.id ?? chat.id, other.id)
          await testUtils.addParticipant(parent?.id ?? chat.id, owner.id)
          let placementId: bigint | undefined
          if (parent) {
            const [placement] = await db.insert(schema.messages)
              .values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "Task placement" }).returning()
            if (!placement) throw new Error("Cleanup race placement missing")
            placementId = placement.globalId
            await db.insert(schema.subthreadParentMessages)
              .values({ childChatId: chat.id, parentMessageGlobalId: placement.globalId })
            await db.update(schema.chats).set({ lastMsgId: 1, messageIdCounter: 1 }).where(eq(schema.chats.id, parent.id))
          }
          await db.update(schema.chats).set({ isUntitled: true, parentChatId: parent?.id ?? null })
            .where(eq(schema.chats.id, chat.id))
          await db.insert(schema.dialogs).values({
            chatId: chat.id, userId: owner.id, open: false, pinned: false, chatListHidden: linked ? true : null,
          })
          const acquired = deferred<number>()
          const resume = deferred<void>()
          const originalTransaction = db.transaction.bind(db)
          let transactionsStarted = 0
          const transaction = spyOn(db, "transaction").mockImplementation((callback, config) => originalTransaction(async (tx) => {
            await tx.execute(sql`set local lock_timeout = '3s'`)
            await tx.execute(sql`set local statement_timeout = '5s'`)
            if (dialogWins && transactionsStarted++ === 0) {
              // Pause only scheduling: the real writer continues using this tx.
              await tx.select().from(schema.users).where(eq(schema.users.id, owner.id)).for("no key update")
              const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
              acquired.resolve(Number(pid!["pid"]))
              await resume.promise
            }
            return callback(tx)
          }, config))
          const originalInsertUpdate = UpdatesModel.insertUpdate.bind(UpdatesModel)
          const insertUpdate = spyOn(UpdatesModel, "insertUpdate").mockImplementation(async (tx, input) => {
            if (!dialogWins && input.bucket === schema.UpdateBucket.Chat && input.entity.id === chat.id && input.update.oneofKind === "deleteChat") {
              // Cleanup has passed its gate and owns the users, before DELETE's
              // natural lock upgrade. A competing writer must wait without KEY SHARE.
              const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
              acquired.resolve(Number(pid!["pid"]))
              await resume.promise
            }
            return originalInsertUpdate(tx, input)
          })
          const mutateDialog = async () => operation === "reopen"
            ? updateDialogOpen({ peerId: inputPeerForChat(chat.id), open: true }, testUtils.functionContext({ userId: owner.id }))
            : updateDialog({ peerThreadId: String(chat.id), pinned: true }, { currentUserId: owner.id, currentSessionId: 0, ip: "127.0.0.1" })
          const cleanup = () => deleteEmptyUntitledThreadAfterClose(chat.id, testUtils.functionContext({ userId: owner.id }))
          const first = (dialogWins ? mutateDialog() : cleanup()).then(
            (value) => ({ value }), (error: unknown) => ({ error }),
          )
          let second: typeof first | undefined
          try {
            const ownerPid = await finishSqlRace(acquired.promise)
            second = (dialogWins ? cleanup() : mutateDialog()).then(
              (value) => ({ value }), (error: unknown) => ({ error }),
            )
            await waitForBlockedDelete(ownerPid)
            resume.resolve()
            const [firstResult, secondResult] = await finishSqlRace(Promise.all([first, second]))
            if ("error" in firstResult) throw firstResult.error
            if (dialogWins) {
              if ("error" in secondResult) throw secondResult.error
              expect(await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))).toHaveLength(1)
              const [dialog] = await db.select().from(schema.dialogs).where(and(
                eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, owner.id),
              ))
              expect(dialog?.open).toBe(true)
              expect(dialog?.pinned).toBe(operation === "pin")
              const deleted = (await db.select().from(schema.updates)).map((row) => UpdatesModel.decrypt(row).payload.update)
                .filter((update) => update.oneofKind === "deleteChat" || update.oneofKind === "userRemovedFromChat")
              expect(deleted).toHaveLength(0)
            } else {
              expect("error" in secondResult).toBe(true)
              if ("error" in secondResult) {
                expect(secondResult.error).toMatchObject(operation === "pin"
                  ? { type: InlineError.ApiError.PEER_INVALID[0] }
                  : { code: RealtimeRpcError.Code.CHAT_ID_INVALID })
              }
              expect(await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))).toHaveLength(0)
              expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.chatId, chat.id))).toHaveLength(0)
            }
            if (placementId !== undefined && parent) {
              expect(await db.select().from(schema.messages).where(eq(schema.messages.globalId, placementId)))
                .toHaveLength(dialogWins ? 1 : 0)
              expect(await db.select().from(schema.chats).where(eq(schema.chats.id, parent.id))).toHaveLength(1)
            }
          } finally {
            resume.resolve()
            try {
              await finishSqlRace(Promise.all(second ? [first, second] : [first]))
            } finally {
              insertUpdate.mockRestore()
              transaction.mockRestore()
            }
          }
        })
      }
    }
  }

  for (const linked of [false, true]) {
    for (const operation of ["reopen", "pin"] as const) {
      test(`a waiting ${operation} rechecks ${linked ? "inherited parent" : "direct"} access after acquiring its user owner`, async () => {
        const owner = await testUtils.createUser(`dialog-revoke-owner-${linked}-${operation}@example.test`)
        const actor = await testUtils.createUser(`dialog-revoke-actor-${linked}-${operation}@example.test`)
        const root = await testUtils.createChat(null, "Private root", "thread", false, owner.id)
        const child = linked ? await testUtils.createChat(null, "Child task", "thread", false, owner.id) : undefined
        if (!root || (linked && !child)) throw new Error("Pin current-access fixture missing")
        await testUtils.addParticipant(root.id, owner.id)
        await testUtils.addParticipant(root.id, actor.id)
        if (child) await db.update(schema.chats).set({ parentChatId: root.id }).where(eq(schema.chats.id, child.id))
        const chat = child ?? root
        await db.insert(schema.dialogs).values({ chatId: chat.id, userId: actor.id, open: false, pinned: false })
        const release = deferred<void>()
        const acquired = deferred<number>()
        const originalTransaction = db.transaction.bind(db)
        const transaction = spyOn(db, "transaction").mockImplementation((callback, config) => originalTransaction(async (tx) => {
          await tx.execute(sql`set local lock_timeout = '3s'`)
          await tx.execute(sql`set local statement_timeout = '5s'`)
          return callback(tx)
        }, config))
        const revoke = db.transaction(async (tx) => {
          await tx.select().from(schema.users).where(eq(schema.users.id, actor.id)).for("no key update")
          const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
          acquired.resolve(Number(pid!["pid"]))
          await release.promise
          await tx.delete(schema.chatParticipants).where(and(
            eq(schema.chatParticipants.chatId, root.id), eq(schema.chatParticipants.userId, actor.id),
          ))
        })
        const mutation = (async () => {
          await finishSqlRace(acquired.promise)
          return operation === "reopen"
            ? updateDialogOpen({ peerId: inputPeerForChat(chat.id), open: true }, testUtils.functionContext({ userId: actor.id }))
            : updateDialog({ peerThreadId: String(chat.id), pinned: true }, {
                currentUserId: actor.id, currentSessionId: 0, ip: "127.0.0.1",
              })
        })().then((value) => ({ value }), (error: unknown) => ({ error }))
        try {
          const ownerPid = await finishSqlRace(acquired.promise)
          await waitForBlockedDelete(ownerPid)
          release.resolve()
          await finishSqlRace(revoke)
          const outcome = await finishSqlRace(mutation)
          expect("error" in outcome ? outcome.error : undefined).toMatchObject(operation === "pin"
            ? { type: InlineError.ApiError.PEER_INVALID[0] }
            : { code: RealtimeRpcError.Code.PEER_ID_INVALID })
          const [dialog] = await db.select().from(schema.dialogs).where(and(
            eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, actor.id),
          ))
          expect(dialog?.open).toBe(false)
          expect(dialog?.pinned).toBe(false)
          expect(await db.select().from(schema.updates)).toHaveLength(0)
        } finally {
          release.resolve()
          try {
            await finishSqlRace(Promise.all([revoke, mutation]))
          } finally {
            transaction.mockRestore()
          }
        }
      })
    }
  }

  test("fans out child-thread deletion to its effective recipients", async () => {
    const owner = await testUtils.createUser("delete-child-owner@example.com")
    const participant = await testUtils.createUser("delete-child-participant@example.com")
    if (!owner || !participant) throw new Error("Delete child users not created")
    const parent = await testUtils.createChat(null, "Delete Child Parent", "thread", false, owner.id)
    if (!parent) throw new Error("Delete child parent not created")
    await testUtils.addParticipant(parent.id, owner.id)
    await testUtils.addParticipant(parent.id, participant.id)
    await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "anchor" })
    const [child] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Delete Child",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parent.id,
        parentMessageId: 1,
      })
      .returning()
    if (!child) throw new Error("Delete child not created")

    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      await deleteChat(
        { peer: inputPeerForChat(child.id) },
        testUtils.functionContext({ userId: owner.id }),
      )

      const deleteRecipients = push.mock.calls.flatMap(([userId, updates]) =>
        updates.some((update) => update.update.oneofKind === "deleteChat") ? [userId] : []
      )
      expect(new Set(deleteRecipients)).toEqual(new Set([owner.id, participant.id]))
    } finally {
      push.mockRestore()
    }
  })
})

async function waitForThreadBacklink(input: {
  fromChatId: number
  fromMessageId: number
  toChatId: number
}): Promise<bigint> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const [link] = await db
      .select()
      .from(schema.threadGraphLinks)
      .where(
        and(
          eq(schema.threadGraphLinks.kind, "thread_link"),
          eq(schema.threadGraphLinks.fromChatId, input.fromChatId),
          eq(schema.threadGraphLinks.fromMessageId, input.fromMessageId),
          eq(schema.threadGraphLinks.toChatId, input.toChatId),
        ),
      )
      .limit(1)

    if (link?.backlinkMessageGlobalId) {
      return link.backlinkMessageGlobalId
    }

    await new Promise((resolve) => setTimeout(resolve, 10))
  }

  throw new Error(`Expected graph backlink for message ${input.fromChatId}:${input.fromMessageId}`)
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}

async function waitForBlockedDelete(blockerPid: number) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const [row] = await db.execute(sql<{ waiting: boolean }>`
      select exists(select 1 from pg_stat_activity where datname = current_database()
        and ${blockerPid} = any(pg_blocking_pids(pid))) as waiting
    `)
    if (row?.["waiting"]) return
    await Bun.sleep(5)
  }
  throw new Error("Delete did not wait for the held mutation lock")
}

async function finishSqlRace<T>(operation: Promise<T>): Promise<T> {
  const result = await Promise.race([
    operation.then((value) => ({ value })),
    Bun.sleep(6_000).then(() => ({ timedOut: true as const })),
  ])
  if ("timedOut" in result) throw new Error("SQL race did not finish within its deadline")
  return result.value
}
