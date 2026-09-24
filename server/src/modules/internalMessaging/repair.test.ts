import { afterEach, describe, expect, spyOn, test } from "bun:test"
import { RealtimeUpdates } from "@in/server/realtime/message"
import {
  ConnectedUserRepair,
  deliverChatHintBatch,
  MAX_CONCURRENT_SCANS,
  MAX_PENDING_USERS,
  type ConnectedUserRepairRuntime,
  type CurrentUserReplayResult,
} from "./repair"

const repairs = new Set<ConnectedUserRepair>()

afterEach(async () => {
  await Promise.all([...repairs].map((repair) => repair.stop()))
  repairs.clear()
})

const createRuntime = (input: {
  states: { date: bigint; seq: number }[]
  replay?: (frontier: number) => CurrentUserReplayResult | Promise<CurrentUserReplayResult>
  hint?: (frontier: number) => number | Promise<number>
  connected?: () => boolean
}) => {
  const requestedDates: bigint[] = []
  const hinted: number[] = []
  const replayed: number[] = []
  const closed: { userId: number; reason: string }[] = []
  let stateIndex = 0
  const runtime: ConnectedUserRepairRuntime = {
    captureWatermark: async () => new Date("2026-09-24T00:00:00.000Z"),
    getUpdatesState: async ({ date }) => {
      requestedDates.push(date)
      const state = input.states[stateIndex]
      stateIndex += 1
      if (!state) throw new Error("Unexpected repair scan")
      return state
    },
    connectedUserIds: () => [71],
    hasConnections: () => input.connected?.() ?? true,
    getConnectionEpoch: () => 1,
    emitUserHint: async (_userId, frontier) => {
      hinted.push(frontier)
      return await (input.hint?.(frontier) ?? 1)
    },
    replayCurrentUserUpdate: async (_userId, frontier) => {
      replayed.push(frontier)
      return await (input.replay?.(frontier) ?? "replayed")
    },
    closeForUnrecoverableFrontier: (userId, reason) => {
      closed.push({ userId, reason })
      return 1
    },
    deliverTargetedBucketHint: async () => {},
  }
  return { runtime, requestedDates, hinted, replayed, closed }
}

const scan = async (repair: ConnectedUserRepair, userId = 71) => {
  repair.observe(userId)
  await repair.waitForIdle()
}

describe("ConnectedUserRepair", () => {
  test("shares one fenced watermark across one thousand coalesced admissions", async () => {
    const userIds = Array.from({ length: 1_000 }, (_value, index) => index + 1)
    const fences: Date[] = []
    let captureCalls = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => {
        captureCalls += 1
        return new Date(`2026-09-24T00:00:${String(captureCalls).padStart(2, "0")}.000Z`)
      },
      getUpdatesState: async (_input, _context, options) => {
        if (!options?.discoveryWatermark) throw new Error("Expected a shared admission watermark")
        fences.push(options.discoveryWatermark)
        return { date: 1n, seq: 0 }
      },
      connectedUserIds: () => userIds,
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async () => 1,
      replayCurrentUserUpdate: async () => "replayed",
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    captureCalls = 0
    for (const userId of userIds) repair.observeConnection(userId)
    await repair.waitForIdle()

    expect(captureCalls).toBe(1)
    expect(fences).toHaveLength(userIds.length)
    expect(new Set(fences.map((watermark) => watermark.getTime())).size).toBe(1)
  })

  test("uses the batched frontier snapshot and finds a later user mutation on the next sweep", async () => {
    const frontiers = [9, 10]
    const hinted: number[] = []
    const loaderCalls: number[][] = []
    const stateFrontiers: number[] = []
    let captures = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => {
        captures += 1
        return new Date(`2026-09-24T00:00:${String(captures * 10).padStart(2, "0")}.000Z`)
      },
      loadUserFrontiers: async (userIds) => {
        loaderCalls.push([...userIds])
        const frontier = frontiers.shift()
        return frontier === undefined ? new Map() : new Map([[71, frontier]])
      },
      getUpdatesState: async (_input, _context, options) => {
        if (!options?.discoveryWatermark || options.userFrontier === undefined) {
          throw new Error("Expected matched internal discovery snapshot")
        }
        stateFrontiers.push(options.userFrontier)
        return { date: BigInt(Math.floor(options.discoveryWatermark.getTime() / 1000)), seq: options.userFrontier }
      },
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async (_userId, frontier) => {
        hinted.push(frontier)
        return 1
      },
      replayCurrentUserUpdate: async () => "replayed",
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observeConnectedUsers()
    await repair.waitForIdle()
    repair.observeConnectedUsers()
    await repair.waitForIdle()

    expect(loaderCalls).toEqual([[71], [71]])
    expect(stateFrontiers).toEqual([9, 10])
    expect(hinted).toEqual([9, 10])
  })

  test("leaves a missing batched user frontier to the per-account fallback", async () => {
    let sawFallback = false
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => new Date("2026-09-24T00:00:00.000Z"),
      loadUserFrontiers: async () => new Map(),
      getUpdatesState: async (_input, _context, options) => {
        sawFallback = options?.discoveryWatermark !== undefined && options.userFrontier === undefined
        return { date: 1n, seq: 0 }
      },
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async () => 1,
      replayCurrentUserUpdate: async () => "replayed",
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observeConnectedUsers()
    await repair.waitForIdle()

    expect(sawFallback).toBe(true)
  })

  test("does not use a delayed sweep watermark to regress a newer checkpoint", async () => {
    const sweepCaptureStarted = Promise.withResolvers<void>()
    const releaseSweepCapture = Promise.withResolvers<void>()
    const firstScanFinished = Promise.withResolvers<void>()
    const secondScanStarted = Promise.withResolvers<void>()
    const releaseSecondScan = Promise.withResolvers<void>()
    const initialWatermark = new Date("2026-09-24T00:00:10.000Z")
    const initialWatermarkSeconds = BigInt(Math.floor(initialWatermark.getTime() / 1000))
    const requests: { date: bigint; watermark?: Date }[] = []
    let captures = 0
    let scans = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => {
        captures += 1
        if (captures === 1) return initialWatermark
        sweepCaptureStarted.resolve()
        await releaseSweepCapture.promise
        return new Date("2026-09-24T00:00:20.000Z")
      },
      getUpdatesState: async ({ date }, _context, options) => {
        scans += 1
        requests.push({ date, watermark: options?.discoveryWatermark })
        if (scans === 1) firstScanFinished.resolve()
        if (scans === 2) {
          // This scan cannot begin until scan one has installed date=30.
          // Keep it active while the older periodic fence is released.
          secondScanStarted.resolve()
          await releaseSecondScan.promise
        }
        return { date: initialWatermarkSeconds + BigInt(19 + scans), seq: 0 }
      },
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async () => 1,
      replayCurrentUserUpdate: async () => "replayed",
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observeConnectedUsers()
    await sweepCaptureStarted.promise
    repair.observe(71)
    await firstScanFinished.promise
    repair.observe(71)
    await secondScanStarted.promise
    releaseSweepCapture.resolve()
    releaseSecondScan.resolve()
    await repair.waitForIdle()

    expect(requests.map((request) => request.date)).toEqual([
      BigInt(Math.floor(initialWatermark.getTime() / 1000) - 1),
      initialWatermarkSeconds + 20n,
      initialWatermarkSeconds + 21n,
    ])
    // The second scan owns a newer checkpoint than the delayed sweep fence,
    // so it must acquire its own fence instead of advancing from time 20.
    expect(requests.map((request) => request.watermark)).toEqual([undefined, undefined, undefined])
  })

  test("waits for an in-flight periodic watermark capture during stop", async () => {
    const sweepCaptureStarted = Promise.withResolvers<void>()
    const releaseSweepCapture = Promise.withResolvers<void>()
    let captures = 0
    let scans = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => {
        captures += 1
        if (captures === 1) return new Date("2026-09-24T00:00:00.000Z")
        sweepCaptureStarted.resolve()
        await releaseSweepCapture.promise
        return new Date("2026-09-24T00:00:01.000Z")
      },
      getUpdatesState: async () => {
        scans += 1
        return { date: 1n, seq: 0 }
      },
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async () => 1,
      replayCurrentUserUpdate: async () => "replayed",
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observeConnectedUsers()
    await sweepCaptureStarted.promise
    let stopped = false
    const stopping = repair.stop().then(() => { stopped = true })
    await Promise.resolve()
    expect(stopped).toBe(false)

    releaseSweepCapture.resolve()
    await stopping
    expect(scans).toBe(0)
  })

  test("rotates a bounded queue through every connected user without replaying active checkpoints", async () => {
    const userIds = Array.from(
      { length: MAX_PENDING_USERS + MAX_CONCURRENT_SCANS + 1 },
      (_value, index) => index + 1,
    )
    const firstWorkersStarted = Promise.withResolvers<void>()
    const releaseScans = Promise.withResolvers<void>()
    const scannedUserIds = new Set<number>()
    let hintCalls = 0
    let replayCalls = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => new Date("2026-09-24T00:00:00.000Z"),
      getUpdatesState: async (_input, context) => {
        scannedUserIds.add(context.currentUserId)
        if (scannedUserIds.size === MAX_CONCURRENT_SCANS) firstWorkersStarted.resolve()
        await releaseScans.promise
        return { date: 1n, seq: 1 }
      },
      connectedUserIds: () => userIds,
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async () => {
        hintCalls += 1
        return 1
      },
      replayCurrentUserUpdate: async () => {
        replayCalls += 1
        return "replayed"
      },
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observeConnectedUsers()
    await firstWorkersStarted.promise
    // Eight workers have started and the remaining 4,096 slots are full.
    // The extra user remains at the fair cursor for the following sweep.
    expect(scannedUserIds.size).toBe(MAX_CONCURRENT_SCANS)

    releaseScans.resolve()
    await repair.waitForIdle()
    expect(scannedUserIds.size).toBe(MAX_PENDING_USERS + MAX_CONCURRENT_SCANS)

    repair.observeConnectedUsers()
    await repair.waitForIdle()

    expect(scannedUserIds.size).toBe(userIds.length)
    // The second sweep revisits some users while reaching the late user. Their
    // active-user checkpoints retain the delivered frontier, so no extra
    // legacy record/hint is replayed.
    expect(hintCalls).toBe(userIds.length)
    expect(replayCalls).toBe(userIds.length)
  })

  test("makes room for an admission by deferring periodic work at a full queue", async () => {
    const userIds = Array.from(
      { length: MAX_PENDING_USERS + MAX_CONCURRENT_SCANS },
      (_value, index) => index + 1,
    )
    const firstWorkersStarted = Promise.withResolvers<void>()
    const releaseFirstWorkers = Promise.withResolvers<void>()
    const admissionFenceCaptured = Promise.withResolvers<void>()
    const scansByUser = new Map<number, number>()
    let blockedWorkers = 0
    let captures = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => {
        captures += 1
        if (captures === 3) admissionFenceCaptured.resolve()
        return new Date("2026-09-24T00:00:00.000Z")
      },
      getUpdatesState: async (_input, context) => {
        scansByUser.set(context.currentUserId, (scansByUser.get(context.currentUserId) ?? 0) + 1)
        blockedWorkers += 1
        if (blockedWorkers === MAX_CONCURRENT_SCANS) firstWorkersStarted.resolve()
        if (blockedWorkers <= MAX_CONCURRENT_SCANS) await releaseFirstWorkers.promise
        return { date: 1n, seq: 0 }
      },
      connectedUserIds: () => userIds,
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async () => 1,
      replayCurrentUserUpdate: async () => "replayed",
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observeConnectedUsers()
    await firstWorkersStarted.promise
    repair.observeConnection(1)
    await admissionFenceCaptured.promise
    await Promise.resolve() // let the owned admission microtask enqueue
    releaseFirstWorkers.resolve()
    await repair.waitForIdle()

    // User 1 was already running. Its admission still receives a second scan;
    // one ordinary periodic entry yielded the bounded queue slot.
    expect(scansByUser.get(1)).toBe(2)
  })

  test("uses a targeted chat or space hint without starting per-recipient discovery", async () => {
    const { runtime, requestedDates } = createRuntime({ states: [] })
    const targeted: string[] = []
    runtime.deliverTargetedBucketHint = async (event) => {
      targeted.push(`${event.bucket.kind}:${event.frontier}`)
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await repair.observeBucket({
      kind: "DurableUpdatesAvailable",
      bucket: { kind: "chat", chatId: 71 },
      frontier: 9,
    } as never)
    await repair.observeBucket({
      kind: "DurableUpdatesAvailable",
      bucket: { kind: "space", spaceId: 72 },
      frontier: 10,
    } as never)
    await repair.waitForIdle()

    expect(targeted).toEqual(["chat:9", "space:10"])
    expect(requestedDates).toEqual([])
  })

  test("waits for every targeted chat delivery in a failed chunk before returning", async () => {
    const heldDeliveryStarted = Promise.withResolvers<void>()
    const releaseHeldDelivery = Promise.withResolvers<void>()
    const started: number[] = []
    const push = spyOn(RealtimeUpdates, "pushToUserWithDelivery").mockImplementation(async (userId) => {
      started.push(userId)
      if (userId === 1) throw new Error("Synthetic first-recipient failure")
      if (userId === 2) {
        heldDeliveryStarted.resolve()
        await releaseHeldDelivery.promise
      }
      return 1
    })
    try {
      const delivery = deliverChatHintBatch(
        { id: 17, type: "thread" } as never,
        new Set([1, 2, 3]),
        { kind: "DurableUpdatesAvailable", bucket: { kind: "chat", chatId: 17 }, frontier: 4 } as never,
      )
      await heldDeliveryStarted.promise
      let settled = false
      void delivery.finally(() => { settled = true }).catch(() => {})
      await Promise.resolve()
      expect(settled).toBe(false)

      releaseHeldDelivery.resolve()
      await expect(delivery).rejects.toThrow("One or more targeted chat durable hints failed")
      expect(started).toEqual([1, 2, 3])
    } finally {
      releaseHeldDelivery.resolve()
      push.mockRestore()
    }
  })

  test("does not rescan an already replayed user frontier", async () => {
    const { runtime, requestedDates } = createRuntime({
      states: [{ date: 1_727_136_401n, seq: 9 }],
    })
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)
    await repair.observeBucket({
      kind: "DurableUpdatesAvailable",
      bucket: { kind: "user", userId: 71 },
      frontier: 9,
    } as never)
    await repair.waitForIdle()

    expect(requestedDates).toEqual([1_790_207_999n])
  })

  test("replays the first observed durable frontier instead of absorbing a missed pre-scan update", async () => {
    const { runtime, requestedDates, hinted, replayed } = createRuntime({
      states: [{ date: 1_727_136_401n, seq: 9 }],
    })
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)

    // The inclusive baseline is one second before the broker-subscription
    // watermark. A lost hint before the first periodic scan is still signaled.
    expect(requestedDates).toEqual([1_790_207_999n])
    expect(hinted).toEqual([9])
    expect(replayed).toEqual([9])
  })

  test("does not disconnect or re-send a healthy already-replayed frontier", async () => {
    const { runtime, hinted, replayed, closed } = createRuntime({
      states: [
        { date: 1_727_136_401n, seq: 9 },
        { date: 1_727_136_402n, seq: 9 },
      ],
    })
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)
    await scan(repair)

    // A duplicate user frontier is harmless and does not disturb live sockets.
    expect(hinted).toEqual([9])
    expect(replayed).toEqual([9])
    expect(closed).toEqual([])
  })

  test("catches a durable user update committed between repair scans", async () => {
    const { runtime, requestedDates, hinted, replayed } = createRuntime({
      states: [
        { date: 1_727_136_401n, seq: 9 },
        { date: 1_727_136_403n, seq: 10 },
      ],
    })
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)
    await scan(repair)

    expect(requestedDates).toEqual([1_790_207_999n, 1_727_136_401n])
    expect(hinted).toEqual([9, 10])
    expect(replayed).toEqual([9, 10])
  })

  test("does not repeat or disconnect a fixed unreplayable historical frontier", async () => {
    for (const replayResult of ["missing_record", "filtered_record"] as const) {
      const { runtime, hinted, replayed, closed } = createRuntime({
        states: [
          { date: 1_727_136_401n, seq: 9 },
          { date: 1_727_136_402n, seq: 9 },
          { date: 1_727_136_403n, seq: 9 },
        ],
        replay: () => replayResult,
      })
      const repair = new ConnectedUserRepair(runtime)
      repairs.add(repair)

      await repair.start()
      await scan(repair) // initial recovery attempt
      await scan(repair) // formerly the 31-second reconnect-rate window
      await scan(repair) // formerly the 62-second reconnect-rate window

      expect(hinted).toEqual([9])
      expect(replayed).toEqual([9])
      expect(closed).toEqual([])
    }
  })

  test("repairs a new frontier after a historical replay was unavailable", async () => {
    const { runtime, hinted, replayed, closed } = createRuntime({
      states: [
        { date: 1_727_136_401n, seq: 9 },
        { date: 1_727_136_402n, seq: 9 },
        { date: 1_727_136_403n, seq: 10 },
      ],
      replay: (frontier) => frontier === 9 ? "missing_record" : "replayed",
    })
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)
    await scan(repair)
    await scan(repair)

    expect(hinted).toEqual([9, 10])
    expect(replayed).toEqual([9, 10])
    expect(closed).toEqual([])
  })

  test("closes only after a live transport refuses a user recovery hint", async () => {
    const { runtime, replayed, closed } = createRuntime({
      states: [{ date: 1_727_136_401n, seq: 9 }],
      hint: () => 0,
    })
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)

    expect(replayed).toEqual([])
    expect(closed).toEqual([{ userId: 71, reason: "transport_not_accepted" }])
  })

  test("a newly admitted socket replays its current frontier even when another socket is healthy", async () => {
    const { runtime, hinted, replayed } = createRuntime({
      states: [
        { date: 1_727_136_401n, seq: 9 },
        { date: 1_727_136_402n, seq: 9 },
      ],
    })
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)
    repair.observeConnection(71)
    await repair.waitForIdle()

    expect(hinted).toEqual([9, 9])
    expect(replayed).toEqual([9, 9])
  })

  test("a newly admitted socket retries its own legacy replay after a historical record was unavailable", async () => {
    const { runtime, hinted, replayed, closed } = createRuntime({
      states: [
        { date: 1_727_136_401n, seq: 9 },
        { date: 1_727_136_402n, seq: 9 },
      ],
      replay: () => "filtered_record",
    })
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)
    repair.observeConnection(71)
    await repair.waitForIdle()

    expect(hinted).toEqual([9, 9])
    expect(replayed).toEqual([9, 9])
    expect(closed).toEqual([])
  })

  test("preserves a new admission's repair demand when an earlier discovery scan completes", async () => {
    const discoveryStarted = Promise.withResolvers<void>()
    const releaseDiscovery = Promise.withResolvers<void>()
    const hinted: number[] = []
    const replayed: number[] = []
    let scans = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => new Date("2026-09-24T00:00:00.000Z"),
      getUpdatesState: async () => {
        scans += 1
        if (scans === 2) {
          discoveryStarted.resolve()
          await releaseDiscovery.promise
        }
        return { date: BigInt(scans), seq: 9 }
      },
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async (_userId, frontier) => {
        hinted.push(frontier)
        return 1
      },
      replayCurrentUserUpdate: async (_userId, frontier) => {
        replayed.push(frontier)
        return "replayed"
      },
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    await scan(repair)

    repair.observe(71)
    await discoveryStarted.promise
    repair.observeConnection(71)
    releaseDiscovery.resolve()
    await repair.waitForIdle()

    // The stale scan cannot restore the prior hint/replay completion over the admission reset.
    // The queued later-generation scan sends both recovery paths again.
    expect(scans).toBe(3)
    expect(hinted).toEqual([9, 9])
    expect(replayed).toEqual([9, 9])
  })

  test("does not reuse a pruned admission generation after disconnect and reconnect", async () => {
    const oldScanStarted = Promise.withResolvers<void>()
    const periodicPruned = Promise.withResolvers<void>()
    const releaseOldScan = Promise.withResolvers<void>()
    const hinted: number[] = []
    const replayed: number[] = []
    let connected = true
    let connectionEpoch = 1
    let scans = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => new Date("2026-09-24T00:00:00.000Z"),
      getUpdatesState: async () => {
        scans += 1
        if (scans === 2) {
          oldScanStarted.resolve()
          await releaseOldScan.promise
        }
        return { date: 1n, seq: 9 }
      },
      connectedUserIds: () => {
        if (!connected) periodicPruned.resolve()
        return connected ? [71] : []
      },
      hasConnections: () => connected,
      getConnectionEpoch: () => connectionEpoch,
      emitUserHint: async (_userId, frontier) => {
        hinted.push(frontier)
        return 1
      },
      replayCurrentUserUpdate: async (_userId, frontier) => {
        replayed.push(frontier)
        return "replayed"
      },
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observeConnection(71)
    await repair.waitForIdle()
    repair.observe(71)
    await oldScanStarted.promise

    // A periodic pass prunes the disconnected account while its prior scan is
    // still held. Reconnection would restart admissionGenerations at one.
    connected = false
    repair.observeConnectedUsers()
    await periodicPruned.promise
    connected = true
    connectionEpoch += 1
    repair.observeConnection(71)
    releaseOldScan.resolve()
    await repair.waitForIdle()

    // The old scan cannot restore its completed frontier over the reconnect;
    // the new admission owns scan three and sends both recovery paths again.
    expect(scans).toBe(3)
    expect(hinted).toEqual([9, 9])
    expect(replayed).toEqual([9, 9])
  })

  test("does not checkpoint an old connection after its replay finishes", async () => {
    const replayStarted = Promise.withResolvers<void>()
    const releaseReplay = Promise.withResolvers<void>()
    const hinted: number[] = []
    const replayed: number[] = []
    let connectionEpoch = 1
    let replayCalls = 0
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => new Date("2026-09-24T00:00:00.000Z"),
      getUpdatesState: async () => ({ date: 1n, seq: 9 }),
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => connectionEpoch,
      emitUserHint: async (_userId, frontier) => {
        hinted.push(frontier)
        return 1
      },
      replayCurrentUserUpdate: async (_userId, frontier) => {
        replayed.push(frontier)
        replayCalls += 1
        if (replayCalls === 1) {
          replayStarted.resolve()
          await releaseReplay.promise
        }
        return "replayed"
      },
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observe(71)
    await replayStarted.promise
    // Authentication changes the authoritative epoch before its deferred
    // observeConnection callback can enqueue repair work.
    connectionEpoch = 2
    repair.observe(71)
    releaseReplay.resolve()
    await repair.waitForIdle()

    // The stale replay result cannot checkpoint frontier 9. The queued scan
    // for the new epoch therefore emits a fresh hint and replay.
    expect(hinted).toEqual([9, 9])
    expect(replayed).toEqual([9, 9])
  })

  test("does not emit a stale replay after stop while a state scan is in flight", async () => {
    const started = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const replayed: number[] = []
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => new Date("2026-09-24T00:00:00.000Z"),
      getUpdatesState: async () => {
        started.resolve()
        await release.promise
        return { date: 1_727_136_401n, seq: 9 }
      },
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async (_userId, frontier) => {
        replayed.push(frontier)
        return 1
      },
      replayCurrentUserUpdate: async (_userId, frontier) => {
        replayed.push(frontier)
        return "replayed"
      },
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observe(71)
    await started.promise
    const stopped = repair.stop()
    release.resolve()
    await stopped

    expect(replayed).toEqual([])
  })

  test("stop wins over an in-flight startup watermark", async () => {
    const started = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => {
        started.resolve()
        await release.promise
        return new Date("2026-09-24T00:00:00.000Z")
      },
      getUpdatesState: async () => ({ date: 1n, seq: 0 }),
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async () => 1,
      replayCurrentUserUpdate: async () => "replayed",
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    const startedRepair = repair.start()
    await started.promise
    const stopped = repair.stop()
    release.resolve()
    await Promise.all([startedRepair, stopped])

    repair.observe(71)
    await repair.waitForIdle()
  })

  test("stop wins while emitting a recovery hint", async () => {
    const hintStarted = Promise.withResolvers<void>()
    const releaseHint = Promise.withResolvers<void>()
    const replayed: number[] = []
    const runtime: ConnectedUserRepairRuntime = {
      captureWatermark: async () => new Date("2026-09-24T00:00:00.000Z"),
      getUpdatesState: async () => ({ date: 1n, seq: 9 }),
      connectedUserIds: () => [71],
      hasConnections: () => true,
      getConnectionEpoch: () => 1,
      emitUserHint: async () => {
        hintStarted.resolve()
        await releaseHint.promise
        return 1
      },
      replayCurrentUserUpdate: async (_userId, frontier) => {
        replayed.push(frontier)
        return "replayed"
      },
      closeForUnrecoverableFrontier: () => 0,
      deliverTargetedBucketHint: async () => {},
    }
    const repair = new ConnectedUserRepair(runtime)
    repairs.add(repair)

    await repair.start()
    repair.observe(71)
    await hintStarted.promise
    const stopped = repair.stop()
    releaseHint.resolve()
    await stopped

    expect(replayed).toEqual([])
  })
})
