import { captureUpdateDiscoveryWatermark } from "@in/server/modules/updates/updateDiscoveryBarrier"
import { getUpdatesState } from "@in/server/functions/updates.getUpdatesState"
import { connectionManager } from "@in/server/ws/connections"
import { Log } from "@in/server/utils/log"
import { db } from "@in/server/db"
import { UpdateBucket, chats, updates } from "@in/server/db/schema"
import { Sync } from "@in/server/modules/updates/sync"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { loadRepairUserFrontiers } from "./repairDiscovery"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { Update } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import type { InternalEvent } from "./schemas"

const log = new Log("internalMessaging.repair")
export const MAX_CONCURRENT_SCANS = 8
export const MAX_PENDING_USERS = 4096
const MAX_TARGETED_RECIPIENTS_PER_QUERY = 512
const MAX_CONCURRENT_TARGETED_DELIVERIES = 32

type DurableUpdatesAvailableEvent = Extract<InternalEvent, { kind: "DurableUpdatesAvailable" }>

type Observation = {
  date: bigint
  /** Highest frontier whose typed user catch-up hint this admission accepted. */
  hintedSeq: number
  /**
   * Highest frontier for which this admission completed one legacy replay
   * attempt. This is not a client acknowledgement: missing and filtered
   * historical records are expected outcomes for an authenticated getUpdates
   * page, and must not be retried forever.
   */
  replayAttemptedSeq: number
  /** Bound reconnect attempts for a frontier that cannot be replayed to older clients. */
  lastReconnect?: { frontier: number; at: number }
  lastCompletedAt: number
}

type DiscoverySnapshot = {
  watermark: Date
  /** Undefined means the batched reader did not find this user; fall back safely. */
  userFrontier?: number
}

export type CurrentUserReplayResult =
  | "replayed"
  | "missing_record"
  | "filtered_record"
  | "transport_not_accepted"
  | "cancelled"

export type ConnectedUserRepairRuntime = {
  captureWatermark: () => Promise<Date>
  /** Optional injection keeps lightweight repair tests independent of database fixtures. */
  loadUserFrontiers?: (userIds: readonly number[]) => Promise<Map<number, number>>
  getUpdatesState: (
    input: { date: bigint },
    context: { currentUserId: number; currentSessionId: number },
    options?: { shouldEmitHints?: () => boolean; discoveryWatermark?: Date; userFrontier?: number },
  ) =>
    Promise<{ date?: bigint; seq?: number }>
  connectedUserIds: () => number[]
  hasConnections: (userId: number) => boolean
  getConnectionEpoch: (userId: number) => number
  /**
   * Emits the current durable user frontier as a typed catch-up hint. This is
   * a transport signal, not an acknowledgement; the client fetches its own
   * authenticated page and applies its sidecars through getUpdates.
   */
  emitUserHint: (userId: number, frontier: number, isActive: () => boolean) => Promise<number>
  /**
   * Emits the actual current, access-filtered record for released clients
   * which safely ignore the newer user hint. Missing and filtered are durable
   * facts; a thrown error is transient and must remain retryable.
   */
  replayCurrentUserUpdate: (
    userId: number,
    frontier: number,
    isActive: () => boolean,
  ) => Promise<CurrentUserReplayResult>
  /** Closes only a genuinely unrecoverable frontier with a distinct wire reason. */
  closeForUnrecoverableFrontier: (
    userId: number,
    reason: "no_replayable_record" | "transport_not_accepted",
    expectedConnectionEpoch: number,
  ) => number
  /** Sends one current bucket hint without starting a cross-bucket discovery scan. */
  deliverTargetedBucketHint: (event: DurableUpdatesAvailableEvent) => Promise<void>
}

const runtime: ConnectedUserRepairRuntime = {
  captureWatermark: captureUpdateDiscoveryWatermark,
  loadUserFrontiers: loadRepairUserFrontiers,
  // Keep this lookup inside the call. `updates.getUpdatesState` reaches
  // update-discovery modules which can import the repair entry point first;
  // reading the imported binding while this module initializes would hit its
  // temporal-dead-zone in that circular entry order.
  getUpdatesState: (input, context, options) => getUpdatesState(input, context, options),
  connectedUserIds: () => connectionManager.getAuthenticatedUserIds(),
  hasConnections: (userId) => connectionManager.getUserConnections(userId).length > 0,
  getConnectionEpoch: (userId) => connectionManager.getUserConnectionEpoch(userId),
  emitUserHint: emitUserHasNewUpdates,
  replayCurrentUserUpdate: replayCurrentUserUpdate,
  closeForUnrecoverableFrontier: (userId, reason, expectedConnectionEpoch) =>
    connectionManager.closeUserConnectionsForDurableRepair(userId, reason, expectedConnectionEpoch),
  deliverTargetedBucketHint: deliverTargetedBucketHint,
}

/** Periodic fenced discovery repairs lost final hints even while Redis is healthy. */
export class ConnectedUserRepair {
  private readonly observations = new Map<number, Observation>()
  /**
   * A socket admission invalidates work captured by an earlier scan. This is
   * deliberately separate from observations: a new socket can arrive while a
   * first scan has not yet written an observation at all.
   */
  private readonly admissionGenerations = new Map<number, number>()
  private readonly pending = new Set<number>()
  /** Fence and frontier are one snapshot; never merge them independently. */
  private readonly pendingDiscoverySnapshots = new Map<number, DiscoverySnapshot>()
  /** Periodic scans yield a queue slot to an admission when the queue is full. */
  private readonly periodicPending = new Set<number>()
  /** A running scan can be invalidated by a new admission while the queue is full. */
  private readonly rescanAfterCurrent = new Map<number, DiscoverySnapshot | undefined>()
  private readonly running = new Set<number>()
  private readonly tasks = new Set<Promise<void>>()
  /** Captures and microtask admission batches are owned by stop()/waitForIdle(). */
  private readonly scheduledTasks = new Set<Promise<void>>()
  private readonly pendingAdmissionUsers = new Set<number>()
  private timer: ReturnType<typeof setTimeout> | undefined
  private enabled = false
  private generation = 0
  private startTask: Promise<void> | undefined
  private baselineDate: bigint = 0n
  /** The next connected-user snapshot slot to admit when the bounded queue has room. */
  private connectedUserCursor = 0
  private periodicSweepTask: Promise<void> | undefined
  private admissionBatchTask: Promise<void> | undefined
  constructor(private readonly repairRuntime: ConnectedUserRepairRuntime = runtime) {}

  async start(): Promise<void> {
    if (this.enabled) return
    if (this.startTask) return this.startTask
    const generation = ++this.generation
    const task = this.startAtGeneration(generation)
    this.startTask = task
    try {
      await task
    } finally {
      if (this.startTask === task) this.startTask = undefined
    }
  }

  private async startAtGeneration(generation: number): Promise<void> {
    // Call after broker subscription. An inclusive warm cursor also covers
    // mutations that raced setup, without treating an absent date as repair.
    const watermark = await this.repairRuntime.captureWatermark()
    if (generation !== this.generation || this.enabled) return
    assertDiscoveryWatermark(watermark)
    this.baselineDate = BigInt(Math.max(0, Math.floor(watermark.getTime() / 1000) - 1))
    this.enabled = true
    this.schedule()
  }

  async stop(): Promise<void> {
    ++this.generation
    this.enabled = false
    if (this.timer) clearTimeout(this.timer)
    this.timer = undefined
    this.pending.clear()
    this.pendingDiscoverySnapshots.clear()
    this.periodicPending.clear()
    this.rescanAfterCurrent.clear()
    this.pendingAdmissionUsers.clear()
    this.observations.clear()
    this.admissionGenerations.clear()
    this.connectedUserCursor = 0
    await Promise.allSettled([
      ...this.tasks,
      ...this.scheduledTasks,
      ...(this.startTask ? [this.startTask] : []),
    ])
  }

  observe(userId: number): void {
    this.enqueue(userId, { source: "event" })
  }

  /** A newly admitted socket needs its own catch-up signal, even at an old frontier. */
  observeConnection(userId: number): void {
    if (!this.enabled) return
    this.admissionGenerations.set(userId, (this.admissionGenerations.get(userId) ?? 0) + 1)
    const previous = this.observations.get(userId)
    if (previous) this.setObservation(userId, { ...previous, hintedSeq: 0, replayAttemptedSeq: 0 })
    this.pendingAdmissionUsers.add(userId)
    this.scheduleAdmissionBatch()
  }

  observeConnectedUsers(): void {
    if (!this.enabled || this.periodicSweepTask) return
    const generation = this.generation
    const task = this.runPeriodicSweep(generation).catch((error) => {
      log.warn("Connected-user repair sweep could not capture its discovery watermark", { error })
    })
    this.periodicSweepTask = task
    this.trackScheduledTask(task, () => {
      if (this.periodicSweepTask === task) this.periodicSweepTask = undefined
    })
  }

  private async runPeriodicSweep(generation: number): Promise<void> {
    const watermark = await this.repairRuntime.captureWatermark()
    assertDiscoveryWatermark(watermark)
    if (!this.isActive(generation)) return

    const userIds = this.repairRuntime.connectedUserIds()
    this.pruneDisconnectedObservations()
    if (userIds.length === 0) {
      this.connectedUserCursor = 0
      return
    }

    // Never restart at index zero after a full queue. With more connected
    // users than the bounded work queue, doing so would permanently starve
    // later users. The cursor advances only through admitted work; when the
    // queue remains full it stays on the first unadmitted user for the next
    // sweep.
    const start = this.connectedUserCursor % userIds.length
    const candidates = this.periodicCandidates(userIds, start)
    const frontiers = await this.loadUserFrontiers(candidates.map((candidate) => candidate.userId))
    if (!this.isActive(generation)) return
    for (const { index, userId } of candidates) {
      if (this.pending.size >= MAX_PENDING_USERS) {
        this.connectedUserCursor = index
        return
      }
      this.enqueue(userId, {
        source: "periodic",
        discoverySnapshot: makeDiscoverySnapshot(watermark, frontiers.get(userId)),
      })
    }
    this.connectedUserCursor = candidates.length === userIds.length
      ? start
      : (start + candidates.length) % userIds.length
  }

  async observeBucket(event: DurableUpdatesAvailableEvent): Promise<void> {
    const { bucket, frontier } = event
    if (bucket.kind === "user") {
      this.observeUserFrontier(bucket.userId, frontier)
      return
    }

    try {
      // Chat and Space events already carry their exact bucket and frontier.
      // Scanning the whole account for each local member was correct but made
      // one remote event run O(recipients) getUpdatesState discovery scans.
      // Targeted delivery keeps the current membership/access check while the
      // fenced periodic scan remains the durable fallback for missed hints.
      await this.repairRuntime.deliverTargetedBucketHint(event)
    } catch (error) {
      log.warn("Targeted durable hint failed; periodic repair remains active", { bucket: bucket.kind, error })
    }
  }

  private observeUserFrontier(userId: number, frontier: number): void {
    const previous = this.observations.get(userId)
    // A repeated broker reference whose typed hint and legacy replay attempt
    // both completed for this live admission cannot expose newer work. A
    // missing or filtered record is still accounted for by authenticated
    // getUpdates; do not turn that expected condition into a periodic retry
    // loop. Transport refusal remains incomplete and is retried normally.
    if (frontier > 0 && previous && previous.hintedSeq >= frontier && previous.replayAttemptedSeq >= frontier) return
    // A broker reference may arrive after this user's batch frontier was read
    // but before its queued scan starts. Its follow-up must query the current
    // frontier rather than pair the old snapshot with a newer durable event.
    this.pendingDiscoverySnapshots.delete(userId)
    this.rescanAfterCurrent.delete(userId)
    this.observe(userId)
  }

  get maximumRepairAgeMs(): number {
    const now = Date.now()
    let maximumAge = 0
    for (const observation of this.observations.values()) {
      maximumAge = Math.max(maximumAge, now - observation.lastCompletedAt)
    }
    return maximumAge
  }

  /** Wait for scans already admitted by observe(). Useful for controlled shutdown and tests. */
  async waitForIdle(): Promise<void> {
    while (this.tasks.size > 0 || this.scheduledTasks.size > 0) {
      await Promise.allSettled([...this.tasks, ...this.scheduledTasks])
    }
  }

  private periodicCandidates(userIds: readonly number[], start: number): { index: number; userId: number }[] {
    // The work queue excludes the actively scanning users, so a sweep can
    // prepare at most those free workers plus the bounded pending capacity.
    // Never batch-read frontiers for every connected account on a large node.
    const limit = Math.max(0, MAX_PENDING_USERS - this.pending.size + MAX_CONCURRENT_SCANS - this.running.size)
    const candidates: { index: number; userId: number }[] = []
    for (let offset = 0; offset < userIds.length && candidates.length < limit; offset += 1) {
      const index = (start + offset) % userIds.length
      const userId = userIds[index]
      if (userId !== undefined) candidates.push({ index, userId })
    }
    return candidates
  }

  private async loadUserFrontiers(userIds: readonly number[]): Promise<Map<number, number>> {
    if (userIds.length === 0 || !this.repairRuntime.loadUserFrontiers) return new Map()
    const frontiers = await this.repairRuntime.loadUserFrontiers(userIds)
    for (const [userId, frontier] of frontiers) {
      if (!Number.isSafeInteger(userId) || userId <= 0 || !Number.isSafeInteger(frontier) || frontier < 0) {
        throw new Error("Invalid batched user frontier")
      }
    }
    return frontiers
  }

  private enqueue(
    userId: number,
    options: { source: "admission" | "event" | "periodic"; discoverySnapshot?: DiscoverySnapshot },
  ): boolean {
    if (!this.enabled) return false
    if (this.pending.has(userId)) {
      this.mergePendingDiscoverySnapshot(userId, options.discoverySnapshot)
      if (options.source !== "periodic") this.periodicPending.delete(userId)
      this.pump()
      return true
    }

    if (this.pending.size >= MAX_PENDING_USERS) {
      if (options.source === "admission") {
        const deferredPeriodicUser = this.periodicPending.values().next().value as number | undefined
        if (deferredPeriodicUser !== undefined) {
          this.pending.delete(deferredPeriodicUser)
          this.pendingDiscoverySnapshots.delete(deferredPeriodicUser)
          this.periodicPending.delete(deferredPeriodicUser)
        } else if (this.running.has(userId)) {
          // At most MAX_CONCURRENT_SCANS entries can be held here. The task's
          // finally handler re-admits it after it has freed a queue slot.
          this.rescanAfterCurrent.set(userId, options.discoverySnapshot)
          return true
        } else {
          return false
        }
      } else {
        return false
      }
    }

    this.pending.add(userId)
    if (options.source === "periodic") this.periodicPending.add(userId)
    this.mergePendingDiscoverySnapshot(userId, options.discoverySnapshot)
    this.pump()
    return true
  }

  private mergePendingDiscoverySnapshot(userId: number, snapshot: DiscoverySnapshot | undefined): void {
    if (!snapshot) return
    assertDiscoverySnapshot(snapshot)
    const previous = this.pendingDiscoverySnapshots.get(userId)
    if (!previous || snapshot.watermark.getTime() >= previous.watermark.getTime()) {
      this.pendingDiscoverySnapshots.set(userId, snapshot)
    }
  }

  private pump(): void {
    while (this.enabled && this.running.size < MAX_CONCURRENT_SCANS && this.pending.size > 0) {
      let userId: number | undefined
      for (const candidate of this.pending) {
        if (!this.running.has(candidate)) {
          userId = candidate
          break
        }
      }
      if (userId === undefined) break
      this.pending.delete(userId)
      this.periodicPending.delete(userId)
      const discoverySnapshot = this.pendingDiscoverySnapshots.get(userId)
      this.pendingDiscoverySnapshots.delete(userId)
      if (!this.repairRuntime.hasConnections(userId)) continue
      this.running.add(userId)
      const generation = this.generation
      const task = this.scan(userId, generation, discoverySnapshot).finally(() => {
        this.running.delete(userId)
        this.tasks.delete(task)
        // Start an ordinary queued scan first; that creates room to retain an
        // admission that arrived while this scan occupied a full queue.
        this.pump()
        if (this.rescanAfterCurrent.has(userId)) {
          const discoverySnapshot = this.rescanAfterCurrent.get(userId)
          this.rescanAfterCurrent.delete(userId)
          this.enqueue(userId, { source: "admission", discoverySnapshot })
        }
        this.pump()
      })
      this.tasks.add(task)
    }
  }

  private async scan(userId: number, generation: number, discoverySnapshot: DiscoverySnapshot | undefined): Promise<void> {
    const previous = this.observations.get(userId)
    const admissionGeneration = this.admissionGenerations.get(userId) ?? 0
    const isCurrentScan = () =>
      this.isActive(generation) &&
      this.repairRuntime.hasConnections(userId) &&
      (this.admissionGenerations.get(userId) ?? 0) === admissionGeneration
    try {
      const requestedDate = previous?.date ?? this.baselineDate
      const snapshotCanAdvanceCheckpoint = discoverySnapshot !== undefined &&
        requestedDate <= floorDiscoveryWatermark(discoverySnapshot.watermark)
      const result = await this.repairRuntime.getUpdatesState(
        { date: requestedDate },
        { currentUserId: userId, currentSessionId: 0 },
        {
          shouldEmitHints: isCurrentScan,
          // A delayed periodic batch may hold a watermark older than this
          // user's current checkpoint. Never pass that stale fence: let the
          // handler acquire a new one rather than regress its cursor.
          discoveryWatermark: snapshotCanAdvanceCheckpoint ? discoverySnapshot.watermark : undefined,
          userFrontier: snapshotCanAdvanceCheckpoint ? discoverySnapshot.userFrontier : undefined,
        },
      )
      // Do not let a scan that began before a new socket was admitted publish
      // or checkpoint that socket's recovery obligation. The queued scan for
      // the later admission uses its own generation and sends the hint.
      if (!isCurrentScan()) return
      const nextSeq = Number(result.seq ?? 0)
      if (!Number.isSafeInteger(nextSeq) || nextSeq < 0) {
        throw new Error(`Invalid user update frontier: ${nextSeq}`)
      }

      // The first scan never absorbs an existing account frontier as a
      // baseline. It emits the same unsequenced discovery hint that chat and
      // space repair use, then also sends a current real record for released
      // clients that ignore the additive user hint.
      let hintedSeq = previous?.hintedSeq ?? 0
      let replayAttemptedSeq = previous?.replayAttemptedSeq ?? 0
      let lastReconnect = previous?.lastReconnect
      let hintAccepted = hintedSeq >= nextSeq
      if (nextSeq > 0 && !hintAccepted) {
        const isActive = isCurrentScan
        const hintConnectionEpoch = this.repairRuntime.getConnectionEpoch(userId)
        const accepted = await this.repairRuntime.emitUserHint(userId, nextSeq, isActive)
        if (!isActive()) return
        if (accepted <= 0) {
          lastReconnect = this.closeUnrecoverableFrontier(
            userId,
            nextSeq,
            "transport_not_accepted",
            hintConnectionEpoch,
            lastReconnect,
          )
        } else {
          hintedSeq = nextSeq
          hintAccepted = true
        }
      }
      if (nextSeq > 0 && hintAccepted && replayAttemptedSeq < nextSeq) {
        // A new admission after the hint belongs to a later repair epoch;
        // an older DB read must never close that fresh socket.
        const replayConnectionEpoch = this.repairRuntime.getConnectionEpoch(userId)
        const replay = await this.repairRuntime.replayCurrentUserUpdate(userId, nextSeq, isCurrentScan)
        if (!isCurrentScan() || replay === "cancelled") return
        if (replay === "replayed" || replay === "missing_record" || replay === "filtered_record") {
          // This records fallback issuance only. It does not assert that a
          // client applied the hint or that a historical record was visible.
          replayAttemptedSeq = nextSeq
        } else if (replay === "transport_not_accepted") {
          lastReconnect = this.closeUnrecoverableFrontier(
            userId,
            nextSeq,
            "transport_not_accepted",
            replayConnectionEpoch,
            lastReconnect,
          )
        }
      }
      if (!isCurrentScan()) return
      this.setObservation(userId, {
        date: result.date ?? this.baselineDate,
        hintedSeq,
        replayAttemptedSeq,
        lastReconnect,
        lastCompletedAt: Date.now(),
      })
    } catch (error) {
      // Preserve the prior checkpoint. A later scan or reconnect must retry.
      log.warn("Connected-user repair scan failed", { userId, error })
    }
  }

  private setObservation(userId: number, observation: Observation): void {
    this.observations.delete(userId)
    this.observations.set(userId, observation)
  }

  /**
   * Checkpoints are retained for every locally connected user, then removed
   * after disconnect. Capping them at the pending-work limit would evict
   * healthy users on larger nodes and make their next sweep replay the latest
   * legacy record again. The queue remains bounded; this map scales only with
   * already-resident WebSocket users and avoids that repeat-delivery cost.
   */
  private pruneDisconnectedObservations(): void {
    for (const userId of this.observations.keys()) {
      if (!this.repairRuntime.hasConnections(userId)) {
        this.observations.delete(userId)
        this.admissionGenerations.delete(userId)
      }
    }
    // An admission may arrive while its first scan is in flight, before an
    // observation exists. Do not retain that fence once the user disconnects.
    for (const userId of this.admissionGenerations.keys()) {
      if (!this.repairRuntime.hasConnections(userId)) this.admissionGenerations.delete(userId)
    }
  }

  private schedule(): void {
    if (!this.enabled) return
    this.timer = setTimeout(() => {
      this.timer = undefined
      this.observeConnectedUsers()
      this.schedule()
    }, 15_000 + Math.floor(Math.random() * 15_000))
    this.timer.unref?.()
  }

  private scheduleAdmissionBatch(): void {
    if (this.admissionBatchTask) return
    const generation = this.generation
    // A microtask collects every connection admitted by the current turn
    // without an unowned timer. It is tracked by waitForIdle()/stop().
    const task = Promise.resolve()
      .then(() => this.flushAdmissionBatch(generation))
      .catch((error) => {
        log.warn("Connected-user repair admission batch could not capture its discovery watermark", { error })
      })
    this.admissionBatchTask = task
    this.trackScheduledTask(task, () => {
      if (this.admissionBatchTask === task) this.admissionBatchTask = undefined
      if (this.enabled && this.pendingAdmissionUsers.size > 0) this.scheduleAdmissionBatch()
    })
  }

  private async flushAdmissionBatch(generation: number): Promise<void> {
    const userIds = [...this.pendingAdmissionUsers]
    this.pendingAdmissionUsers.clear()
    if (userIds.length === 0 || !this.isActive(generation)) return

    const watermark = await this.repairRuntime.captureWatermark()
    assertDiscoveryWatermark(watermark)
    if (!this.isActive(generation)) return
    const connectedUserIds = userIds.filter((userId) => this.repairRuntime.hasConnections(userId))
    const frontiers = await this.loadUserFrontiers(connectedUserIds)
    if (!this.isActive(generation)) return
    for (const userId of userIds) {
      if (!this.repairRuntime.hasConnections(userId)) {
        this.admissionGenerations.delete(userId)
        continue
      }
      this.enqueue(userId, {
        source: "admission",
        discoverySnapshot: makeDiscoverySnapshot(watermark, frontiers.get(userId)),
      })
    }
  }

  private trackScheduledTask(task: Promise<void>, onSettled: () => void): void {
    this.scheduledTasks.add(task)
    void task.then(() => {
      this.scheduledTasks.delete(task)
      onSettled()
    })
  }

  private isActive(generation: number): boolean {
    return this.enabled && generation === this.generation
  }

  private closeUnrecoverableFrontier(
    userId: number,
    frontier: number,
    reason: "no_replayable_record" | "transport_not_accepted",
    expectedConnectionEpoch: number,
    previous: Observation["lastReconnect"],
  ): Observation["lastReconnect"] {
    const now = Date.now()
    if (previous?.frontier === frontier && now - previous.at < 30_000) {
      log.warn("Durable user frontier remains unreplayable; reconnect remains rate limited", { userId, frontier, reason })
      return previous
    }
    const closed = this.repairRuntime.closeForUnrecoverableFrontier(userId, reason, expectedConnectionEpoch)
    log.warn("Closing affected sockets for unreplayable durable user frontier", { userId, frontier, reason, closed })
    return { frontier, at: now }
  }
}

const assertDiscoveryWatermark = (watermark: Date): void => {
  if (!(watermark instanceof Date) || !Number.isFinite(watermark.getTime())) {
    throw new Error("Invalid discovery watermark")
  }
}

const makeDiscoverySnapshot = (watermark: Date, userFrontier: number | undefined): DiscoverySnapshot => {
  const snapshot = userFrontier === undefined ? { watermark } : { watermark, userFrontier }
  assertDiscoverySnapshot(snapshot)
  return snapshot
}

const assertDiscoverySnapshot = (snapshot: DiscoverySnapshot): void => {
  assertDiscoveryWatermark(snapshot.watermark)
  if (snapshot.userFrontier !== undefined &&
    (!Number.isSafeInteger(snapshot.userFrontier) || snapshot.userFrontier < 0)) {
    throw new Error("Invalid batched user frontier")
  }
}

const floorDiscoveryWatermark = (watermark: Date): bigint => BigInt(Math.floor(watermark.getTime() / 1000))

/**
 * Sends the precise bucket hinted by Redis to currently connected recipients.
 *
 * The cache/index is only used as a candidate source. Chat recipients go
 * through the same effective-access projection used by mutation code, while
 * Space recipients use the guarded space fanout helper. Neither path invokes
 * getUpdatesState, so routine fanout cannot multiply account-wide discovery
 * work by the number of recipients on this process.
 */
export async function deliverTargetedBucketHint(event: DurableUpdatesAvailableEvent): Promise<void> {
  if (event.bucket.kind === "space") {
    // Keep this dynamic: websocket connection registration imports repair for
    // the periodic fallback, and a static repair -> realtime -> connections
    // edge would make startup ordering needlessly cyclic.
    const { sendMessageToRealtimeSpace } = await import("@in/server/realtime/message")
    await sendMessageToRealtimeSpace(event.bucket.spaceId, {
      oneofKind: "update",
      update: {
        updates: [{
          update: {
            oneofKind: "spaceHasNewUpdates",
            spaceHasNewUpdates: {
              spaceId: BigInt(event.bucket.spaceId),
              updateSeq: event.frontier,
            },
          },
        }],
      },
    })
    return
  }

  if (event.bucket.kind !== "chat") return
  if (connectionManager.getAuthenticatedUserCount() === 0) return
  const [chat] = await db.select().from(chats).where(eq(chats.id, event.bucket.chatId)).limit(1)
  if (!chat) return
  const candidateUserIds = chat.type === "private"
    ? privateChatRecipients(chat)
    // A local Space membership index may lag an access grant or removal from
    // another process. For threads it can only be an optimization when paired
    // with a safe complete fallback, so the authoritative projection receives
    // every connected local user in bounded chunks.
    : connectionManager.getAuthenticatedUserIds()
  if (candidateUserIds.length === 0) return

  for (let offset = 0; offset < candidateUserIds.length; offset += MAX_TARGETED_RECIPIENTS_PER_QUERY) {
    const candidates = candidateUserIds.slice(offset, offset + MAX_TARGETED_RECIPIENTS_PER_QUERY)
    const access = await getEffectiveChatAccessUserIds(db, [chat.id], { userIds: candidates })
    const recipients = access.get(chat.id) ?? new Set<number>()
    await deliverChatHintBatch(chat, recipients, event)
  }
}

const privateChatRecipients = (
  chat: typeof chats.$inferSelect,
): number[] => {
  return Array.from(new Set([chat.minUserId, chat.maxUserId].filter(
    (userId): userId is number =>
      typeof userId === "number" &&
      Number.isSafeInteger(userId) &&
      userId > 0 &&
      connectionManager.getUserConnections(userId).length > 0,
  )))
}

export const deliverChatHintBatch = async (
  chat: typeof chats.$inferSelect,
  recipients: ReadonlySet<number>,
  event: DurableUpdatesAvailableEvent,
): Promise<void> => {
  const { RealtimeUpdates } = await import("@in/server/realtime/message")
  const userIds = Array.from(recipients)
  const failures: unknown[] = []
  for (let offset = 0; offset < userIds.length; offset += MAX_CONCURRENT_TARGETED_DELIVERIES) {
    const batch = userIds.slice(offset, offset + MAX_CONCURRENT_TARGETED_DELIVERIES)
    // Do not return while another recipient from this bounded chunk is still
    // delivering. The inbound hint owner can then drain all work it admitted,
    // and a transient socket failure does not prevent later recipients from
    // receiving their independent best-effort signal.
    const results = await Promise.allSettled(batch.map(async (userId) => {
      const update: Update = {
        update: {
          oneofKind: "chatHasNewUpdates",
          chatHasNewUpdates: {
            chatId: BigInt(chat.id),
            peerId: Encoders.peerFromChat(chat, { currentUserId: userId }),
            updateSeq: event.frontier,
          },
        },
      }
      const skipSessionId = event.senderUserId === userId && event.excludeSessionId !== undefined
        ? event.excludeSessionId
        : undefined
      await RealtimeUpdates.pushToUserWithDelivery(
        userId,
        [update],
        skipSessionId === undefined ? undefined : { skipSessionId },
      )
    }))
    for (const result of results) {
      if (result.status === "rejected") failures.push(result.reason)
    }
  }
  if (failures.length > 0) {
    throw new AggregateError(failures, "One or more targeted chat durable hints failed")
  }
}

/**
 * Replaying only the current record is deliberate. A receiver below this
 * sequence buffers it and uses the authenticated getUpdates RPC for pages,
 * sidecars and TOO_LONG repair. Sending a whole page over ServerMessage would
 * lose its UpdateSidecars, which are RPC-only protocol data.
 */
export async function emitUserHasNewUpdates(userId: number, frontier: number, isActive: () => boolean): Promise<number> {
  if (!isActive()) return 0
  // Avoid a static repair -> realtime/message -> connections -> repair cycle.
  const { RealtimeUpdates } = await import("@in/server/realtime/message")
  if (!isActive()) return 0
  return await RealtimeUpdates.pushToUserWithDelivery(userId, [{
    update: {
      oneofKind: "userHasNewUpdates",
      userHasNewUpdates: { updateSeq: frontier },
    },
  }])
}

export async function replayCurrentUserUpdate(
  userId: number,
  frontier: number,
  isActive: () => boolean = () => true,
): Promise<CurrentUserReplayResult> {
  if (!isActive()) return "cancelled"
  const [record] = await db
    .select()
    .from(updates)
    .where(and(
      eq(updates.bucket, UpdateBucket.User),
      eq(updates.entityId, userId),
      eq(updates.seq, frontier),
    ))
    .limit(1)
  if (!record) return "missing_record"

  // Current access is rechecked before an old durable payload is allowed back
  // onto a live socket. Stale grants are explicitly skipped by this helper.
  const page = await Sync.prepareUserUpdatesPage([record], userId)
  const update = page.updates.find((candidate) => Number(candidate.seq ?? 0) === frontier)
  if (!update) return "filtered_record"

  // Avoid a static repair -> realtime/message -> connections -> repair cycle.
  const { RealtimeUpdates } = await import("@in/server/realtime/message")
  if (!isActive()) return "cancelled"
  return (await RealtimeUpdates.pushToUserWithDelivery(userId, [update])) > 0 ? "replayed" : "transport_not_accepted"
}

export const connectedUserRepair = new ConnectedUserRepair()
