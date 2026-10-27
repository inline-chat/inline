import { expect, spyOn, test } from "bun:test"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { registerPreCommitTask } from "@in/server/db/commitHooks"
import { handler as getDialogs } from "@in/server/methods/getDialogs"
import { Log } from "@in/server/utils/log"
import { syncChatAccess } from "./chatAccessSync"
import { reportVerification, verifyChatAccess } from "./chatAccessVerifier"

setupTestLifecycle()

test("rolled back savepoints must discard their pre-commit tasks", async () => {
  const events: string[] = []
  await db.transaction(async (tx) => {
    try {
      await tx.transaction(async (nested) => {
        registerPreCommitTask(nested, "regression-rolled-back", {
          run: async () => { events.push("rolled-back-task") },
        })
        throw new Error("rollback nested")
      })
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "rollback nested") throw error
    }
  })
  expect(events).toEqual([])
})

test("rolled back user deletion must preserve that user's chat access", async () => {
  const alice = await testUtils.createUser("regression-alice@example.test")
  const bob = await testUtils.createUser("regression-bob@example.test")
  const chat = await testUtils.createPrivateChat(alice, bob)
  if (!chat) throw new Error("missing chat")
  await verifyChatAccess()

  await db.transaction(async (tx) => {
    try {
      await tx.transaction(async (nested) => {
        await nested.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, bob.id))
        await syncChatAccess(nested, { kind: "deletedUsers", userIds: [bob.id] })
        throw new Error("rollback deletion")
      })
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "rollback deletion") throw error
    }
  })
  const [user] = await db.select().from(schema.users).where(eq(schema.users.id, bob.id))
  expect(user?.deleted).not.toBe(true)
  const result = await verifyChatAccess({ repair: false })
  expect(result.missing).toBe(0)
})

test("major drift after the backfill must be reported as an error", async () => {
  const alice = await testUtils.createUser("regression-drift-a@example.test")
  const bob = await testUtils.createUser("regression-drift-b@example.test")
  await testUtils.createPrivateChat(alice, bob)
  await verifyChatAccess()
  await db.delete(schema.chatAccess)
  // Fresh drift right after the backfill is a rollout warning, not an error.
  const duringGrace = await verifyChatAccess({ repair: false })
  expect(duringGrace.rolloutGrace).toBe(true)
  await db.update(schema.chatAccessState).set({ backfilledAt: new Date(Date.now() - 60 * 60_000) })
  const result = await verifyChatAccess()
  const info = spyOn(Log.prototype, "info").mockImplementation(() => {})
  const warn = spyOn(Log.prototype, "warn").mockImplementation(() => {})
  const error = spyOn(Log.prototype, "error").mockImplementation(() => {})
  try {
    reportVerification(duringGrace)
    expect(warn).toHaveBeenCalledTimes(1)
    expect(error).toHaveBeenCalledTimes(0)
    reportVerification(result)
    expect(error).toHaveBeenCalledTimes(1)
  } finally {
    info.mockRestore()
    warn.mockRestore()
    error.mockRestore()
  }
})

test("getDialogs must sync the private chats it creates for Space members", async () => {
  const { space, users: [alice] } = await testUtils.createSpaceWithMembers("Regression Dialogs", ["regression-dialogs-a@example.test", "regression-dialogs-b@example.test"])
  await verifyChatAccess()
  const response = await getDialogs({ spaceId: space.id }, { currentUserId: alice.id, currentSessionId: 1, ip: undefined })
  expect(response.chats.length).toBeGreaterThan(0)
  const result = await verifyChatAccess({ repair: false })
  expect(result.missing).toBe(0)
})

test("a verifier batch of 500 public chats with 77 members must backfill successfully", async () => {
  const [space] = await db.insert(schema.spaces).values({ name: "Regression large batch" }).returning()
  if (!space) throw new Error("missing space")
  const users = await db.insert(schema.users).values(Array.from({ length: 77 }, (_, index) => ({ email: `regression-large-${index}@example.test` }))).returning()
  await db.insert(schema.members).values(users.map((user) => ({ spaceId: space.id, userId: user.id, role: "member" as const })))
  await db.insert(schema.chats).values(Array.from({ length: 500 }, () => ({ spaceId: space.id, type: "thread" as const, publicThread: true })))
  let failedCode: string | undefined
  try {
    await verifyChatAccess()
  } catch (error) {
    let current: unknown = error
    failedCode = "unknown"
    for (let index = 0; index < 5 && current && typeof current === "object"; index++) {
      if ("code" in current && typeof current.code === "string") {
        failedCode = current.code
        break
      }
      current = "cause" in current ? current.cause : undefined
    }
  }
  expect(failedCode).toBeUndefined()
})

test("control: concurrent group changes and chat grants converge under the access lock", async () => {
  const { space, users: [owner, alice, bob] } = await testUtils.createSpaceWithMembers("Regression concurrency", ["regression-concurrent-owner@example.test", "regression-concurrent-a@example.test", "regression-concurrent-b@example.test"])
  const chat = await testUtils.createChat(space.id, "private", "thread", false, owner.id)
  if (!chat) throw new Error("missing chat")
  await testUtils.addParticipant(chat.id, owner.id)
  const [group] = await db.insert(schema.userGroups).values({ spaceId: space.id, name: "Regression group", createdBy: owner.id }).returning()
  if (!group) throw new Error("missing group")
  await db.insert(schema.userGroupMembers).values({ groupId: group.id, userId: alice.id })
  await verifyChatAccess()
  let ready = 0
  let release!: () => void
  const barrier = new Promise<void>((resolve) => { release = resolve })
  const awaitBoth = async () => {
    ready++
    if (ready === 2) release()
    await barrier
  }
  const settled = await Promise.allSettled([
    db.transaction(async (tx) => {
      await tx.insert(schema.chatParticipantGroups).values({ chatId: chat.id, groupId: group.id })
      await syncChatAccess(tx, { kind: "chats", chatIds: [chat.id] })
      await awaitBoth()
    }),
    db.transaction(async (tx) => {
      await tx.delete(schema.userGroupMembers).where(eq(schema.userGroupMembers.groupId, group.id))
      await tx.insert(schema.userGroupMembers).values({ groupId: group.id, userId: bob.id })
      await syncChatAccess(tx, { kind: "groups", groupIds: [group.id] })
      await awaitBoth()
    }),
  ])
  for (const result of settled) expect(result.status).toBe("fulfilled")
  const result = await verifyChatAccess({ repair: false })
  expect({ missing: result.missing, extra: result.extra }).toEqual({ missing: 0, extra: 0 })
  const access = await db.select().from(schema.chatAccess).where(eq(schema.chatAccess.chatId, chat.id))
  expect(access.map((pair) => pair.userId).sort((a,b) => a-b)).toEqual([owner.id, bob.id].sort((a,b) => a-b))
})
