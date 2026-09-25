import { expect, spyOn, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import {
  chats, chatParticipants, chatParticipantGroups, dialogs, members, messages, spaces, updates,
  UpdateBucket, userGroups, userGroupMembers, users,
} from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { postgresRepairDiscovery as discovery } from "./repairDiscovery.postgres"
import type { RepairDiscoverySnapshot } from "./repairDiscovery"
import { ConnectedUserRepair } from "./repair"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { measureOperation } from "@in/server/__tests__/performance/measure"
import { ChatModel } from "@in/server/db/models/chats"
import { createChat } from "@in/server/functions/messages.createChat"
import { pinMessage } from "@in/server/functions/messages.pinMessage"
import { loadRepairUserFrontiers } from "./repairDiscovery.postgres"

setupTestLifecycle()

const date = 1_700_000_000n
const changedAt = new Date(Number(date) * 1000)
const watermark = new Date(Number(date + 10n) * 1000)
const fixture = async () => {
  const { users: actors, space } = await testUtils.createSpaceWithMembers("Discovery", ["discovery@example.test"])
  const user = actors[0]!
  await db.update(spaces).set({ lastUpdateDate: new Date(0) }).where(eq(spaces.id, space.id))
  return { user, space }
}
const compare = async (userId: number, snapshot?: RepairDiscoverySnapshot, since = date) => {
  const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
  try {
    const expected = await getUpdatesState({ date: since }, { currentUserId: userId, currentSessionId: 0 }, {
      discoveryWatermark: watermark,
    })
    const expectedHints = structuredClone(push.mock.calls)
    push.mockClear()
    const actual = await discovery.discover({ userId, date: since }, { snapshot, shouldEmitHints: () => true })
    expect(actual).toEqual(expected)
    expect(push.mock.calls).toEqual(expectedHints)
    return { result: actual, hints: expectedHints }
  } finally { push.mockRestore() }
}
const prepare = (userId: number, since = date) => discovery.prepare([{ userId, date: since }], watermark)

const homeFixture = async () => {
  const creator = await testUtils.createUser("home-creator@example.test")
  const participant = await testUtils.createUser("home-participant@example.test")
  const outsider = await testUtils.createUser("home-outsider@example.test")
  const { chat } = await createChat({
    title: "Home recovery", participants: [{ userId: BigInt(participant.id) }],
  }, testUtils.functionContext({ userId: creator.id }))
  const chatId = Number(chat.id)
  expect(await db.query.dialogs.findMany({ where: { chatId } })).toMatchObject([{ userId: creator.id }])
  return { creator, participant, outsider, chatId }
}

test("the authoritative catalog includes Home participants without requiring a dialog", async () => {
  const { creator, participant, outsider, chatId } = await homeFixture()
  await db.update(chats).set({ lastUpdateDate: changedAt }).where(eq(chats.id, chatId))
  for (const user of [creator, participant]) {
    const catalog = await ChatModel.getUserChats({ userId: user.id })
    expect(catalog.chats.map(chat => chat.id)).toEqual([chatId])
    const snapshots = await prepare(user.id)
    expect(snapshots.get(user.id)?.resourcesUnchangedSince).toBeUndefined()
    const { result, hints } = await compare(user.id, snapshots.get(user.id))
    expect(result.updatesFound).toBe(true)
    expect(hints.flatMap(([, values]) => values).map(value => value.update)).toMatchObject([{
      oneofKind: "chatHasNewUpdates", chatHasNewUpdates: { chatId: BigInt(chatId) },
    }])
    expect((await ChatModel.getUserChats({ userId: user.id, where: {
      lastUpdateAtGreaterThanEqual: new Date(changedAt.getTime() + 1),
    } })).chats).toEqual([])
  }

  // Even a stale outsider dialog may nominate a candidate, but cannot grant access.
  await db.insert(dialogs).values({ userId: outsider.id, chatId })
  expect((await ChatModel.getUserChats({ userId: outsider.id })).chats).toEqual([])
  const outsiderSnapshot = (await prepare(outsider.id)).get(outsider.id)
  expect(outsiderSnapshot?.resourcesUnchangedSince).toBeUndefined()
  const outsiderDiscovery = await compare(outsider.id, outsiderSnapshot)
  expect(outsiderDiscovery.result.updatesFound).toBe(false)
  expect(outsiderDiscovery.hints).toEqual([])
})

test("a lost Home unpin hint is repaired before the scheduler advances either participant's checkpoint", async () => {
  // Drop the real mutation's live delivery. Recovery must use the durable chat
  // bucket; no internal event is sent to this scheduler.
  const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
  let repair: ConnectedUserRepair | undefined
  try {
    const { creator, participant, chatId } = await homeFixture()
    const userIds = [creator.id, participant.id]
    await db.insert(messages).values({ chatId, fromId: creator.id, messageId: 1, pinnedAt: changedAt })
    await UserBucketUpdates.enqueue({ userId: creator.id, update: {
      oneofKind: "userDialogArchived",
      userDialogArchived: { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } }, archived: false },
    } })
    const frontiers = await loadRepairUserFrontiers(userIds)
    expect([...frontiers.values()].every(seq => seq > 0)).toBe(true)
    await db.update(chats).set({ lastUpdateDate: new Date(Number(date - 10n) * 1000) }).where(eq(chats.id, chatId))

    let sweepWatermark = watermark
    const scans: { userId: number; requestedDate: bigint; result: Awaited<ReturnType<typeof discovery.discover>>;
      hints: Parameters<typeof RealtimeUpdates.pushToUser>[1] }[] = []
    const userHints: number[] = []
    const replay: number[] = []
    repair = new ConnectedUserRepair({
      discovery: {
        ...discovery,
        captureWatermark: async () => sweepWatermark,
        async discover(request, options) {
          const result = await discovery.discover(request, options)
          // Capture before returning the result that advances the scheduler's
          // checkpoint. A later empty sweep must not hide a first-sweep miss.
          scans.push({ userId: request.userId, requestedDate: request.date, result,
            hints: structuredClone(push.mock.calls.filter(([id]) => id === request.userId).flatMap(([, values]) => values)) })
          return result
        },
      },
      connectedUserIds: () => userIds, hasConnections: () => true, getConnectionEpoch: () => 1,
      emitUserHint: async (id) => { userHints.push(id); return 1 },
      replayCurrentUserUpdate: async (id) => { replay.push(id); return "replayed" },
      closeForUnrecoverableFrontier: () => { throw new Error("Unexpected disconnect") },
      deliverTargetedBucketHint: async () => { throw new Error("Unexpected broker event") },
    })
    await repair.start()
    push.mockClear()
    repair.observeConnectedUsers()
    await repair.waitForIdle()
    expect(userHints.toSorted()).toEqual(userIds.toSorted())
    expect(replay.toSorted()).toEqual(userIds.toSorted())
    expect(scans).toHaveLength(2)
    expect(scans.every(scan => scan.result.updatesFound === false)).toBe(true)

    const mutation = await pinMessage({
      peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } }, messageId: 1n, unpin: true,
    }, testUtils.functionContext({ userId: creator.id }))
    const unpinSeq = mutation.updates[0]!.seq!
    expect((await db.query.messages.findFirst({ where: { chatId, messageId: 1 } }))?.pinnedAt).toBeNull()
    expect(await loadRepairUserFrontiers(userIds)).toEqual(frontiers)
    const changed = await db.query.chats.findFirst({ where: { id: chatId } })
    sweepWatermark = new Date(changed!.lastUpdateDate!.getTime() + 2_000)
    const recoveryDate = BigInt(Math.floor(sweepWatermark.getTime() / 1000))
    push.mockClear()
    scans.length = 0
    repair.observeConnectedUsers()
    await repair.waitForIdle()
    expect(scans).toHaveLength(2)
    for (const scan of scans) {
      expect(scan.requestedDate).toBe(date + 10n)
      expect(scan.result).toEqual({ date: recoveryDate, seq: frontiers.get(scan.userId), updatesFound: true })
      expect(scan.hints.map(hint => hint.update)).toMatchObject([{
        oneofKind: "chatHasNewUpdates", chatHasNewUpdates: { chatId: BigInt(chatId), updateSeq: unpinSeq },
      }])
    }

    push.mockClear()
    scans.length = 0
    sweepWatermark = new Date(sweepWatermark.getTime() + 10_000)
    repair.observeConnectedUsers()
    await repair.waitForIdle()
    expect(scans).toHaveLength(2)
    expect(scans.every(scan => scan.requestedDate === recoveryDate && scan.result.updatesFound === false)).toBe(true)
    expect(push).not.toHaveBeenCalled()
    expect(userHints.toSorted()).toEqual(userIds.toSorted())
    expect(replay.toSorted()).toEqual(userIds.toSorted())
  } finally {
    await repair?.stop()
    push.mockRestore()
  }
})

for (const kind of ["dm-min", "dm-max", "public", "private", "group", "linked", "space"] as const) {
  test(`batched discovery preserves ${kind} hints at the inclusive checkpoint`, async () => {
    let { user, space } = await fixture()
    let chatId: number | undefined
    if (kind === "space") {
      await db.update(spaces).set({ lastUpdateDate: changedAt, updateSeq: 7 }).where(eq(spaces.id, space.id))
    } else if (kind.startsWith("dm")) {
      let other = await testUtils.createUser("other@example.test")
      if ((kind === "dm-min" && user.id > other.id) || (kind === "dm-max" && user.id < other.id)) {
        [user, other] = [other, user]
      }
      const [chat] = await db.insert(chats).values({
        type: "private", minUserId: kind === "dm-min" ? user.id : other.id,
        maxUserId: kind === "dm-min" ? other.id : user.id, lastUpdateDate: changedAt, updateSeq: 7,
      }).returning()
      chatId = chat!.id
    } else {
      const [root] = await db.insert(chats).values({
        type: "thread", spaceId: space.id, publicThread: kind === "public" || kind === "linked",
        title: "Root", isUntitled: false, lastUpdateDate: kind === "linked" ? new Date(0) : changedAt, updateSeq: 7,
      }).returning()
      chatId = root!.id
      if (kind === "private") await db.insert(chatParticipants).values({ chatId, userId: user.id })
      if (kind === "group") {
        const [group] = await db.insert(userGroups).values({ spaceId: space.id, createdBy: user.id, name: "Group" }).returning()
        await db.insert(userGroupMembers).values({ groupId: group!.id, userId: user.id })
        await db.insert(chatParticipantGroups).values({ groupId: group!.id, chatId })
      }
      if (kind === "linked") {
        const [child] = await db.insert(chats).values({
          type: "thread", spaceId: space.id, parentChatId: chatId, publicThread: false,
          lastUpdateDate: changedAt, updateSeq: 7,
        }).returning()
        chatId = child!.id
        await db.insert(dialogs).values({ userId: user.id, chatId, spaceId: space.id })
      }
    }
    // A retained sequence ahead of the cached counter must still win.
    await db.insert(updates).values({
      bucket: kind === "space" ? UpdateBucket.Space : UpdateBucket.Chat,
      entityId: chatId ?? space.id, seq: 11, payload: Buffer.alloc(0),
    })
    const snapshots = await prepare(user.id)
    expect(snapshots.get(user.id)?.resourcesUnchangedSince).toBeUndefined()
    const { result, hints } = await compare(user.id, snapshots.get(user.id))
    expect(result.updatesFound).toBe(true)
    expect(hints.flatMap(([, values]) => values)).toHaveLength(1)
  })
}

test("idle discovery performs no per-account SQL and still returns the durable user frontier", async () => {
  const { user } = await fixture()
  const persisted = await UserBucketUpdates.enqueue({ userId: user.id, update: {
    oneofKind: "userDialogArchived",
    userDialogArchived: { peerId: { type: { oneofKind: "chat", chat: { chatId: 7n } } }, archived: true },
  } })
  // Simulate a legacy cached counter lagging retained durable history.
  await db.update(users).set({ updateSeq: 0 }).where(eq(users.id, user.id))
  const snapshots = await prepare(user.id)
  expect(snapshots.get(user.id)?.resourcesUnchangedSince).toBe(date)
  const sample = await measureOperation(db.$client.options, async () => {
    expect(await discovery.discover({ userId: user.id, date }, {
      snapshot: snapshots.get(user.id), shouldEmitHints: () => true,
    })).toEqual({ date: date + 10n, seq: persisted.seq, updatesFound: false })
  }, async () => {})
  expect(sample.sql.commands).toBe(0)
  await compare(user.id, snapshots.get(user.id))
})

test("the scheduler repairs a lost user-only hint without a broker event or repeat replay", async () => {
  const { user } = await fixture()
  await db.update(users).set({ updateSeq: 11 }).where(eq(users.id, user.id))
  const hints: number[] = []
  const replay: number[] = []
  const repair = new ConnectedUserRepair({
    discovery, connectedUserIds: () => [user.id], hasConnections: () => true, getConnectionEpoch: () => 1,
    emitUserHint: async (_id, seq) => { hints.push(seq); return 1 },
    replayCurrentUserUpdate: async (_id, seq) => { replay.push(seq); return "replayed" },
    closeForUnrecoverableFrontier: () => { throw new Error("Unexpected disconnect") },
    deliverTargetedBucketHint: async () => {},
  })
  try {
    await repair.start()
    for (let i = 0; i < 2; i++) {
      repair.observeConnectedUsers()
      await repair.waitForIdle()
    }
    expect(hints).toEqual([11])
    expect(replay).toEqual([11])
    await db.update(users).set({ updateSeq: 12 }).where(eq(users.id, user.id))
    repair.observeConnectedUsers()
    await repair.waitForIdle()
    expect(hints).toEqual([11, 12])
  } finally { await repair.stop() }
})

test("conservative candidates cannot grant private access or revive a deleted space", async () => {
  const { user, space } = await fixture()
  await db.insert(chats).values({ type: "thread", spaceId: space.id, publicThread: false, lastUpdateDate: changedAt })
  const first = await prepare(user.id)
  expect(first.get(user.id)?.resourcesUnchangedSince).toBeUndefined()
  expect((await compare(user.id, first.get(user.id))).hints).toHaveLength(0)
  await db.update(spaces).set({ deleted: new Date(), lastUpdateDate: changedAt }).where(eq(spaces.id, space.id))
  const deleted = await prepare(user.id)
  expect((await compare(user.id, deleted.get(user.id))).hints).toHaveLength(0)
})

test("membership removed after preparation is rechecked before delivering changed resources", async () => {
  const { user, space } = await fixture()
  await db.insert(chats).values({ type: "thread", spaceId: space.id, publicThread: true, lastUpdateDate: changedAt })
  const snapshots = await prepare(user.id)
  await db.delete(members).where(eq(members.userId, user.id))
  expect((await compare(user.id, snapshots.get(user.id))).hints).toHaveLength(0)
})

test("a mutation after a negative snapshot is found on the next inclusive sweep", async () => {
  const { user, space } = await fixture()
  const first = await prepare(user.id)
  await db.insert(chats).values({ type: "thread", spaceId: space.id, publicThread: true, lastUpdateDate: watermark })
  const quiet = await discovery.discover({ userId: user.id, date }, { snapshot: first.get(user.id), shouldEmitHints: () => true })
  expect(quiet.updatesFound).toBe(false)
  const nextWatermark = new Date(watermark.getTime() + 1_000)
  const next = await discovery.prepare([{ userId: user.id, date: quiet.date! }], nextWatermark)
  expect(next.get(user.id)?.resourcesUnchangedSince).toBeUndefined()
  const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
  try {
    const repaired = await discovery.discover({ userId: user.id, date: quiet.date! }, { snapshot: next.get(user.id), shouldEmitHints: () => true })
    expect(repaired.updatesFound).toBe(true)
    expect(push).toHaveBeenCalledTimes(1)
  } finally { push.mockRestore() }
})

test("duplicates use the oldest requested checkpoint, without mixing different users' dates", async () => {
  const { user, space } = await fixture()
  const other = await testUtils.createUser("different-checkpoint@example.test")
  await db.insert(members).values({ userId: other.id, spaceId: space.id })
  await db.insert(chats).values({ type: "thread", spaceId: space.id, publicThread: true, lastUpdateDate: changedAt })
  const results = await discovery.prepare([
    { userId: user.id, date: date + 1n }, { userId: user.id, date }, { userId: other.id, date: date + 1n },
  ], watermark)
  expect(results.size).toBe(2)
  expect(results.get(user.id)?.resourcesUnchangedSince).toBeUndefined()
  expect(results.get(other.id)?.resourcesUnchangedSince).toBe(date + 1n)
})

test("a negative result cannot skip an older request or a missing user frontier", async () => {
  const { user, space } = await fixture()
  await db.insert(chats).values({ type: "thread", spaceId: space.id, publicThread: true, lastUpdateDate: changedAt })
  const later = (await prepare(user.id, date + 1n)).get(user.id)!
  expect(later.resourcesUnchangedSince).toBe(date + 1n)
  expect((await compare(user.id, later)).result.updatesFound).toBe(true)
  const missing = { watermark, resourcesUnchangedSince: date }
  expect((await compare(user.id, missing)).result.updatesFound).toBe(true)
})

test("a stale watermark cannot supply its sequence or regress a newer checkpoint", async () => {
  const { user, space } = await fixture()
  await db.insert(chats).values({ type: "thread", spaceId: space.id, publicThread: true, lastUpdateDate: changedAt })
  const push = spyOn(RealtimeUpdates, "pushToUser").mockResolvedValue(undefined)
  try {
    const result = await discovery.discover({ userId: user.id, date }, {
      snapshot: { watermark: new Date(Number(date - 1n) * 1000), userFrontier: 777, resourcesUnchangedSince: date - 1n },
      shouldEmitHints: () => true,
    })
    expect(result.date).toBeGreaterThanOrEqual(date)
    expect(result.seq).toBe(0)
    expect(result.updatesFound).toBe(true)
    expect(push).toHaveBeenCalledTimes(1)
  } finally { push.mockRestore() }
})

test("empty batches do no SQL and malformed requests fail closed", async () => {
  const sample = await measureOperation(db.$client.options, async () => {
    expect((await discovery.prepare([], watermark)).size).toBe(0)
    await expect(discovery.prepare([{ userId: 1, date: -1n }], watermark)).rejects.toThrow()
    await expect(discovery.prepare([{ userId: NaN, date }], watermark)).rejects.toThrow()
    await expect(discovery.prepare([], new Date(NaN))).rejects.toThrow()
  }, async () => {})
  expect(sample.sql.commands).toBe(0)
})
