import { expect, spyOn, test } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { createChat } from "@in/server/functions/messages.createChat"
import { createSubthread } from "@in/server/functions/messages.createSubthread"
import { reserveChatIds } from "@in/server/functions/messages.reserveChatIds"
import { deleteChat } from "@in/server/functions/messages.deleteChat"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { setDialogFollowModeForUsers } from "@in/server/modules/dialogFollow"
import { setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import { lockChatAndAncestors } from "@in/server/modules/authorization/chatAccessProjection"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"

setupTestLifecycle()

async function reserve(userId: number): Promise<bigint> {
  const result = await reserveChatIds({ count: 1 }, testUtils.functionContext({ userId }))
  const reservation = result.reservations[0]
  if (!reservation) throw new Error("Reservation missing")
  return reservation.chatId
}

async function chatUpdates(chatId: bigint) {
  return db
    .select()
    .from(schema.updates)
    .where(and(eq(schema.updates.bucket, schema.UpdateBucket.Chat), eq(schema.updates.entityId, Number(chatId))))
}

test("an explicitly empty private participant list creates a sole-owner task chat", async () => {
  const owner = await testUtils.createUser("create-sole-owner@example.test")
  const request = { title: "Scout's task", participants: [] }
  const result = await createChat(request, testUtils.functionContext({ userId: owner.id }))
  const participants = await db.select().from(schema.chatParticipants)
    .where(eq(schema.chatParticipants.chatId, Number(result.chat.id)))
  expect(participants.map((participant) => participant.userId)).toEqual([owner.id])
  expect(request.participants).toEqual([])
  expect(result.chat.title).toBe("Scout's task")
  expect(result.dialog.open).toBe(true)
})

test("a lost create reply reconciles the original intent after a rename and reservation expiry", async () => {
  const owner = await testUtils.createUser("create-replay-owner@example.test")
  const invited = await testUtils.createUser("create-replay-invited@example.test")
  const space = await testUtils.createSpace()
  if (!space) throw new Error("Space missing")
  await db
    .insert(schema.members)
    .values({ spaceId: space.id, userId: owner.id, role: "member", canAccessPublicChats: true })
  const reservedChatId = await reserve(owner.id)
  const request = { reservedChatId, spaceId: BigInt(space.id), title: "Starter title", isPublic: true }
  const context = testUtils.functionContext({ userId: owner.id })
  const first = await createChat(request, context)
  const updatesBefore = await chatUpdates(reservedChatId)
  await db
    .update(schema.chats)
    .set({ title: "Human renamed title", isUntitled: false })
    .where(eq(schema.chats.id, Number(reservedChatId)))
  await db
    .update(schema.chatIdReservations)
    .set({ expiresAt: new Date(0) })
    .where(eq(schema.chatIdReservations.chatId, Number(reservedChatId)))
  const retried = await createChat(request, context)
  expect(retried.chat.id).toBe(first.chat.id)
  expect(retried.chat.title).toBe("Human renamed title")
  expect(await chatUpdates(reservedChatId)).toHaveLength(updatesBefore.length)
  // Reusing the consumed ID with a new purpose is not a rename/add operation.
  await expect(createChat({ ...request, title: "Another intent" }, context)).rejects.toMatchObject({
    code: RealtimeRpcError.Code.BAD_REQUEST,
  })
  await expect(
    createChat({ reservedChatId, participants: [{ userId: BigInt(invited.id) }] }, context),
  ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
})

test("concurrent retries create one destination, one membership set and one chat update", async () => {
  const owner = await testUtils.createUser("create-concurrent-owner@example.test")
  const invited = await testUtils.createUser("create-concurrent-invited@example.test")
  const reservedChatId = await reserve(owner.id)
  const request = {
    reservedChatId,
    participants: [{ userId: BigInt(invited.id) }],
    placeholderTitle: "Work in progress",
  }
  const context = testUtils.functionContext({ userId: owner.id })
  const replies = await Promise.all([createChat(request, context), createChat(request, context)])
  expect(replies.map((reply) => reply.chat.id)).toEqual([reservedChatId, reservedChatId])
  expect(request.participants).toEqual([{ userId: BigInt(invited.id) }])
  expect(
    await db
      .select()
      .from(schema.chats)
      .where(eq(schema.chats.id, Number(reservedChatId))),
  ).toHaveLength(1)
  expect(
    await db
      .select()
      .from(schema.chatParticipants)
      .where(eq(schema.chatParticipants.chatId, Number(reservedChatId))),
  ).toHaveLength(2)
  expect(await chatUpdates(reservedChatId)).toHaveLength(1)
})

test("new reserved creates can fill the connection pool without borrowing nested connections", async () => {
  const owner = await testUtils.createUser("create-pool-owner@example.test")
  const context = testUtils.functionContext({ userId: owner.id })
  const { reservations } = await reserveChatIds({ count: 10 }, context)
  const results = await Promise.all(reservations.map((reservation, index) => createChat({
    reservedChatId: reservation.chatId,
    participants: [],
    title: `Concurrent task ${index}`,
  }, context)))
  expect(results.map(({ chat }) => chat.id)).toEqual(reservations.map(({ chatId }) => chatId))
  const claims = await db.select().from(schema.chatIdReservations).where(eq(schema.chatIdReservations.userId, owner.id))
  expect(claims.filter((claim) => claim.claimedAt !== null)).toHaveLength(10)
})

for (const operation of ["follow", "open"] as const) {
  test(`child creation permits a missing parent dialog to ${operation} while its user owner is locked`, async () => {
    const owner = await testUtils.createUser(`create-owner-${operation}-fk@example.test`)
    const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
    if (!parent) throw new Error("Parent missing")
    await testUtils.addParticipant(parent.id, owner.id)
    const acquired = deferred<number>()
    const resumeDialog = deferred<void>()
    const originalTransaction = db.transaction.bind(db)
    // Insert a scheduling barrier around a real dialog transaction. Both
    // operations retain their actual owner locks, writes and FK constraints.
    const transaction = spyOn(db, "transaction").mockImplementationOnce((callback, config) => originalTransaction(async (tx) => {
      await tx.select().from(schema.users).where(eq(schema.users.id, owner.id)).for("no key update")
      const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
      acquired.resolve(Number(pid!["pid"]))
      await resumeDialog.promise
      return callback(tx)
    }, config))
    const dialogMutation = (operation === "follow"
      ? setDialogFollowModeForUsers({ chat: parent, userIds: [owner.id], followMode: "following", pushRealtime: false })
      : setDialogOpenForUsers({ chat: parent, userIds: [owner.id], open: true }))
      .then((value) => ({ value }), (error: unknown) => ({ error }))
    const ownerPid = await acquired.promise
    const creation = createSubthread({ parentChatId: BigInt(parent.id), title: "New task" }, testUtils.functionContext({ userId: owner.id }))
      .then((value) => ({ value }), (error: unknown) => ({ error }))
    try {
      await waitForBlockedCreate(ownerPid)
      resumeDialog.resolve()
      const [dialogResult, createResult] = await Promise.all([dialogMutation, creation])
      if ("error" in dialogResult) throw dialogResult.error
      if ("error" in createResult) throw createResult.error
      expect(createResult.value.chat.parentChatId).toBe(BigInt(parent.id))
      const [dialog] = await db.select().from(schema.dialogs)
        .where(and(eq(schema.dialogs.chatId, parent.id), eq(schema.dialogs.userId, owner.id)))
      expect(operation === "follow" ? dialog?.followMode : dialog?.open).toBe(operation === "follow" ? "following" : true)
    } finally {
      resumeDialog.resolve()
      transaction.mockRestore()
      await Promise.all([dialogMutation, creation])
    }
  })
}

for (const deleteFirst of [false, true]) {
  test(`parent deletion and child creation serialize when ${deleteFirst ? "deletion" : "creation"} owns the parent first`, async () => {
    const owner = await testUtils.createUser(`structural-race-owner-${deleteFirst}@example.test`)
    const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
    if (!parent) throw new Error("Parent missing")
    await testUtils.addParticipant(parent.id, owner.id)
    const context = testUtils.functionContext({ userId: owner.id })
    const acquired = deferred<number>()
    const resumeFirst = deferred<void>()
    const originalTransaction = db.transaction.bind(db)
    const transaction = spyOn(db, "transaction").mockImplementationOnce((callback, config) => originalTransaction(async (tx) => {
      await lockChatAndAncestors(tx, parent.id, "no key update")
      const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
      acquired.resolve(Number(pid!["pid"]))
      await resumeFirst.promise
      return callback(tx)
    }, config))
    const remove = () => deleteChat({ peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(parent.id) } } } }, context)
    const create = () => createSubthread({ parentChatId: BigInt(parent.id), title: "Child" }, context)
    const first = (deleteFirst ? remove() : create()).then((value) => ({ value }), (error: unknown) => ({ error }))
    const firstPid = await acquired.promise
    const second = (deleteFirst ? create() : remove()).then((value) => ({ value }), (error: unknown) => ({ error }))
    try {
      await waitForBlockedCreate(firstPid)
      resumeFirst.resolve()
      const [firstResult, secondResult] = await Promise.all([first, second])
      if ("error" in firstResult) throw firstResult.error
      expect("error" in secondResult ? secondResult.error : undefined).toMatchObject(deleteFirst
        ? { code: RealtimeRpcError.Code.CHAT_ID_INVALID }
        : { code: RealtimeRpcError.Code.BAD_REQUEST, message: "Delete child chats before deleting their parent" })
      expect(await db.select().from(schema.chats).where(eq(schema.chats.id, parent.id))).toHaveLength(deleteFirst ? 0 : 1)
      expect(await db.select().from(schema.chats).where(eq(schema.chats.parentChatId, parent.id))).toHaveLength(deleteFirst ? 0 : 1)
    } finally {
      resumeFirst.resolve()
      transaction.mockRestore()
      await Promise.all([first, second])
    }
  })
}

test("competing intents cannot both consume a reserved destination", async () => {
  const owner = await testUtils.createUser("create-collision-owner@example.test")
  const invited = await testUtils.createUser("create-collision-invited@example.test")
  const reservedChatId = await reserve(owner.id)
  const context = testUtils.functionContext({ userId: owner.id })
  const outcomes = await Promise.allSettled([
    createChat({ reservedChatId, participants: [{ userId: BigInt(invited.id) }], title: "First" }, context),
    createChat({ reservedChatId, participants: [{ userId: BigInt(invited.id) }], title: "Second" }, context),
  ])
  expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(1)
  const failed = outcomes.find((outcome) => outcome.status === "rejected")
  expect(failed?.status === "rejected" ? failed.reason : undefined).toMatchObject({
    code: RealtimeRpcError.Code.BAD_REQUEST,
  })
  expect(await chatUpdates(reservedChatId)).toHaveLength(1)
})

test("a consumed reservation cannot recreate a deleted chat or return it to a different actor", async () => {
  const owner = await testUtils.createUser("create-deleted-owner@example.test")
  const invited = await testUtils.createUser("create-deleted-invited@example.test")
  const reservedChatId = await reserve(owner.id)
  const request = { reservedChatId, participants: [{ userId: BigInt(invited.id) }], title: "Disposable" }
  const context = testUtils.functionContext({ userId: owner.id })
  await createChat(request, context)
  await expect(createChat(request, testUtils.functionContext({ userId: invited.id }))).rejects.toMatchObject({
    code: RealtimeRpcError.Code.BAD_REQUEST,
  })
  await deleteChat({ peer: { type: { oneofKind: "chat", chat: { chatId: reservedChatId } } } }, context)
  await expect(createChat(request, context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.CHAT_ID_INVALID })
  expect(
    await db
      .select()
      .from(schema.chats)
      .where(eq(schema.chats.id, Number(reservedChatId))),
  ).toHaveLength(0)
})

test("an unanchored subthread uses and replays its reserved destination without reconfiguration", async () => {
  const owner = await testUtils.createUser("subthread-replay-owner@example.test")
  const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
  if (!parent) throw new Error("Parent missing")
  await testUtils.addParticipant(parent.id, owner.id)
  const reservedChatId = await reserve(owner.id)
  const request = { parentChatId: BigInt(parent.id), reservedChatId, title: "New discussion" }
  const context = testUtils.functionContext({ userId: owner.id })
  const replies = await Promise.all([createSubthread(request, context), createSubthread(request, context)])
  expect(replies.map((reply) => reply.chat.id)).toEqual([reservedChatId, reservedChatId])
  await db
    .update(schema.chats)
    .set({ title: "Human's chosen title", isUntitled: false })
    .where(eq(schema.chats.id, Number(reservedChatId)))
  expect((await createSubthread(request, context)).chat.title).toBe("Human's chosen title")
  await expect(createSubthread({ ...request, title: "Changed intent" }, context)).rejects.toMatchObject({
    code: RealtimeRpcError.Code.BAD_REQUEST,
  })
  await expect(
    createChat({ reservedChatId, title: "New discussion", participants: [{ userId: BigInt(owner.id) }] }, context),
  ).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
})

test("an occupied anchor resolves the reservation to its existing child without adding participants", async () => {
  const owner = await testUtils.createUser("anchor-replay-owner@example.test")
  const invited = await testUtils.createUser("anchor-replay-invited@example.test")
  const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
  if (!parent) throw new Error("Parent missing")
  await testUtils.addParticipant(parent.id, owner.id)
  await db.insert(schema.messages).values({ chatId: parent.id, fromId: owner.id, messageId: 1, text: "Anchor" })
  const [existing] = await db
    .insert(schema.chats)
    .values({
      type: "thread",
      createdBy: owner.id,
      publicThread: false,
      title: "Keep me",
      parentChatId: parent.id,
      parentMessageId: 1,
    })
    .returning()
  if (!existing) throw new Error("Child missing")
  const reservedChatId = await reserve(owner.id)
  const result = await createSubthread(
    {
      parentChatId: BigInt(parent.id),
      parentMessageId: 1n,
      reservedChatId,
      title: "Do not rename",
      participants: [{ userId: BigInt(invited.id) }],
    },
    testUtils.functionContext({ userId: owner.id }),
  )
  expect(result.chat.id).toBe(BigInt(existing.id))
  expect(result.chat.id).not.toBe(reservedChatId)
  expect(result.chat.title).toBe("Keep me")
  const [reservation] = await db
    .select()
    .from(schema.chatIdReservations)
    .where(eq(schema.chatIdReservations.chatId, Number(reservedChatId)))
  expect(reservation?.claimedAt).not.toBeNull()
  expect(reservation?.resolvedChatId).toBe(existing.id)
  expect(
    await db.select().from(schema.chatParticipants).where(eq(schema.chatParticipants.chatId, existing.id)),
  ).toHaveLength(0)
})

test("a reserved anchor reuse cannot recreate its resolved child after deletion", async () => {
  const owner = await testUtils.createUser("reuse-deleted-owner@example.test")
  const actor = await testUtils.createUser("reuse-deleted-actor@example.test")
  const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
  if (!parent) throw new Error("Parent missing")
  await testUtils.addParticipant(parent.id, owner.id)
  await testUtils.addParticipant(parent.id, actor.id)
  await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "Anchor" })
  const created = await createSubthread(
    { parentChatId: BigInt(parent.id), parentMessageId: 1n, title: "Existing discussion" },
    testUtils.functionContext({ userId: owner.id }),
  )
  const reservedChatId = await reserve(actor.id)
  const request = { parentChatId: BigInt(parent.id), parentMessageId: 1n, reservedChatId }
  const context = testUtils.functionContext({ userId: actor.id })
  expect((await createSubthread(request, context)).chat.id).toBe(created.chat.id)
  expect((await createSubthread(request, context)).chat.id).toBe(created.chat.id)
  await deleteChat({ peer: { type: { oneofKind: "chat", chat: { chatId: created.chat.id } } } }, testUtils.functionContext({ userId: owner.id }))
  await expect(createSubthread(request, context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.CHAT_ID_INVALID })
  expect(await db.select().from(schema.chats).where(eq(schema.chats.id, Number(reservedChatId)))).toHaveLength(0)
  expect(await db.select().from(schema.chats).where(eq(schema.chats.parentChatId, parent.id))).toHaveLength(0)
})

test("claimed create replay does not revalidate deleted participants or the retired bot preset", async () => {
  const owner = await testUtils.createUser("replay-retired-owner@example.test")
  const bot = await testUtils.createUser("replay-retired-bot@example.test")
  await db.update(schema.users).set({ bot: true, botCreatorId: owner.id }).where(eq(schema.users.id, bot.id))
  const reservedChatId = await reserve(owner.id)
  const request = {
    title: "Persistent task", reservedChatId, participants: [{ userId: BigInt(bot.id) }],
    agentContext: { botUserId: BigInt(bot.id) },
  }
  const context = testUtils.functionContext({ userId: owner.id })
  const created = await createChat(request, context)
  await db.update(schema.users).set({ deleted: true, bot: false }).where(eq(schema.users.id, bot.id))
  const replay = await createChat(request, context)
  expect(replay.chat.id).toBe(created.chat.id)
  expect(replay.chat.agentContext).toEqual(created.chat.agentContext)
  expect(replay.chat.title).toBe(created.chat.title)
  await expect(createChat({ ...request, reservedChatId: undefined }, context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.USER_ID_INVALID })
})

test("claimed subthread replay survives retired creation inputs and an erased anchor", async () => {
  const owner = await testUtils.createUser("subthread-retired-owner@example.test")
  const bot = await testUtils.createUser("subthread-retired-bot@example.test")
  await db.update(schema.users).set({ bot: true, botCreatorId: owner.id }).where(eq(schema.users.id, bot.id))
  const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
  if (!parent) throw new Error("Parent missing")
  await testUtils.addParticipant(parent.id, owner.id)
  await db.insert(schema.messages).values({ chatId: parent.id, messageId: 1, fromId: owner.id, text: "Anchor" })
  const reservedChatId = await reserve(owner.id)
  const request = {
    parentChatId: BigInt(parent.id), parentMessageId: 1n, reservedChatId,
    participants: [{ userId: BigInt(bot.id) }], agentContext: { botUserId: BigInt(bot.id) },
  }
  const context = testUtils.functionContext({ userId: owner.id })
  const created = await createSubthread(request, context)
  await db.update(schema.users).set({ deleted: true, bot: false }).where(eq(schema.users.id, bot.id))
  // An anchor deletion may unlink its durable child; the original reservation
  // still resolves the same accessible destination rather than running create.
  await deleteMessage({ peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(parent.id) } } }, messageIds: [1n] }, context)
  const replay = await createSubthread(request, context)
  expect(replay.chat.id).toBe(created.chat.id)
  expect(replay.chat.agentContext).toEqual(created.chat.agentContext)
  expect(replay.chat.title).toBe(created.chat.title)
  await expect(createSubthread({ ...request, reservedChatId: undefined }, context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.MESSAGE_ID_INVALID })
})

test("a parent grant removed before the create authority lock cannot create or reuse a child", async () => {
  for (const reuse of [false, true]) {
    const owner = await testUtils.createUser(`authority-${reuse}-owner@example.test`)
    const actor = await testUtils.createUser(`authority-${reuse}-actor@example.test`)
    const parent = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
    if (!parent) throw new Error("Parent missing")
    await testUtils.addParticipant(parent.id, owner.id)
    await testUtils.addParticipant(parent.id, actor.id)
    await db.insert(schema.messages).values({ chatId: parent.id, fromId: owner.id, messageId: 1, text: "Anchor" })
    if (reuse) await createSubthread({ parentChatId: BigInt(parent.id), parentMessageId: 1n }, testUtils.functionContext({ userId: owner.id }))
    const existingCount = (await db.select().from(schema.chats).where(eq(schema.chats.parentChatId, parent.id))).length
    const release = deferred<void>()
    const acquired = deferred<number>()
    const blocker = db.transaction(async (tx) => {
      await tx.select().from(schema.chats).where(eq(schema.chats.id, parent.id)).for("update")
      const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
      acquired.resolve(Number(pid!["pid"]))
      await release.promise
      await tx.delete(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, parent.id), eq(schema.chatParticipants.userId, actor.id)))
    })
    const blockerPid = await acquired.promise
    const creation = createSubthread({ parentChatId: BigInt(parent.id), parentMessageId: 1n }, testUtils.functionContext({ userId: actor.id }))
      .then((value) => ({ value }), (error: unknown) => ({ error }))
    try {
      await waitForBlockedCreate(blockerPid)
      release.resolve()
      await blocker
      const outcome = await creation
      expect("error" in outcome ? outcome.error : undefined).toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
      expect(await db.select().from(schema.chats).where(eq(schema.chats.parentChatId, parent.id))).toHaveLength(existingCount)
      expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, actor.id))).toHaveLength(0)
    } finally {
      release.resolve()
      await blocker
      await creation
    }
  }
})

test("an inherited root grant removed before the authority lock cannot create below its child", async () => {
  const owner = await testUtils.createUser("authority-root-owner@example.test")
  const actor = await testUtils.createUser("authority-root-actor@example.test")
  const root = await testUtils.createChat(null, "Root", "thread", false, owner.id)
  if (!root) throw new Error("Root missing")
  await testUtils.addParticipant(root.id, owner.id)
  await testUtils.addParticipant(root.id, actor.id)
  const parent = await createSubthread({ parentChatId: BigInt(root.id), title: "Parent" }, testUtils.functionContext({ userId: owner.id }))
  const release = deferred<void>()
  const acquired = deferred<number>()
  const blocker = db.transaction(async (tx) => {
    await tx.select().from(schema.chats).where(eq(schema.chats.id, root.id)).for("update")
    const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
    acquired.resolve(Number(pid!["pid"]))
    await release.promise
    await tx.delete(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, root.id), eq(schema.chatParticipants.userId, actor.id)))
  })
  const blockerPid = await acquired.promise
  const creation = createSubthread({ parentChatId: parent.chat.id, title: "Denied grandchild" }, testUtils.functionContext({ userId: actor.id }))
    .then((value) => ({ value }), (error: unknown) => ({ error }))
  try {
    await waitForBlockedCreate(blockerPid)
    release.resolve()
    await blocker
    const outcome = await creation
    expect("error" in outcome ? outcome.error : undefined).toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
    expect(await db.select().from(schema.chats).where(eq(schema.chats.parentChatId, Number(parent.chat.id)))).toHaveLength(0)
  } finally {
    release.resolve()
    await blocker
    await creation
  }
})

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}

async function waitForBlockedCreate(blockerPid: number) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const [row] = await db.execute(sql<{ waiting: boolean }>`
      select exists(select 1 from pg_stat_activity where datname = current_database()
        and ${blockerPid} = any(pg_blocking_pids(pid))) as waiting
    `)
    if (row?.["waiting"]) return
    await Bun.sleep(5)
  }
  throw new Error("Create did not wait for the held authority lock")
}
