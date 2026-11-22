import { describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { canMessageBot } from "@in/server/modules/agents/access"
import { deleteAgentGrant, setAgentGrant } from "@in/server/modules/agents/grants"
import { AgentGrantOperation } from "@inline-chat/protocol/core"
import { and, eq, isNull, sql } from "drizzle-orm"
import { runPendingDataTasks } from "../automatic"
import { applyDataTaskItem, planDataTask, planViolation, revertDataTask } from "../runner"
import task from "./2026-11-21-close-grandfathered-bots"

async function person(name: string) {
  return testUtils.createUser(`${name}@example.test`)
}

async function bot(name: string, owner: schema.DbUser, settings: { open: boolean; updatedBy?: number } = { open: true }) {
  const [user] = await db
    .insert(schema.users)
    .values({ firstName: name, username: `${name}_bot`, bot: true, botCreatorId: owner.id, pendingSetup: false })
    .returning()
  // As migration 0173 left it: open, updated by nobody.
  await db.insert(schema.agentSettings).values({ botUserId: user!.id, openToEveryone: settings.open, updatedBy: settings.updatedBy ?? null })
  return user!
}

let messageIds = 0
async function say(chatId: number, from: schema.DbUser, date = new Date()) {
  await db.insert(schema.messages).values({ chatId, fromId: from.id, messageId: ++messageIds, date })
}

async function dm(botUser: schema.DbUser, from: schema.DbUser, date?: Date) {
  const chat = await testUtils.createPrivateChat(botUser, from)
  await say(chat!.id, from, date)
}

const settingsOf = async (botUser: schema.DbUser) =>
  (await db.select().from(schema.agentSettings).where(eq(schema.agentSettings.botUserId, botUser.id)))[0]!

const activeGrants = (botUser: schema.DbUser) =>
  db.select().from(schema.agentGrants).where(and(eq(schema.agentGrants.botUserId, botUser.id), sql`${schema.agentGrants.revokedAt} is null`))

const userUpdates = async (userId: number) =>
  (await db.select({ n: sql<number>`count(*)::int` }).from(schema.updates)
    .where(and(eq(schema.updates.bucket, UpdateBucket.User), eq(schema.updates.entityId, userId))))[0]!.n

describe("2026-11-21-close-grandfathered-bots", () => {
  setupTestLifecycle()

  test("leaves every bot others used open, and closes the rest without cutting anyone off", async () => {
    const owner = await person("owner")
    const teammate = await person("teammate")
    const outsider = await person("outsider")
    const stranger = await person("stranger")
    const space = (await testUtils.createSpace("Team"))!
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: teammate.id, role: "member" },
    ])

    const unused = await bot("unused", owner)
    const usedByTeammate = await bot("teammate_dm", owner)
    await dm(usedByTeammate, teammate)
    const oldOutsider = await bot("old_outsider", owner)
    await dm(oldOutsider, outsider, new Date("2026-05-01T00:00:00Z"))
    const inThread = await bot("in_thread", owner)
    const thread = (await testUtils.createChat(space.id, "Standup", "thread", false, owner.id))!
    await say(thread.id, inThread)
    await say(thread.id, teammate)
    const inSpace = await bot("in_space", owner)
    await db.insert(schema.members).values({ spaceId: space.id, userId: inSpace.id, role: "member" })
    // In a thread with the teammate, who never wrote there.
    const participant = await bot("participant", owner)
    const quiet = (await testUtils.createChat(space.id, "Quiet", "thread", false, owner.id))!
    await testUtils.addParticipant(quiet.id, participant.id)
    await testUtils.addParticipant(quiet.id, teammate.id)
    const ownerChose = await bot("owner_chose", owner, { open: true, updatedBy: owner.id })

    const plan = await planDataTask(task)
    const tierOf = Object.fromEntries(plan.items.map((item) => [item.key, item.tier]))
    expect(tierOf).toEqual({
      [`bot:${unused.id}`]: "close",
      [`bot:${usedByTeammate.id}`]: "keep-open",
      [`bot:${oldOutsider.id}`]: "keep-open",
      [`bot:${inThread.id}`]: "keep-open",
      [`bot:${inSpace.id}`]: "share-and-close",
      [`bot:${participant.id}`]: "share-and-close",
    })
    const planOf = (botUser: schema.DbUser) => plan.items.find((item) => item.key === `bot:${botUser.id}`)!.plan
    expect(planOf(inSpace)).toMatchObject({ userIds: [], spaceIds: [space.id], usedByOthers: 0 })
    expect(planOf(participant)).toMatchObject({ userIds: [teammate.id], spaceIds: [], usedByOthers: 0 })
    expect(planOf(usedByTeammate)).toMatchObject({ usedByOthers: 1 })

    expect(planViolation(task, plan)).toBeUndefined()
    const ownerUpdatesBefore = await userUpdates(owner.id)
    const [report] = await runPendingDataTasks({ tasks: [task], sleep: async () => {} })
    expect(report).toEqual({ taskId: task.id, status: "completed", applied: 3, skipped: 0 })

    // Bots anyone else used are exactly as they were.
    for (const kept of [usedByTeammate, oldOutsider, inThread]) {
      expect(await settingsOf(kept)).toMatchObject({ openToEveryone: true, updatedBy: null })
      expect(await activeGrants(kept)).toHaveLength(0)
      expect(await canMessageBot(kept, stranger.id)).toBe(true)
    }
    expect(await settingsOf(ownerChose)).toMatchObject({ openToEveryone: true, updatedBy: owner.id })

    for (const closed of [unused, inSpace, participant]) {
      expect(await settingsOf(closed)).toMatchObject({ openToEveryone: false, updatedBy: null })
      expect(await canMessageBot(closed, stranger.id)).toBe(false)
    }
    expect((await activeGrants(inSpace)).map((grant) => grant.subjectSpaceId)).toEqual([space.id])
    expect((await activeGrants(participant))[0]).toMatchObject({ subjectUserId: teammate.id, operations: 6, grantedBy: null })
    expect(await activeGrants(unused)).toHaveLength(0)
    // Nobody who shared a chat with a closed bot loses it.
    expect(await canMessageBot(inSpace, teammate.id)).toBe(true)
    expect(await canMessageBot(participant, teammate.id)).toBe(true)
    // Owners hear about every change, like an owner's own edit.
    expect(await userUpdates(owner.id)).toBeGreaterThan(ownerUpdatesBefore)
    expect(await userUpdates(teammate.id)).toBeGreaterThan(0)

    // Completed once, like a migration.
    expect((await runPendingDataTasks({ tasks: [task], sleep: async () => {} }))[0]?.status).toBe("already-completed")
  })

  test("blocks a plan past its reviewed limits", () => {
    const item = (key: number, tier: string, userIds: number[], usedByOthers = 0) => ({
      key: `bot:${key}`, tier, noop: tier === "keep-open", plan: { botUserId: key, ownerUserId: 1, userIds, spaceIds: [], usedByOthers },
    })
    const plan = (items: ReturnType<typeof item>[]) => {
      const tiers: Record<string, number> = {}
      for (const entry of items) tiers[entry.tier] = (tiers[entry.tier] ?? 0) + 1
      return { taskId: task.id, hash: "h", items, tiers }
    }
    expect(planViolation(task, plan([item(1, "share-and-close", [2]), item(2, "keep-open", [3, 4], 2)]))).toBeUndefined()
    expect(planViolation(task, plan([item(1, "share-and-close", Array.from({ length: 11 }, (_, index) => index + 10))])))
      .toBe("11 person grants exceed 10")
    expect(planViolation(task, plan([item(1, "share-and-close", [])]))).toBe("bot:1 shares with nobody")
    expect(planViolation(task, plan([item(1, "close", [], 1)]))).toBe("bot:1 is used by others but would close")
    expect(planViolation(task, plan([item(1, "keep-open", [], 0)]))).toBe("bot:1 is kept open without being used by others")
    expect(planViolation(task, plan(Array.from({ length: 21 }, (_, index) => item(index + 1, "keep-open", [], 1)))))
      .toBe('21 "keep-open" items exceed the limit of 20')
  })

  test("skips a bot someone used or its owner changed after the plan, and reverts the rest", async () => {
    const owner = await person("owner2")
    const teammate = await person("teammate2")
    const space = (await testUtils.createSpace("Team 2"))!
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: teammate.id, role: "member" },
    ])
    const a = await bot("a", owner)
    await db.insert(schema.members).values({ spaceId: space.id, userId: a.id, role: "member" })
    const b = await bot("b", owner)
    const late = await bot("late", owner)
    const plan = await planDataTask(task)
    const itemOf = (botUser: schema.DbUser) => plan.items.find((item) => item.key === `bot:${botUser.id}`)!

    // After the plan: the owner closes b themselves, and the teammate writes to late.
    await db.update(schema.agentSettings).set({ openToEveryone: false, updatedBy: owner.id }).where(eq(schema.agentSettings.botUserId, b.id))
    await dm(late, teammate)
    expect(await applyDataTaskItem(task, itemOf(b), plan.hash)).toEqual({ kind: "skipped", reason: "settings changed since the plan" })
    expect(await applyDataTaskItem(task, itemOf(late), plan.hash)).toEqual({ kind: "skipped", reason: "used by others since the plan" })
    expect(await settingsOf(late)).toMatchObject({ openToEveryone: true, updatedBy: null })
    expect(await applyDataTaskItem(task, itemOf(a), plan.hash)).toEqual({ kind: "applied" })
    expect(await activeGrants(a)).toHaveLength(1)

    // The owner reopens a after the task; revert leaves their choice alone.
    const c = await bot("c", owner)
    await applyDataTaskItem(task, (await planDataTask(task)).items.find((item) => item.key === `bot:${c.id}`)!, "h")
    await db.update(schema.agentSettings).set({ openToEveryone: true, updatedBy: owner.id }).where(eq(schema.agentSettings.botUserId, a.id))
    const reverted = await revertDataTask(task)
    expect(reverted).toEqual({ reverted: 1, skipped: [{ key: `bot:${a.id}`, reason: "settings changed since apply" }] })
    expect(await settingsOf(c)).toMatchObject({ openToEveryone: true, updatedBy: null })
    expect(await settingsOf(a)).toMatchObject({ openToEveryone: true, updatedBy: owner.id })
    expect(await settingsOf(b)).toMatchObject({ openToEveryone: false, updatedBy: owner.id })
  })

  test("applies only the sharing it planned: a bot that left a space, a space made public or a revoked person replans", async () => {
    const owner = await person("owner3")
    const teammate = await person("teammate3")
    const team = (await testUtils.createSpace("Team 3"))!
    const lounge = (await testUtils.createSpace("Lounge 3"))!
    for (const space of [team, lounge]) {
      await db.insert(schema.members).values([
        { spaceId: space.id, userId: owner.id, role: "owner" },
        { spaceId: space.id, userId: teammate.id, role: "member" },
      ])
    }
    const left = await bot("left", owner)
    await db.insert(schema.members).values({ spaceId: team.id, userId: left.id, role: "member" })
    const publicSpace = await bot("public_space", owner)
    await db.insert(schema.members).values({ spaceId: lounge.id, userId: publicSpace.id, role: "member" })
    const revoked = await bot("revoked", owner)
    const quiet = (await testUtils.createChat(team.id, "Quiet 3", "thread", false, owner.id))!
    await testUtils.addParticipant(quiet.id, revoked.id)
    await testUtils.addParticipant(quiet.id, teammate.id)

    const plan = await planDataTask(task)
    const itemOf = (botUser: schema.DbUser) => plan.items.find((item) => item.key === `bot:${botUser.id}`)!
    expect(itemOf(left).plan).toMatchObject({ spaceIds: [team.id] })
    expect(itemOf(publicSpace).plan).toMatchObject({ spaceIds: [lounge.id] })
    expect(itemOf(revoked).plan).toMatchObject({ userIds: [teammate.id] })

    // After the plan: the bot leaves Team, Lounge goes public, and the owner shares then unshares with the teammate.
    await db.delete(schema.members).where(and(eq(schema.members.spaceId, team.id), eq(schema.members.userId, left.id)))
    await db.update(schema.spaces).set({ isPublic: true }).where(eq(schema.spaces.id, lounge.id))
    await setAgentGrant({ botUserId: BigInt(revoked.id), userId: BigInt(teammate.id), operations: [AgentGrantOperation.INVOKE] }, owner.id)
    await deleteAgentGrant({ botUserId: BigInt(revoked.id), userId: BigInt(teammate.id) }, owner.id)

    for (const stale of [left, publicSpace, revoked]) {
      expect(await applyDataTaskItem(task, itemOf(stale), plan.hash)).toEqual({ kind: "skipped", reason: "sharing changed since the plan" })
      expect(await settingsOf(stale)).toMatchObject({ openToEveryone: true, updatedBy: null })
    }
    expect(await activeGrants(left)).toHaveLength(0)
    expect(await activeGrants(publicSpace)).toHaveLength(0)

    // The next run replans from current data: each closes, and nobody gets a grant the plan no longer gives.
    const [report] = await runPendingDataTasks({ tasks: [task], sleep: async () => {} })
    expect(report).toMatchObject({ status: "completed", skipped: 0 })
    for (const replanned of [left, publicSpace, revoked]) {
      expect(await settingsOf(replanned)).toMatchObject({ openToEveryone: false, updatedBy: null })
      expect(await activeGrants(replanned)).toHaveLength(0)
    }
    expect(await canMessageBot(revoked, teammate.id)).toBe(false)
  })

  test("revert keeps a bot closed once its owner granted or revoked access since", async () => {
    const owner = await person("owner4")
    const teammate = await person("teammate4")
    const stranger = await person("stranger4")
    const space = (await testUtils.createSpace("Team 4"))!
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: teammate.id, role: "member" },
    ])
    const unshared = await bot("unshared", owner)
    await db.insert(schema.members).values({ spaceId: space.id, userId: unshared.id, role: "member" })
    const extended = await bot("extended", owner)
    const untouched = await bot("untouched", owner)
    await db.insert(schema.members).values({ spaceId: space.id, userId: untouched.id, role: "member" })
    expect((await runPendingDataTasks({ tasks: [task], sleep: async () => {} }))[0]).toMatchObject({ status: "completed", applied: 3 })

    // The owner revokes the space grant the task made, and shares another bot with someone.
    const spaceSubject = { subject: { oneofKind: "spaceId" as const, spaceId: BigInt(space.id) } }
    await deleteAgentGrant({ botUserId: BigInt(unshared.id), userId: 0n, subject: spaceSubject }, owner.id)
    await setAgentGrant({ botUserId: BigInt(extended.id), userId: BigInt(stranger.id), operations: [AgentGrantOperation.INVOKE] }, owner.id)

    const summary = await revertDataTask(task)
    expect(summary.reverted).toBe(1)
    expect(summary.skipped.sort((a, b) => a.key.localeCompare(b.key))).toEqual(
      [unshared, extended].map((botUser) => ({ key: `bot:${botUser.id}`, reason: "access list changed since apply" }))
        .sort((a, b) => a.key.localeCompare(b.key)),
    )
    expect(await settingsOf(unshared)).toMatchObject({ openToEveryone: false })
    expect(await canMessageBot(unshared, teammate.id)).toBe(false)
    expect(await settingsOf(extended)).toMatchObject({ openToEveryone: false })
    expect(await canMessageBot(extended, stranger.id)).toBe(true)
    expect(await settingsOf(untouched)).toMatchObject({ openToEveryone: true, updatedBy: null })
    const untouchedGrants = await db.select().from(schema.agentGrants)
      .where(and(eq(schema.agentGrants.botUserId, untouched.id), isNull(schema.agentGrants.revokedAt)))
    expect(untouchedGrants).toHaveLength(0)
  })
})
