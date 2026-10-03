import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { addChatParticipant } from "@in/server/functions/messages.addChatParticipant"
import { removeChatParticipant } from "@in/server/functions/messages.removeChatParticipant"
import { updateDialogOpen } from "@in/server/functions/messages.updateDialogOpen"
import { handler as updateDialog } from "@in/server/methods/updateDialog"
import { updateChatVisibility } from "@in/server/functions/messages.updateChatVisibility"
import { moveThread } from "@in/server/functions/messages.moveThread"
import { addSpaceMember } from "@in/server/functions/space.addMember.shared"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { createUserGroup } from "@in/server/modules/userGroups"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { InlineError } from "@in/server/types/errors"
import { setupTestLifecycle, testUtils } from "../setup"

const inputPeer = (chatId: number) => ({ type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } })
type DialogAction = "reopen" | "pin"
const mutateDialog = (action: DialogAction, chatId: number, userId: number) => action === "reopen"
  ? updateDialogOpen({ peerId: inputPeer(chatId), open: true }, testUtils.functionContext({ userId }))
  : updateDialog({ peerThreadId: String(chatId), pinned: true }, { currentUserId: userId, currentSessionId: 0, ip: "127.0.0.1" })
const denied = (action: DialogAction) => action === "reopen"
  ? { code: RealtimeRpcError.Code.PEER_ID_INVALID }
  : { type: InlineError.ApiError.PEER_INVALID[0] }

describe("participant and workbench mutation lock order", () => {
  setupTestLifecycle()

  for (const grouped of [false, true]) {
    for (const adding of [false, true]) {
      for (const childDialog of adding ? [true] : [false, true]) {
        for (const action of ["reopen", "pin"] as const) {
          for (const dialogWins of [false, true]) {
            test(`actual ${grouped ? "group" : "individual"} ${adding ? "add" : "remove"} and ${action} on ${childDialog ? "a child" : "the root"}: ${dialogWins ? "dialog owns first" : "membership owns first"}`, async () => {
              const { space, users: [owner, actor] } = await testUtils.createSpaceWithMembers("Workbench membership", [
                `membership-owner-${grouped}-${adding}-${childDialog}-${action}-${dialogWins}@example.test`,
                `membership-actor-${grouped}-${adding}-${childDialog}-${action}-${dialogWins}@example.test`,
              ])
              await db.update(schema.members).set({ role: "owner" }).where(and(
                eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id),
              ))
              const root = await testUtils.createChat(space.id, "Private root", "thread", false, owner.id)
              const child = childDialog ? await testUtils.createChat(space.id, "Child task", "thread", false, owner.id) : undefined
              if (!root || (childDialog && !child)) throw new Error("Workbench participant chats missing")
              await testUtils.addParticipant(root.id, owner.id)
              if (child) await db.update(schema.chats).set({ parentChatId: root.id }).where(eq(schema.chats.id, child.id))
              const group = grouped ? await createUserGroup({ spaceId: space.id, name: "Editors", userIds: [actor.id] }, testUtils.functionContext({ userId: owner.id })) : undefined
              if (adding || !group) {
                await testUtils.addParticipant(root.id, actor.id)
              } else {
                await db.insert(schema.chatParticipantGroups).values({ chatId: root.id, groupId: Number(group.group.id) })
              }
              const dialogChat = child ?? root
              const grantChat = adding ? dialogChat : root
              await db.insert(schema.dialogs).values({ chatId: dialogChat.id, userId: actor.id, open: false, pinned: false })
              const participant = group ? { groupId: Number(group.group.id) } : { userId: actor.id }
              const input = { chatId: grantChat.id, ...participant }
              await raceOwnedMutations({
                userId: actor.id,
                dialogWins,
                authority: () => adding
                  ? addChatParticipant(input, testUtils.functionContext({ userId: owner.id }))
                  : removeChatParticipant(input, testUtils.functionContext({ userId: owner.id })),
                dialog: () => mutateDialog(action, dialogChat.id, actor.id),
                expectedDialogError: !adding && !dialogWins ? denied(action) : undefined,
              })
              const grants = group
                ? await db.select().from(schema.chatParticipantGroups).where(and(eq(schema.chatParticipantGroups.chatId, grantChat.id), eq(schema.chatParticipantGroups.groupId, Number(group.group.id))))
                : await db.select().from(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, grantChat.id), eq(schema.chatParticipants.userId, actor.id)))
              expect(grants).toHaveLength(adding ? 1 : 0)
              const [dialog] = await db.select().from(schema.dialogs).where(and(eq(schema.dialogs.chatId, dialogChat.id), eq(schema.dialogs.userId, actor.id)))
              expect(dialog?.open).toBe(adding || dialogWins)
              expect(dialog?.pinned).toBe(action === "pin" && (adding || dialogWins))
              if (!adding) {
                await expect(mutateDialog(action, dialogChat.id, actor.id)).rejects.toMatchObject(denied(action))
                expect(group
                  ? await db.select().from(schema.chatParticipantGroups).where(eq(schema.chatParticipantGroups.chatId, root.id))
                  : await db.select().from(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, root.id), eq(schema.chatParticipants.userId, actor.id))))
                  .toHaveLength(0)
              }
            })
          }
        }
      }
    }
  }

  for (const action of ["reopen", "pin"] as const) {
    for (const dialogWins of [false, true]) {
      test(`actual visibility revocation and ${action}: ${dialogWins ? "dialog owns first" : "visibility owns first"}`, async () => {
        const { space, users: [owner, actor] } = await testUtils.createSpaceWithMembers("Workbench visibility", [
          `visibility-owner-${action}-${dialogWins}@example.test`, `visibility-actor-${action}-${dialogWins}@example.test`,
        ])
        await db.update(schema.members).set({ role: "owner" }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id)))
        const chat = await testUtils.createChat(space.id, "Public task", "thread", true, owner.id)
        if (!chat) throw new Error("Visibility race chat missing")
        await db.insert(schema.dialogs).values({ chatId: chat.id, userId: actor.id, open: false, pinned: false })
        await raceOwnedMutations({
          userId: actor.id, dialogWins,
          authority: () => updateChatVisibility({ chatId: chat.id, isPublic: false, participants: [owner.id] }, testUtils.functionContext({ userId: owner.id })),
          dialog: () => mutateDialog(action, chat.id, actor.id),
          expectedDialogError: dialogWins ? undefined : denied(action),
        })
        expect(await db.select().from(schema.dialogs).where(and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, actor.id)))).toHaveLength(0)
        await expect(mutateDialog(action, chat.id, actor.id)).rejects.toMatchObject(denied(action))
        expect(await db.select().from(schema.dialogs).where(and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, actor.id)))).toHaveLength(0)
      })

      if (dialogWins) test(`actual move to home lets owner-first ${action} finish before the creator number and key update`, async () => {
        const { space, users: [owner] } = await testUtils.createSpaceWithMembers("Workbench move", [`move-owner-${action}@example.test`])
        const chat = await testUtils.createChat(space.id, "Moving task", "thread", false, owner.id)
        if (!chat) throw new Error("Move race chat missing")
        await testUtils.addParticipant(chat.id, owner.id)
        await db.insert(schema.dialogs).values({ chatId: chat.id, userId: owner.id, spaceId: space.id, open: false, pinned: false })
        await raceOwnedMutations({
          userId: owner.id, dialogWins: true,
          authority: () => moveThread({ chatId: chat.id, spaceId: null }, testUtils.functionContext({ userId: owner.id })),
          dialog: () => mutateDialog(action, chat.id, owner.id),
        })
        const [saved] = await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))
        const [dialog] = await db.select().from(schema.dialogs).where(and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, owner.id)))
        expect(saved?.spaceId).toBeNull()
        expect(saved?.threadNumber).toBe(1)
        expect(dialog?.spaceId).toBeNull()
        expect(dialog?.open).toBe(true)
        expect(dialog?.pinned).toBe(action === "pin")
      })
    }
  }

  for (const grouped of [false, true]) {
    test(`actual ${grouped ? "group" : "individual"} add and remove remain mutually serialized`, async () => {
      const { space, users: [owner, actor] } = await testUtils.createSpaceWithMembers("Workbench membership mutex", [
        `mutex-owner-${grouped}@example.test`, `mutex-actor-${grouped}@example.test`,
      ])
      await db.update(schema.members).set({ role: "owner" }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id)))
      const chat = await testUtils.createChat(space.id, "Private task", "thread", false, owner.id)
      if (!chat) throw new Error("Membership mutex chat missing")
      await testUtils.addParticipant(chat.id, owner.id)
      const group = grouped ? await createUserGroup({ spaceId: space.id, name: "Mutex group", userIds: [actor.id] }, testUtils.functionContext({ userId: owner.id })) : undefined
      const input = { chatId: chat.id, ...(group ? { groupId: Number(group.group.id) } : { userId: actor.id }) }
      await raceOwnedMutations({
        userId: actor.id, dialogWins: false,
        authority: () => addChatParticipant(input, testUtils.functionContext({ userId: owner.id })),
        dialog: () => removeChatParticipant(input, testUtils.functionContext({ userId: owner.id })),
      })
      expect(group
        ? await db.select().from(schema.chatParticipantGroups).where(eq(schema.chatParticipantGroups.chatId, chat.id))
        : await db.select().from(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, actor.id))))
        .toHaveLength(0)
    })
  }

  test("a new Space member outside visibility's owned recipient set rolls back with a typed retry result", async () => {
    const { space, users: [owner, actor] } = await testUtils.createSpaceWithMembers("Visibility recipient change", [
      "recipient-change-owner@example.test", "recipient-change-actor@example.test",
    ])
    const late = await testUtils.createUser("recipient-change-late@example.test")
    await db.update(schema.members).set({ role: "owner" }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id)))
    await db.update(schema.members).set({ canAccessPublicChats: false }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, actor.id)))
    const chat = await testUtils.createChat(space.id, "Private task", "thread", false, owner.id)
    if (!chat) throw new Error("Visibility recipient fixture missing")
    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, actor.id)
    await db.insert(schema.dialogs).values({ chatId: chat.id, userId: actor.id, open: false, pinned: true })
    const acquired = deferred<void>()
    const resume = deferred<void>()
    const originalInsert = UpdatesModel.insertUpdate.bind(UpdatesModel)
    const insert = spyOn(UpdatesModel, "insertUpdate").mockImplementation(async (tx, input) => {
      if (input.bucket === schema.UpdateBucket.Chat && input.entity.id === chat.id && input.update.oneofKind === "chatVisibility") {
        acquired.resolve()
        await resume.promise
      }
      return originalInsert(tx, input)
    })
    const originalTransaction = db.transaction.bind(db)
    const transaction = spyOn(db, "transaction").mockImplementation((callback, config) => originalTransaction(async (tx) => {
      await tx.execute(sql`set local lock_timeout = '3s'`)
      await tx.execute(sql`set local statement_timeout = '5s'`)
      return callback(tx)
    }, config))
    const visibility = updateChatVisibility({ chatId: chat.id, isPublic: true }, testUtils.functionContext({ userId: owner.id }))
      .then((value) => ({ value }), (error: unknown) => ({ error }))
    try {
      await bounded(acquired.promise)
      await bounded(addSpaceMember({ spaceId: space.id, actorUserId: owner.id, target: { kind: "userId", userId: late.id }, admission: "manageMembers" }))
      resume.resolve()
      const result = await bounded(visibility)
      expect("error" in result ? result.error : undefined).toMatchObject({
        code: RealtimeRpcError.Code.BAD_REQUEST, message: "Space membership changed; retry visibility update",
      })
      const [saved] = await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))
      const [dialog] = await db.select().from(schema.dialogs).where(and(eq(schema.dialogs.chatId, chat.id), eq(schema.dialogs.userId, actor.id)))
      expect(saved?.publicThread).toBe(false)
      expect(dialog?.pinned).toBe(true)
      expect(await db.select().from(schema.chatParticipants).where(eq(schema.chatParticipants.chatId, chat.id))).toHaveLength(2)
      expect(await db.select().from(schema.updates).where(and(eq(schema.updates.bucket, schema.UpdateBucket.Chat), eq(schema.updates.entityId, chat.id)))).toHaveLength(0)
    } finally {
      resume.resolve()
      try { await bounded(visibility) }
      finally { transaction.mockRestore(); insert.mockRestore() }
    }
    await updateChatVisibility({ chatId: chat.id, isPublic: true }, testUtils.functionContext({ userId: owner.id }))
    const [saved] = await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))
    expect(saved?.publicThread).toBe(true)
    const accessUpdates = (await db.select().from(schema.updates).where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, late.id))))
      .map((row) => UpdatesModel.decrypt(row).payload.update).filter((update) => update.oneofKind === "userAddedToChat" && update.userAddedToChat.chatId === BigInt(chat.id))
    expect(accessUpdates).toHaveLength(1)
  })
})

/** Real handlers and SQL locks; these spies only pause scheduling and observe
 * failures. Deadlocks must be absent, including deadlocks hidden by retry. */
async function raceOwnedMutations(input: {
  userId: number
  dialogWins: boolean
  authority: () => Promise<unknown>
  dialog: () => Promise<unknown>
  expectedDialogError?: object
}) {
  const acquired = deferred<number>()
  const resume = deferred<void>()
  const originalTransaction = db.transaction.bind(db)
  let firstTransaction = true
  let deadlocks = 0
  const transaction = spyOn(db, "transaction").mockImplementation((callback, config) => originalTransaction(async (tx) => {
    await tx.execute(sql`set local lock_timeout = '3s'`)
    await tx.execute(sql`set local statement_timeout = '5s'`)
    if (input.dialogWins && firstTransaction) {
      firstTransaction = false
      await tx.select().from(schema.users).where(eq(schema.users.id, input.userId)).for("no key update")
      const [pid] = await tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
      acquired.resolve(Number(pid!["pid"]))
      await resume.promise
    }
    return callback(tx)
  }, config).catch((error: unknown) => {
    let cause = error
    for (let i = 0; i < 4 && typeof cause === "object" && cause !== null; i++) {
      if ("code" in cause && cause.code === "40P01") deadlocks++
      cause = "cause" in cause ? cause.cause : undefined
    }
    throw error
  }))
  const originalEnqueue = UserBucketUpdates.enqueueMany.bind(UserBucketUpdates)
  let paused = false
  const enqueue = spyOn(UserBucketUpdates, "enqueueMany").mockImplementation(async (updates, options) => {
    const result = await originalEnqueue(updates, options)
    if (!input.dialogWins && !paused && options?.tx && updates.some((update) => update.userId === input.userId && (
      update.update.oneofKind === "userAddedToChat" || update.update.oneofKind === "userRemovedFromChat" || update.update.oneofKind === "userChatPermissions"
    ))) {
      paused = true
      const [pid] = await options.tx.execute(sql<{ pid: number }>`select pg_backend_pid() as pid`)
      acquired.resolve(Number(pid!["pid"]))
      await resume.promise
    }
    return result
  })
  const outcome = (operation: Promise<unknown>) => operation.then((value) => ({ value }), (error: unknown) => ({ error }))
  const first = outcome(input.dialogWins ? input.dialog() : input.authority())
  let second: ReturnType<typeof outcome> | undefined
  try {
    const pid = await bounded(acquired.promise)
    second = outcome(input.dialogWins ? input.authority() : input.dialog())
    for (let attempt = 0; ; attempt++) {
      const [row] = await db.execute(sql<{ blocked: boolean }>`select exists (
        select 1 from pg_stat_activity where datname = current_database() and ${pid} = any(pg_blocking_pids(pid))) as blocked`)
      if (row?.["blocked"]) break
      if (attempt >= 200) throw new Error("Actual handler did not reach the contested owner")
      await Bun.sleep(5)
    }
    resume.resolve()
    const [firstResult, secondResult] = await bounded(Promise.all([first, second]))
    if ("error" in firstResult) throw firstResult.error
    if (input.expectedDialogError) expect("error" in secondResult ? secondResult.error : undefined).toMatchObject(input.expectedDialogError)
    else if ("error" in secondResult) throw secondResult.error
    expect(deadlocks).toBe(0)
  } finally {
    resume.resolve()
    try { await bounded(Promise.all(second ? [first, second] : [first])) }
    finally { enqueue.mockRestore(); transaction.mockRestore() }
  }
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}

async function bounded<T>(operation: Promise<T>): Promise<T> {
  const result = await Promise.race([operation.then((value) => ({ value })), Bun.sleep(6_000).then(() => ({ timeout: true as const }))])
  if ("timeout" in result) throw new Error("Actual handler SQL race exceeded its deadline")
  return result.value
}
