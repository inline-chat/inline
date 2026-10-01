import { afterEach, expect, test } from "bun:test"
import { Update } from "@inline-chat/protocol/core"
import type { RecentRealtimeBucket } from "@in/server/db/schema/recentRealtimeBuckets"
import { RECENT_REALTIME_BUCKET_TTL_MS } from "@in/server/db/models/recentRealtimeBuckets"
import { RecentRealtimeRepair, updateBucket, type RecentRepairRuntime } from "./recentRepair"

const running: RecentRealtimeRepair[] = []
afterEach(async () => { await Promise.all(running.splice(0).map((repair) => repair.stop())) })

const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((ready) => { resolve = ready })
  return { promise, resolve }
}

const fixture = (enabled = true) => {
  const state = { now: 1_000, rows: [] as RecentRealtimeBucket[], epochs: new Map([[1, 1]]),
    reads: 0, cleanups: 0, reconciles: 0, replays: 0, fallbacks: 0, hints: [] as { userId: number; seq: number }[] }
  const source: RecentRepairRuntime = {
    enabled: () => enabled,
    now: () => state.now,
    connectedUsers: () => [...state.epochs.keys()],
    epoch: (userId) => state.epochs.get(userId) ?? 0,
    readPage: async ({ after, limit }) => {
      state.reads += 1
      return state.rows.filter((row) => after === undefined || row.bucket > after.bucket ||
        (row.bucket === after.bucket && row.entityId > after.entityId)).slice(0, limit)
    },
    cleanup: async () => { state.cleanups += 1; return 0 },
    hintBucket: async (event, controls) => {
      for (const userId of state.epochs.keys()) {
        if (controls.shouldDeliver?.(userId) === false) continue
        state.hints.push({ userId, seq: event.frontier })
        controls.onDelivered?.(userId, 1)
      }
    },
    hintUser: async (userId, seq, current) => {
      if (!current()) return 0
      state.hints.push({ userId, seq })
      return 1
    },
    replayUser: async () => { state.replays += 1; return "replayed" },
    fallbackUser: async () => { state.fallbacks += 1 },
    reconcile: () => { state.reconciles += 1 },
  }
  const repair = new RecentRealtimeRepair(source)
  running.push(repair)
  const row = (entityId: number, seq: number, bucket = 1): RecentRealtimeBucket => ({
    bucket, entityId, seq, expiresAt: new Date(state.now + RECENT_REALTIME_BUCKET_TTL_MS),
  })
  const message = (chatId: number, seq: number) => Update.create({
    seq, update: { oneofKind: "newMessage", newMessage: { message: {
      chatId: BigInt(chatId), id: 1n, fromId: 1n, out: false, date: 1n,
    } } },
  })
  return { state, source, repair, row, message }
}

test("default local mode creates no polling, cleanup, or publication-repair work", async () => {
  const { state, repair } = fixture(false)
  repair.start()
  repair.observeBucket({ bucket: { kind: "chat", chatId: 10 }, frontier: 1 })
  await repair.poll()
  expect(repair.diagnostics.active).toBe(false)
  expect(state.reads + state.cleanups + state.hints.length).toBe(0)
})

test("full live delivery wins the grace and suppresses a healthy bucket hint", async () => {
  const { state, repair, row, message } = fixture()
  state.rows = [row(10, 5)]
  repair.start()
  await repair.poll()
  repair.observeDelivery(1, [message(10, 5)], 1)
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toEqual([])
  expect(repair.diagnostics.pending).toBe(0)
})

test("a quiet final committed update is discovered and repaired without a broker event", async () => {
  const { state, repair, row } = fixture()
  state.rows = [row(10, 5)]
  repair.start()
  await repair.poll()
  expect(state.hints).toEqual([])
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toEqual([{ userId: 1, seq: 5 }])
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toHaveLength(1)
})

test("one recipient's live payload does not hide another recipient's loss", async () => {
  const { state, repair, row, message } = fixture()
  state.epochs.set(2, 1)
  state.rows = [row(10, 5)]
  repair.start()
  repair.observeDelivery(1, [message(10, 5)], 1)
  await repair.poll()
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toEqual([{ userId: 2, seq: 5 }])
})

test("a socket joining during repair cannot inherit the earlier socket's receipt", async () => {
  const { state, source, repair, row } = fixture()
  state.rows = [row(10, 5)]
  const entered = deferred()
  const release = deferred()
  const deliver = source.hintBucket
  source.hintBucket = async (event, controls) => {
    entered.resolve()
    await release.promise
    await deliver(event, controls)
  }
  repair.start()
  await repair.poll()
  state.now += 1_000
  const inFlight = repair.poll()
  await entered.promise
  state.epochs.set(1, 2)
  release.resolve()
  await inFlight
  expect(state.hints).toEqual([])
  source.hintBucket = deliver
  state.now += 1_000
  await repair.poll()
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toEqual([{ userId: 1, seq: 5 }])
})

test("no connected sockets skips discovery while bounded expiry cleanup continues", async () => {
  const { state, repair } = fixture()
  state.epochs.clear()
  repair.start()
  await repair.poll()
  state.now += 4_999
  await repair.poll()
  expect(state.cleanups).toBe(1)
  state.now += 1
  await repair.poll()
  expect(state.cleanups).toBe(2)
  expect(state.reads).toBe(0)
  expect(repair.diagnostics.scanCycleMs).toBe(0)
})

test("user-bucket recovery sends a typed hint and released-client replay without account discovery", async () => {
  const { state, repair, row } = fixture()
  state.rows = [row(1, 9, 2)]
  repair.start()
  await repair.poll()
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toEqual([{ userId: 1, seq: 9 }])
  expect(state.replays).toBe(1)
  expect(state.reconciles + state.fallbacks).toBe(0)
})

test("an unreplayable user frontier retains the existing bounded compatibility fallback", async () => {
  const { state, source, repair, row } = fixture()
  state.rows = [row(1, 9, 2)]
  source.replayUser = async () => "filtered_record"
  repair.start()
  await repair.poll()
  state.now += 1_000
  await repair.poll()
  expect(state.fallbacks).toBe(1)
})

test("a scan gap longer than retention triggers authoritative reconciliation", async () => {
  const { state, source, repair } = fixture()
  repair.start()
  await repair.poll()
  const read = source.readPage
  source.readPage = async () => { throw new Error("database unavailable") }
  state.now += RECENT_REALTIME_BUCKET_TTL_MS
  await repair.poll()
  source.readPage = read
  state.now += 1_000
  await repair.poll()
  expect(state.reconciles).toBeGreaterThanOrEqual(1)
})

test("legacy hints coalesce without indefinitely postponing a busy bucket", async () => {
  const { state, repair } = fixture()
  repair.start()
  repair.observeBucket({ bucket: { kind: "chat", chatId: 10 }, frontier: 1 })
  state.now += 500
  repair.observeBucket({ bucket: { kind: "chat", chatId: 10 }, frontier: 2 })
  state.now += 500
  await repair.poll()
  expect(state.hints).toEqual([{ userId: 1, seq: 2 }])
})

test("DM-only payloads require a resolved peer mapping rather than guessing a bucket", () => {
  const update = Update.create({ seq: 4, update: { oneofKind: "deleteMessages", deleteMessages: {
    messageIds: [1n], peerId: { type: { oneofKind: "user", user: { userId: 2n } } },
  } } })
  expect(updateBucket(1, update)).toBeUndefined()
  expect(updateBucket(1, update, new Map([[2, 10]]))).toEqual({ kind: "chat", chatId: 10 })
})

test("a burst is drained fairly in capped batches with at most four resource operations", async () => {
  const { state, source, repair } = fixture()
  let active = 0
  let peak = 0
  const deliver = source.hintBucket
  source.hintBucket = async (event, controls) => {
    active += 1
    peak = Math.max(peak, active)
    await Promise.resolve()
    await deliver(event, controls)
    active -= 1
  }
  repair.start()
  for (let chatId = 1; chatId <= 40; chatId += 1) {
    repair.observeBucket({ bucket: { kind: "chat", chatId }, frontier: chatId })
  }
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toHaveLength(16)
  expect(repair.diagnostics.pending).toBe(24)
  state.now += 100
  await repair.poll()
  expect(state.hints).toHaveLength(32)
  state.now += 100
  await repair.poll()
  expect(state.hints.map((hint) => hint.seq)).toEqual(Array.from({ length: 40 }, (_, index) => index + 1))
  expect(peak).toBe(4)
  expect(repair.diagnostics.pending).toBe(0)
})

test("a failed bucket retries behind unrelated work rather than starving it", async () => {
  const { state, source, repair } = fixture()
  let fail = true
  const deliver = source.hintBucket
  source.hintBucket = async (event, controls) => {
    if (event.frontier === 1 && fail) {
      fail = false
      throw new Error("one resource failed")
    }
    await deliver(event, controls)
  }
  repair.start()
  repair.observeBucket({ bucket: { kind: "chat", chatId: 1 }, frontier: 1 })
  repair.observeBucket({ bucket: { kind: "chat", chatId: 2 }, frontier: 2 })
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toEqual([{ userId: 1, seq: 2 }])
  expect(repair.diagnostics.pending).toBe(1)
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toEqual([{ userId: 1, seq: 2 }, { userId: 1, seq: 1 }])
})

test("completed keyset cycles revisit commits inserted behind their current cursor", async () => {
  const { state, repair, row } = fixture()
  state.rows = Array.from({ length: 260 }, (_, index) => row(index + 10, 1))
  repair.start()
  await repair.poll()
  state.rows.unshift(row(1, 9))
  state.now += 100
  await repair.poll()
  state.now += 100
  await repair.poll()
  expect(repair.diagnostics.pending).toBe(261)
  // The rows are discovery candidates rather than recipients. They stay
  // bounded and queued fairly while the coordinator observes its live grace.
  expect(state.reads).toBe(3)
})

test("full expiry batches continue at the fast cadence even without connected sockets", async () => {
  const { state, source, repair } = fixture()
  state.epochs.clear()
  let remaining = 600
  source.cleanup = async () => {
    state.cleanups += 1
    const deleted = Math.min(256, remaining)
    remaining -= deleted
    return deleted
  }
  repair.start()
  await repair.poll()
  state.now += 100
  await repair.poll()
  state.now += 100
  await repair.poll()
  expect(remaining).toBe(0)
  expect(repair.diagnostics.expiredRowsCleaned).toBe(600)
  expect(repair.diagnostics.fullCleanupBatches).toBe(2)
  state.now += 100
  await repair.poll()
  expect(state.cleanups).toBe(3)
  expect(state.reads).toBe(0)
})

test("a validated local DM identity suppresses later peer-only delete repair and expires", async () => {
  const { state, repair, row, message } = fixture()
  repair.start()
  const created = message(10, 1)
  if (created.update.oneofKind !== "newMessage" || !created.update.newMessage.message) throw new Error("Missing fixture message")
  created.update.newMessage.message.peerId = { type: { oneofKind: "user", user: { userId: 2n } } }
  repair.observeDelivery(1, [created], 1)
  const deleted = Update.create({ seq: 2, update: { oneofKind: "deleteMessages", deleteMessages: {
    messageIds: [1n], peerId: { type: { oneofKind: "user", user: { userId: 2n } } },
  } } })
  repair.observeDelivery(1, [deleted], 1)
  state.rows = [row(10, 2)]
  await repair.poll()
  state.now += 1_000
  await repair.poll()
  expect(state.hints).toEqual([])
  expect(repair.knownPeerChatId(1, 2)).toBe(10)
  expect(repair.knownPeerChatId(2, 1)).toBeUndefined()
  state.now += RECENT_REALTIME_BUCKET_TTL_MS
  expect(repair.knownPeerChatId(1, 2)).toBeUndefined()
})
