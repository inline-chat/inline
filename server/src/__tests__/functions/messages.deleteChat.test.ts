import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, inArray, sql } from "drizzle-orm"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { closeDb, db, initDb, schema } from "@in/server/db"
import { deleteChat, deleteEmptyUntitledThreadAfterClose } from "@in/server/functions/messages.deleteChat"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { setupTestLifecycle, testUtils } from "../setup"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { UpdatesModel } from "@in/server/db/models/updates"
import { waitForPostCommitHooks } from "@in/server/db/commitHooks"
import { RealtimeRpcError } from "@in/server/realtime/errors"

const inputPeerForChat = (chatId: number) => ({
  type: {
    oneofKind: "chat" as const,
    chat: { chatId: BigInt(chatId) },
  },
})

describe("messages.deleteChat", () => {
  setupTestLifecycle()

  test("refuses a parent with child and grandchild before changing any state", async () => {
    const fixture = await placementFixture()
    const [grandchild] = await db.insert(schema.chats).values({
      type: "thread", title: "Grandchild", createdBy: fixture.owner.id,
      parentChatId: fixture.child.id, publicThread: false,
    }).returning()
    expect(grandchild).toBeDefined()
    const before = await deletionSnapshot()
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      for (const chatId of [fixture.parent.id, fixture.child.id]) {
        await expect(deleteChat({ peer: inputPeerForChat(chatId) }, fixture.context)).rejects.toMatchObject({
          code: RealtimeRpcError.Code.BAD_REQUEST, codeNumber: 400,
          message: "Delete child threads before deleting this thread",
        })
        expect(await deletionSnapshot()).toEqual(before)
      }
      expect(push).not.toHaveBeenCalled()
    } finally { push.mockRestore() }
  })

  test("conditional draft cleanup with a child is a no-op", async () => {
    const fixture = await placementFixture()
    await db.update(schema.chats).set({ isUntitled: true, title: "" }).where(eq(schema.chats.id, fixture.child.id))
    await db.insert(schema.dialogs).values({ chatId: fixture.child.id, userId: fixture.owner.id, open: false })
    await db.insert(schema.chats).values({ type: "thread", title: "Grandchild", createdBy: fixture.owner.id, parentChatId: fixture.child.id })
    const before = await deletionSnapshot()
    await expect(deleteEmptyUntitledThreadAfterClose(fixture.child.id, fixture.context)).resolves.toEqual({})
    expect(await deletionSnapshot()).toEqual(before)
  })

  test("conditional cleanup that gained a message preserves the generated parent placement", async () => {
    const fixture = await placementFixture()
    await db.update(schema.chats).set({ isUntitled: true, title: "" }).where(eq(schema.chats.id, fixture.child.id))
    await db.insert(schema.dialogs).values({ chatId: fixture.child.id, userId: fixture.owner.id, open: false })
    await db.insert(schema.messages).values({ chatId: fixture.child.id, messageId: 1, fromId: fixture.owner.id, text: "arrived" })
    const before = await deletionSnapshot()
    await deleteEmptyUntitledThreadAfterClose(fixture.child.id, fixture.context)
    expect(await deletionSnapshot()).toEqual(before)
  })

  test("a commit failure rolls back placement cleanup and durable updates", async () => {
    const fixture = await placementFixture()
    const before = await deletionSnapshot()
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    await db.execute(sql`CREATE FUNCTION test_reject_chat_delete() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test injected chat deletion failure'; END $$;
      CREATE CONSTRAINT TRIGGER test_reject_chat_delete AFTER DELETE ON chats
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION test_reject_chat_delete();`)
    try {
      await expect(deleteChat({ peer: inputPeerForChat(fixture.child.id) }, fixture.context)).rejects.toMatchObject({
        code: RealtimeRpcError.Code.INTERNAL_ERROR,
      })
      await waitForPostCommitHooks()
      expect(await deletionSnapshot()).toEqual(before)
      expect(push).not.toHaveBeenCalled()
    } finally {
      push.mockRestore()
      await db.execute(sql`DROP TRIGGER test_reject_chat_delete ON chats; DROP FUNCTION test_reject_chat_delete();`)
    }
  })

  test("a translated leaf and its placement delete atomically with durable replay", async () => {
    const fixture = await placementFixture()
    await db.insert(schema.messages).values({ chatId: fixture.child.id, messageId: 1, fromId: fixture.owner.id, text: "translated child" })
    await db.insert(schema.translations).values([
      { chatId: fixture.child.id, messageId: 1, language: "en" },
      { chatId: fixture.parent.id, messageId: 1, language: "en" },
    ])
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      await deleteChat({ peer: inputPeerForChat(fixture.child.id) }, fixture.context)
      await waitForPostCommitHooks()
      expect(await db.select().from(schema.chats).where(eq(schema.chats.id, fixture.child.id))).toHaveLength(0)
      expect(await db.select().from(schema.messages)).toHaveLength(0)
      expect(await db.select().from(schema.translations)).toHaveLength(0)
      expect(await db.select().from(schema.subthreadParentMessages)).toHaveLength(0)
      const persisted = (await db.select().from(schema.updates)).map(UpdatesModel.decrypt)
      expect(persisted.filter((row) => row.payload.update.oneofKind === "deleteChat" && row.entityId === fixture.child.id)).toHaveLength(1)
      expect(persisted.filter((row) => row.payload.update.oneofKind === "deleteMessages" && row.entityId === fixture.parent.id)).toHaveLength(1)
      expect(push.mock.calls.flatMap(([, updates]) => updates).filter((update) => update.update.oneofKind === "deleteChat")).toHaveLength(1)
      expect(push.mock.calls.flatMap(([, updates]) => updates).filter((update) => update.update.oneofKind === "deleteMessages")).toHaveLength(1)
    } finally { push.mockRestore() }
  })

  test("placed-leaf deletion completes with a one-connection database pool", async () => {
    const databaseUrl = process.env["DATABASE_URL"]
    if (!databaseUrl || !new URL(databaseUrl).pathname.startsWith("/test_db_")) {
      throw new Error("Expected the lifecycle-owned disposable test database")
    }
    const previousPoolMax = process.env["INLINE_DATABASE_QUERY_POOL_MAX"]
    await waitForPostCommitHooks()
    await closeDb()
    process.env["INLINE_DATABASE_QUERY_POOL_MAX"] = "1"
    initDb(databaseUrl)
    let deletion: Promise<{}> | undefined
    let deadline: ReturnType<typeof setTimeout> | undefined
    try {
      const fixture = await placementFixture()
      deletion = deleteChat({ peer: inputPeerForChat(fixture.child.id) }, fixture.context)
      await Promise.race([
        deletion,
        new Promise<never>((_resolve, reject) => {
          deadline = setTimeout(() => reject(new Error("Placed-leaf deletion escaped its transaction and exhausted the pool")), 3_000)
        }),
      ])
      await waitForPostCommitHooks()
      expect(await db.select().from(schema.chats).where(eq(schema.chats.id, fixture.child.id))).toHaveLength(0)
      expect(await db.select().from(schema.subthreadParentMessages)).toHaveLength(0)
      const persisted = (await db.select().from(schema.updates)).map(UpdatesModel.decrypt)
      expect(persisted.filter((row) => row.payload.update.oneofKind === "deleteChat")).toHaveLength(1)
      expect(persisted.filter((row) => row.payload.update.oneofKind === "deleteMessages")).toHaveLength(1)
    } finally {
      if (deadline) clearTimeout(deadline)
      // Closing the one-connection pool also settles a regression's blocked
      // transaction before restoring the ordinary pool for the remaining tests.
      await closeDb()
      if (deletion) await Promise.allSettled([deletion])
      if (previousPoolMax === undefined) delete process.env["INLINE_DATABASE_QUERY_POOL_MAX"]
      else process.env["INLINE_DATABASE_QUERY_POOL_MAX"] = previousPoolMax
      initDb(databaseUrl)
    }
  })

  test("leaf deletion preserves direct and inherited group recipients and root-only access replay", async () => {
    const fixture = await placementFixture()
    const space = await testUtils.createSpace("Delete group recipients")
    if (!space) throw new Error("Missing space")
    const groupMember = await testUtils.createUser("delete-group-member@example.test")
    const direct = await testUtils.createUser("delete-direct-member@example.test")
    const outsider = await testUtils.createUser("delete-outsider@example.test")
    await db.insert(schema.members).values([fixture.owner, groupMember, direct].map((user) => ({ userId: user.id, spaceId: space.id, role: "member" as const })))
    await db.update(schema.chats).set({ spaceId: space.id }).where(inArray(schema.chats.id, [fixture.parent.id, fixture.child.id]))
    const [group] = await db.insert(schema.userGroups).values({ spaceId: space.id, name: "Readers", createdBy: fixture.owner.id }).returning()
    if (!group) throw new Error("Missing group")
    await db.insert(schema.userGroupMembers).values({ groupId: group.id, userId: groupMember.id })
    await db.insert(schema.chatParticipantGroups).values({ groupId: group.id, chatId: fixture.parent.id })
    await testUtils.addParticipant(fixture.child.id, direct.id)
    const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
    try {
      const before = await deletionSnapshot()
      await expect(deleteChat({ peer: inputPeerForChat(fixture.child.id) }, testUtils.functionContext({ userId: outsider.id }))).rejects.toBeInstanceOf(RealtimeRpcError)
      expect(await deletionSnapshot()).toEqual(before)
      expect(push).not.toHaveBeenCalled()
      await deleteChat({ peer: inputPeerForChat(fixture.child.id) }, fixture.context)
      await waitForPostCommitHooks()
      const recipients = push.mock.calls.flatMap(([userId, updates]) => updates.some((update) => update.update.oneofKind === "deleteChat") ? [userId] : [])
      expect(new Set(recipients)).toEqual(new Set([fixture.owner.id, groupMember.id, direct.id]))
      const childReplay = (await db.select().from(schema.updates)).map(UpdatesModel.decrypt)
      expect(childReplay.filter((row) => row.payload.update.oneofKind === "userRemovedFromChat")).toHaveLength(0)
      push.mockClear()
      await deleteChat({ peer: inputPeerForChat(fixture.parent.id) }, fixture.context)
      const rootReplay = (await db.select().from(schema.updates)).map(UpdatesModel.decrypt)
        .filter((row) => row.payload.update.oneofKind === "userRemovedFromChat")
      expect(new Set(rootReplay.map((row) => row.entityId))).toEqual(new Set([fixture.owner.id, groupMember.id]))
      for (const row of rootReplay) expect(row.payload.update).toMatchObject({ userRemovedFromChat: { chatId: BigInt(fixture.parent.id) } })
    } finally { push.mockRestore() }
  })

  for (const change of ["message_arrived", "creator_removed"] as const) {
    test(`rechecks deletion authority after the chat lock: ${change}`, async () => {
      const fixture = await placementFixture()
      const actor = change === "message_arrived"
        ? await testUtils.createUser("delete-empty-participant@example.test")
        : fixture.owner
      if (change === "message_arrived") {
        await testUtils.addParticipant(fixture.child.id, actor.id)
        await db.update(schema.chats).set({ title: "", isUntitled: true }).where(eq(schema.chats.id, fixture.child.id))
      }
      const locked = Promise.withResolvers<number>()
      const release = Promise.withResolvers<void>()
      const mutation = db.transaction(async (tx) => {
        await tx.select().from(schema.chats).where(eq(schema.chats.id, fixture.child.id)).for("update")
        const [{ pid } = { pid: 0 }] = await tx.execute<{ pid: number }>(sql`SELECT pg_backend_pid() AS pid`)
        locked.resolve(pid)
        await release.promise
        if (change === "message_arrived") {
          await tx.insert(schema.messages).values({ chatId: fixture.child.id, messageId: 1, fromId: fixture.owner.id, text: "Arrived while deletion waited" })
          await tx.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, fixture.child.id))
        } else {
          await tx.delete(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, fixture.parent.id), eq(schema.chatParticipants.userId, actor.id)))
        }
      })
      const push = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {})
      let deletion: Promise<{}> | undefined
      try {
        const pid = await Promise.race([locked.promise, mutation.then(() => { throw new Error("Mutation finished before its barrier") })])
        deletion = deleteChat({ peer: inputPeerForChat(fixture.child.id) }, testUtils.functionContext({ userId: actor.id }))
        const result = deletion.then(() => undefined, (error: unknown) => error)
        await waitForBlockedBy(pid)
        release.resolve()
        await mutation
        expect(await result).toMatchObject({ code: RealtimeRpcError.Code.UNAUTHENTICATED, codeNumber: 403 })
        await waitForPostCommitHooks()
        expect(await db.select().from(schema.chats).where(eq(schema.chats.id, fixture.child.id))).toHaveLength(1)
        expect(await db.select().from(schema.subthreadParentMessages)).toHaveLength(1)
        expect(await db.select().from(schema.messages)).toHaveLength(change === "message_arrived" ? 2 : 1)
        expect(await db.select().from(schema.updates)).toHaveLength(0)
        expect(push).not.toHaveBeenCalled()
      } finally {
        release.resolve()
        await Promise.allSettled([mutation, ...(deletion ? [deletion] : [])])
        push.mockRestore()
      }
    })
  }

  test("a child committed while deletion waits is retained with a clear parent refusal", async () => {
    const fixture = await placementFixture()
    const inserted = Promise.withResolvers<number>()
    const release = Promise.withResolvers<void>()
    const creator = db.transaction(async (tx) => {
      const [{ pid } = { pid: 0 }] = await tx.execute<{ pid: number }>(sql`SELECT pg_backend_pid() AS pid`)
      await tx.insert(schema.chats).values({ type: "thread", title: "Concurrent child", parentChatId: fixture.child.id, createdBy: fixture.owner.id })
      inserted.resolve(pid)
      await release.promise
    })
    let deletion: Promise<{}> | undefined
    try {
      const pid = await Promise.race([inserted.promise, creator.then(() => { throw new Error("Creator finished before its barrier") })])
      deletion = deleteChat({ peer: inputPeerForChat(fixture.child.id) }, fixture.context)
      // Attach a rejection handler before releasing the competing transaction.
      const result = deletion.then(() => undefined, (error: unknown) => error)
      await waitForBlockedBy(pid)
      release.resolve()
      await creator
      expect(await result).toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
      expect(await db.select().from(schema.chats)).toHaveLength(3)
      expect(await db.select().from(schema.messages)).toHaveLength(1)
      expect(await db.select().from(schema.subthreadParentMessages)).toHaveLength(1)
      expect(await db.select().from(schema.updates)).toHaveLength(0)
    } finally {
      release.resolve()
      await Promise.allSettled([creator, ...(deletion ? [deletion] : [])])
    }
  })

  test("a deletion holding the parent row fences a concurrent child insert", async () => {
    const owner = await testUtils.createUser("delete-fence-owner@example.test")
    const parent = await testUtils.createChat(null, "Delete fence", "thread", false, owner.id)
    if (!parent) throw new Error("Missing parent")
    await testUtils.addParticipant(parent.id, owner.id)
    const locked = Promise.withResolvers<number>()
    const release = Promise.withResolvers<void>()
    const originalInsert = UpdatesModel.insertUpdate
    const insertUpdate = spyOn(UpdatesModel, "insertUpdate").mockImplementation(async (tx, input) => {
      const result = await originalInsert(tx, input)
      if (input.update.oneofKind === "deleteChat") {
        const [{ pid } = { pid: 0 }] = await tx.execute<{ pid: number }>(sql`SELECT pg_backend_pid() AS pid`)
        locked.resolve(pid)
        await release.promise
      }
      return result
    })
    const deletion = deleteChat({ peer: inputPeerForChat(parent.id) }, testUtils.functionContext({ userId: owner.id }))
    let creation: Promise<unknown> | undefined
    try {
      const pid = await Promise.race([locked.promise, deletion.then(() => { throw new Error("Deletion finished before its barrier") })])
      creation = db.insert(schema.chats).values({ type: "thread", title: "Too late", parentChatId: parent.id, createdBy: owner.id }).then((result) => result)
      const result = creation.then(() => undefined, (error: unknown) => error)
      await waitForBlockedBy(pid)
      release.resolve()
      await deletion
      expect(await result).toBeInstanceOf(Error)
      expect(await db.select().from(schema.chats)).toHaveLength(0)
      const persisted = (await db.select().from(schema.updates)).map(UpdatesModel.decrypt)
      expect(persisted.filter((row) => row.payload.update.oneofKind === "deleteChat")).toHaveLength(1)
    } finally {
      release.resolve()
      await Promise.allSettled([deletion, ...(creation ? [creation] : [])])
      insertUpdate.mockRestore()
    }
  })

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

  test("a creator removed from a private space thread cannot delete it", async () => {
    const space = await testUtils.createSpace("Delete Removed Creator Space")
    if (!space) throw new Error("Failed to create space")
    const creator = await testUtils.createUser("delete-removed-creator@example.com")
    const remaining = await testUtils.createUser("delete-removed-creator-remaining@example.com")
    await db.insert(schema.members).values([
      { userId: creator.id, spaceId: space.id, role: "member" },
      { userId: remaining.id, spaceId: space.id, role: "member" },
    ])
    const chat = await createThreadWithMessage(space.id, "Removed Creator Thread", creator.id, [creator.id, remaining.id])

    // Removed from the thread, still a member of the Space.
    await removeParticipant(chat.id, creator.id)

    await expect(
      deleteChat({ peer: inputPeerForChat(chat.id) }, testUtils.functionContext({ userId: creator.id })),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
    await expectThreadIntact(chat.id, [remaining.id])
  })

  test("a creator removed from a home thread cannot delete it", async () => {
    const creator = await testUtils.createUser("delete-removed-home-creator@example.com")
    const remaining = await testUtils.createUser("delete-removed-home-remaining@example.com")
    const chat = await createThreadWithMessage(null, "Removed Home Thread", creator.id, [creator.id, remaining.id])

    await removeParticipant(chat.id, creator.id)

    await expect(
      deleteChat({ peer: inputPeerForChat(chat.id) }, testUtils.functionContext({ userId: creator.id })),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
    await expectThreadIntact(chat.id, [remaining.id])
  })

  test("a current creator and a space admin can still delete threads", async () => {
    const space = await testUtils.createSpace("Delete Authority Space")
    if (!space) throw new Error("Failed to create space")
    const creator = await testUtils.createUser("delete-current-creator@example.com")
    const admin = await testUtils.createUser("delete-space-admin@example.com")
    await db.insert(schema.members).values([
      { userId: creator.id, spaceId: space.id, role: "member" },
      { userId: admin.id, spaceId: space.id, role: "admin" },
    ])
    const creatorThread = await createThreadWithMessage(space.id, "Creator Deletes", creator.id, [creator.id])
    // The admin is not a participant of this private thread.
    const adminThread = await createThreadWithMessage(space.id, "Admin Deletes", creator.id, [creator.id])
    const homeThread = await createThreadWithMessage(null, "Creator Deletes Home", creator.id, [creator.id])

    await deleteChat({ peer: inputPeerForChat(creatorThread.id) }, testUtils.functionContext({ userId: creator.id }))
    await deleteChat({ peer: inputPeerForChat(adminThread.id) }, testUtils.functionContext({ userId: admin.id }))
    await deleteChat({ peer: inputPeerForChat(homeThread.id) }, testUtils.functionContext({ userId: creator.id }))

    const remaining = await db
      .select({ id: schema.chats.id })
      .from(schema.chats)
      .where(inArray(schema.chats.id, [creatorThread.id, adminThread.id, homeThread.id]))
    expect(remaining).toHaveLength(0)
  })
})

async function createThreadWithMessage(
  spaceId: number | null,
  title: string,
  creatorId: number,
  participantIds: number[],
): Promise<schema.DbChat> {
  const chat = await testUtils.createChat(spaceId, title, "thread", false, creatorId)
  if (!chat) throw new Error("Failed to create thread")
  for (const userId of participantIds) {
    await testUtils.addParticipant(chat.id, userId)
  }
  await db.insert(schema.messages).values({ chatId: chat.id, messageId: 1, fromId: creatorId, text: "keep me" })
  await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, chat.id))
  return chat
}

async function removeParticipant(chatId: number, userId: number) {
  await db
    .delete(schema.chatParticipants)
    .where(and(eq(schema.chatParticipants.chatId, chatId), eq(schema.chatParticipants.userId, userId)))
}

async function expectThreadIntact(chatId: number, participantIds: number[]) {
  const [chat] = await db.select({ id: schema.chats.id }).from(schema.chats).where(eq(schema.chats.id, chatId))
  expect(chat?.id).toBe(chatId)
  const participants = await db
    .select({ userId: schema.chatParticipants.userId })
    .from(schema.chatParticipants)
    .where(eq(schema.chatParticipants.chatId, chatId))
  expect(participants.map((row) => row.userId).sort()).toEqual([...participantIds].sort())
  const messages = await db
    .select({ messageId: schema.messages.messageId })
    .from(schema.messages)
    .where(eq(schema.messages.chatId, chatId))
  expect(messages).toHaveLength(1)
}

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

async function placementFixture() {
  const owner = await testUtils.createUser("delete-atomic-owner@example.test")
  const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
  if (!parent) throw new Error("Missing parent")
  await testUtils.addParticipant(parent.id, owner.id)
  const [child] = await db.insert(schema.chats).values({
    type: "thread", title: "Child", createdBy: owner.id, parentChatId: parent.id, publicThread: false,
  }).returning()
  if (!child) throw new Error("Missing child")
  const [placement] = await db.insert(schema.messages).values({
    chatId: parent.id, messageId: 1, fromId: owner.id, text: "Child placement",
  }).returning()
  if (!placement) throw new Error("Missing placement")
  await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, parent.id))
  await db.insert(schema.subthreadParentMessages).values({ childChatId: child.id, parentMessageGlobalId: placement.globalId })
  return { owner, parent, child, placement, context: testUtils.functionContext({ userId: owner.id }) }
}

async function deletionSnapshot() {
  return {
    chats: await db.select().from(schema.chats).orderBy(schema.chats.id),
    messages: await db.select().from(schema.messages).orderBy(schema.messages.globalId),
    placements: await db.select().from(schema.subthreadParentMessages).orderBy(schema.subthreadParentMessages.childChatId),
    participants: await db.select().from(schema.chatParticipants).orderBy(schema.chatParticipants.id),
    dialogs: await db.select().from(schema.dialogs).orderBy(schema.dialogs.id),
    updates: await db.select().from(schema.updates).orderBy(schema.updates.id),
  }
}

async function waitForBlockedBy(pid: number) {
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    const rows = await db.execute<{ blocked: boolean }>(sql`
      SELECT EXISTS (
        SELECT 1 FROM pg_stat_activity WHERE datname = current_database()
        AND ${pid} = ANY(pg_blocking_pids(pid))
      ) AS blocked
    `)
    if (rows[0]?.blocked) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error("Expected a concurrent mutation waiting for the deletion fence")
}
