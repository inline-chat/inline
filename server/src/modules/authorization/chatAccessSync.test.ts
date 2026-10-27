import { describe, expect, spyOn, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { addChatParticipant } from "@in/server/functions/messages.addChatParticipant"
import { deleteChat } from "@in/server/functions/messages.deleteChat"
import { moveThread } from "@in/server/functions/messages.moveThread"
import { removeChatParticipant } from "@in/server/functions/messages.removeChatParticipant"
import { addSpaceMember } from "@in/server/functions/space.addMember.shared"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { deleteMemberHandler } from "@in/server/realtime/handlers/space.deleteMember"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { syncChatAccess } from "./chatAccessSync"
import { verifyChatAccess } from "./chatAccessVerifier"

const accessUserIds = async (chatId: number): Promise<number[]> =>
  (await db.select().from(schema.chatAccess).where(eq(schema.chatAccess.chatId, chatId)))
    .map((row) => row.userId)
    .sort((a, b) => a - b)

/** The table matches the canonical projection for every chat. */
const expectInSync = async () => {
  const result = await verifyChatAccess({ repair: false })
  expect({ missing: result.missing, extra: result.extra, orphans: result.orphans, samples: result.samples })
    .toEqual({ missing: 0, extra: 0, orphans: 0, samples: [] })
}

const homeThread = async (creatorId: number, title: string) => {
  const chat = await testUtils.createChat(null, title, "thread", false, creatorId)
  if (!chat) throw new Error("Thread not created")
  await testUtils.addParticipant(chat.id, creatorId)
  return chat
}

const subthread = async (parentId: number, creatorId: number) => {
  const [child] = await db.insert(schema.chats).values({
    type: "thread", title: "Child", publicThread: false, createdBy: creatorId, parentChatId: parentId,
  }).returning()
  if (!child) throw new Error("Subthread not created")
  return child
}

const sortIds = (...ids: number[]) => ids.sort((a, b) => a - b)

describe("materialized chat access", () => {
  setupTestLifecycle()

  test("the verifier backfills from the projection and then has nothing to repair", async () => {
    const { space, users: [alice, bob] } = await testUtils.createSpaceWithMembers("Backfill", ["backfill-a@example.com", "backfill-b@example.com"])
    const publicThread = await testUtils.createChat(space.id, "Public", "thread", true)
    const dm = await testUtils.createPrivateChat(alice, bob)
    if (!publicThread || !dm) throw new Error("Fixtures not created")

    const first = await verifyChatAccess()
    expect(first.backfill).toBe(true)
    expect(first.missing).toBe(first.rows)
    expect(await accessUserIds(publicThread.id)).toEqual(sortIds(alice.id, bob.id))
    expect(await accessUserIds(dm.id)).toEqual(sortIds(alice.id, bob.id))
    await expectInSync()
  })

  test("participant add and remove resync the thread and the subthreads that inherit from it", async () => {
    const creator = await testUtils.createUser("sync-participant-creator@example.com")
    const target = await testUtils.createUser("sync-participant-target@example.com")
    const chat = await homeThread(creator.id, "Home")
    const child = await subthread(chat.id, creator.id)
    await verifyChatAccess()
    const context = testUtils.functionContext({ userId: creator.id })

    await addChatParticipant({ chatId: chat.id, userId: target.id }, context)
    expect(await accessUserIds(chat.id)).toEqual(sortIds(creator.id, target.id))
    expect(await accessUserIds(child.id)).toEqual(sortIds(creator.id, target.id))
    await expectInSync()

    await removeChatParticipant({ chatId: chat.id, userId: target.id }, context)
    expect(await accessUserIds(chat.id)).toEqual([creator.id])
    expect(await accessUserIds(child.id)).toEqual([creator.id])
    await expectInSync()
  })

  test("Space creation, member add and member removal keep the Space's chats in sync", async () => {
    const owner = await testUtils.createUser("sync-space-owner@example.com")
    const target = await testUtils.createUser("sync-space-target@example.com")
    const created = await createSpace({ name: "Sync Space" }, { currentUserId: owner.id, currentSessionId: 1, ip: undefined })
    await expectInSync()
    const [mainChat] = await db.select().from(schema.chats).where(eq(schema.chats.spaceId, created.space.id))
    if (!mainChat) throw new Error("Main chat not created")
    expect(await accessUserIds(mainChat.id)).toEqual([owner.id])

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await addSpaceMember({
        spaceId: created.space.id,
        actorUserId: owner.id,
        target: { kind: "userId", userId: target.id },
        admission: "manageMembers",
      })
      expect(await accessUserIds(mainChat.id)).toEqual(sortIds(owner.id, target.id))
      await expectInSync()

      await deleteMemberHandler(
        { spaceId: BigInt(created.space.id), userId: BigInt(target.id), blockJoin: false },
        { userId: owner.id, sessionId: 1, connectionId: "sync-remove", sendRaw: () => {}, sendRpcReply: () => {} },
      )
      expect(await accessUserIds(mainChat.id)).toEqual([owner.id])
      await expectInSync()
    } finally {
      push.mockRestore()
    }
  })

  test("moving a thread into a Space resyncs it", async () => {
    const space = await testUtils.createSpace("Move Target")
    if (!space) throw new Error("Space not created")
    const creator = await testUtils.createUser("sync-move-creator@example.com")
    const participant = await testUtils.createUser("sync-move-participant@example.com")
    // Moving requires every participant to be a member of the target Space.
    await db.insert(schema.members).values([
      { userId: creator.id, spaceId: space.id, role: "member" },
      { userId: participant.id, spaceId: space.id, role: "member" },
    ])
    const chat = await homeThread(creator.id, "Movable")
    await testUtils.addParticipant(chat.id, participant.id)
    const child = await subthread(chat.id, creator.id)
    await verifyChatAccess()

    await moveThread({ chatId: chat.id, spaceId: space.id }, testUtils.functionContext({ userId: creator.id }))
    expect(await accessUserIds(chat.id)).toEqual(sortIds(creator.id, participant.id))
    expect(await accessUserIds(child.id)).toEqual(sortIds(creator.id, participant.id))
    await expectInSync()
  })

  test("deleting a chat removes its rows", async () => {
    const owner = await testUtils.createUser("sync-delete-owner@example.com")
    const parent = await homeThread(owner.id, "Parent")
    await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "anchor" })
    const [child] = await db.insert(schema.chats).values({
      type: "thread", title: "Child", publicThread: false, createdBy: owner.id, parentChatId: parent.id, parentMessageId: 1,
    }).returning()
    if (!child) throw new Error("Child not created")
    await verifyChatAccess()
    expect(await accessUserIds(child.id)).toEqual([owner.id])

    const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
    try {
      await deleteChat({ peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(child.id) } } } }, testUtils.functionContext({ userId: owner.id }))
    } finally {
      push.mockRestore()
    }
    expect(await accessUserIds(child.id)).toEqual([])
    await expectInSync()
  })

  test("a sync registered before later writes in the transaction still sees them", async () => {
    const creator = await testUtils.createUser("sync-order-creator@example.com")
    const target = await testUtils.createUser("sync-order-target@example.com")
    const chat = await homeThread(creator.id, "Ordered")
    await verifyChatAccess()

    await db.transaction(async (tx) => {
      await syncChatAccess(tx, { kind: "chats", chatIds: [chat.id] })
      await tx.insert(schema.chatParticipants).values({ chatId: chat.id, userId: target.id })
    })
    expect(await accessUserIds(chat.id)).toEqual(sortIds(creator.id, target.id))
    await expectInSync()
  })

  test("a failed sync keeps the change and leaves the repair to the verifier", async () => {
    const creator = await testUtils.createUser("sync-failure-creator@example.com")
    const target = await testUtils.createUser("sync-failure-target@example.com")
    const chat = await homeThread(creator.id, "Failing")
    await verifyChatAccess()

    // The recompute refuses snapshot isolation, which would read stale access inputs.
    await db.transaction(async (tx) => {
      await tx.insert(schema.chatParticipants).values({ chatId: chat.id, userId: target.id })
      await syncChatAccess(tx, { kind: "chats", chatIds: [chat.id] })
    }, { isolationLevel: "repeatable read" })
    const [participant] = await db.select().from(schema.chatParticipants)
      .where(and(eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, target.id)))
    expect(participant).toBeDefined()

    const drift = await verifyChatAccess({ repair: false })
    expect(drift.missing).toBe(1)
    expect(drift.backfill).toBe(false)
    await verifyChatAccess()
    await expectInSync()
  })

  test("deleted users lose every row and orphaned rows are removed", async () => {
    const { users: [alice, bob] } = await testUtils.createSpaceWithMembers("Orphans", ["orphan-a@example.com", "orphan-b@example.com"])
    const dm = await testUtils.createPrivateChat(alice, bob)
    if (!dm) throw new Error("DM not created")
    await verifyChatAccess()

    await db.transaction(async (tx) => {
      await tx.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, bob.id))
      await syncChatAccess(tx, { kind: "deletedUsers", userIds: [bob.id] })
    })
    expect(await accessUserIds(dm.id)).toEqual([alice.id])
    await expectInSync()

    await db.insert(schema.chatAccess).values({ chatId: dm.id + 1_000_000, userId: alice.id })
    const orphaned = await verifyChatAccess()
    expect(orphaned.orphans).toBe(1)
    await expectInSync()
  })
})
