import { createHash, randomUUID } from "node:crypto"
import { Log } from "@in/server/utils/log"
import { InternalRedisTransport, type BrokerHealth, type BrokerPublication } from "./redis"
import { decodeEnvelope, encodeEnvelope, InternalEnvelope, type InternalEvent } from "./schemas"

type Delivery = InternalEnvelope extends infer T
  ? T extends InternalEnvelope ? Pick<T, "target" | "event"> : never
  : never

const environment = process.env.NODE_ENV === "production" ? "prod" : process.env.NODE_ENV === "test" ? "test" : "dev"
const prefix = `inline:${environment}`
const clusterChannel = `${prefix}:internal:v1:cluster`
const inboxChannel = (bootId: string) => `${prefix}:internal:v1:boot:${bootId}`
const log = new Log("internalMessaging.service")

type Handler<K extends InternalEvent["kind"]> = (envelope: Extract<InternalEnvelope, { event: { kind: K } }>) => void | Promise<void>
type PrivateTarget = Extract<InternalEnvelope, { event: { kind: "PrivateRequest" } }>["target"]
type PrivateRequestPayload = Extract<InternalEvent, { kind: "PrivateRequest" }>["payload"]
type PrivateReplyPayload = Extract<InternalEvent, { kind: "PrivateReply" }>["payload"]
type PrivateRequestEnvelope = Extract<InternalEnvelope, { event: { kind: "PrivateRequest" } }>
type DurableUpdatesAvailableEnvelope = Extract<InternalEnvelope, { event: { kind: "DurableUpdatesAvailable" } }>
type InboundHandler = (envelope: InternalEnvelope) => void | Promise<void>
type InboundTask = {
  envelope: InternalEnvelope
  readonly handlers: readonly InboundHandler[]
  readonly generation: number
  readonly lane: "normal" | "private" | "revocation"
  readonly durableBucketKey?: string
  readonly revocationKey?: string
}
type DurableBucketState = {
  active?: InboundTask
  pending?: InboundTask
}
type PrivatePending = {
  target: PrivateTarget
  origin: PrivateTarget
  requestId: bigint
  deadlineMs: number
  resolve: (result: { status: "replied"; payload: PrivateReplyPayload } | { status: "unavailable" }) => void
  timer: ReturnType<typeof setTimeout>
}

/** All event kinds and their handlers share this aggregate execution limit. */
export const maxConcurrentInboundEvents = 32
/** Four workers remain available even during a targeted-private traffic burst. */
export const maxReservedRevocationInboundWorkers = 4
/** Targeted private/session traffic has its own eight-worker budget. */
export const maxReservedPrivateInboundWorkers = 8
/** Normal work can use the remaining twenty workers. */
export const maxReservedPriorityInboundWorkers =
  maxReservedRevocationInboundWorkers + maxReservedPrivateInboundWorkers
/** Bounded queued events; active workers are counted separately. */
export const maxPendingInboundEvents = 4_096
/** Revocations retain a dedicated queue even when private traffic saturates. */
export const maxReservedRevocationInboundEvents = 64
/** Private/session traffic retains this many pending entries. */
export const maxReservedPrivateInboundEvents = 192
/** Reserved queue capacity prevents ordinary fanout from starving critical work. */
export const maxReservedPriorityInboundEvents =
  maxReservedRevocationInboundEvents + maxReservedPrivateInboundEvents

export class InternalMessagingService {
  readonly bootId = randomUUID()
  private transport: InternalRedisTransport
  private readonly url: string | undefined
  private readonly handlers = new Map<InternalEvent["kind"], Set<(envelope: InternalEnvelope) => void | Promise<void>>>()
  private readonly recentlySeen = new Map<string, number>()
  private readonly privatePending = new Map<string, PrivatePending>()
  private readonly inboundPrivate = new Map<string, PrivateRequestEnvelope>()
  private readonly continuityListeners = new Set<() => void>()
  private readonly readyListeners = new Set<() => void>()
  private readonly inboundRevocations = [] as InboundTask[]
  private readonly inboundTargeted = [] as InboundTask[]
  private readonly inboundNormal = [] as InboundTask[]
  /** Each bucket owns at most one running hint and one mergeable successor. */
  private readonly durableBuckets = new Map<string, DurableBucketState>()
  /** A revocation is idempotent; retain one task per authenticated session. */
  private readonly revocationsBySession = new Map<string, InboundTask>()
  private readonly activeInbound = new Set<Promise<void>>()
  private readonly inboundIdleWaiters = new Set<() => void>()
  private invalidFrames = 0
  private droppedFrames = 0
  private deliveredFrames = 0
  private droppedInboundEvents = 0
  private droppedRevocationEvents = 0
  private coalescedRevocationEvents = 0
  private inboundActiveCount = 0
  private inboundNormalActiveCount = 0
  private inboundPriorityActiveCount = 0
  private inboundRevocationActiveCount = 0
  private inboundPrivateActiveCount = 0
  private inboundAccepting = false
  private inboundGeneration = 0
  private inboundTransportGeneration = 0
  private degradedSharedLimitTotal = 0
  private started = false
  private startPromise: Promise<void> | undefined
  private lastRevocationSaturationWarningAt = 0

  constructor(url: string | undefined = process.env["REDIS_URL"] ?? process.env["VALKEY_URL"]) {
    this.url = url
    this.transport = new InternalRedisTransport(url)
    this.attachTransportObservers()
  }

  get health(): BrokerHealth { return this.transport.health }
  get diagnostics() {
    return {
      invalidFrames: this.invalidFrames,
      droppedFrames: this.droppedFrames,
      deliveredFrames: this.deliveredFrames,
      droppedInboundEvents: this.droppedInboundEvents,
      droppedRevocationEvents: this.droppedRevocationEvents,
      coalescedRevocationEvents: this.coalescedRevocationEvents,
      inboundActive: this.inboundActiveCount,
      inboundPriorityActive: this.inboundPriorityActiveCount,
      inboundRevocationActive: this.inboundRevocationActiveCount,
      inboundPrivateActive: this.inboundPrivateActiveCount,
      inboundPending: this.inboundRevocations.length + this.inboundTargeted.length + this.inboundNormal.length,
      degradedSharedLimitTotal: this.degradedSharedLimitTotal,
      health: this.health,
    }
  }

  async start(): Promise<void> {
    if (this.startPromise) {
      return this.startPromise
    }
    if (this.started) {
      if (!this.inboundAccepting) {
        this.inboundTransportGeneration = this.beginIncomingAdmission()
      }
      return
    }
    if (this.transport.health === "closed") {
      this.transport = new InternalRedisTransport(this.url)
      this.attachTransportObservers()
    }
    this.started = true
    const generation = this.beginIncomingAdmission()
    this.inboundTransportGeneration = generation
    const transport = this.transport
    const start = transport.start(
      [clusterChannel, inboxChannel(this.bootId)],
      (frame, channel) => this.receive(frame, channel, this.inboundTransportGeneration, transport),
    )
    this.startPromise = start
    try {
      await start
    } catch (error) {
      this.started = false
      this.stopIncomingAdmission()
      throw error
    } finally {
      if (this.startPromise === start) {
        this.startPromise = undefined
      }
    }
  }

  /** Stop accepting broker events and join admitted handler work before transport shutdown. */
  async stopIncoming(): Promise<void> {
    this.stopIncomingAdmission()
    await this.waitForIncomingWork()
  }

  async close(): Promise<void> {
    // Keep the broker pair alive until admitted private/revocation handlers
    // finish; their completion can legitimately publish a final reply.
    await this.stopIncoming()
    for (const [correlationId, pending] of this.privatePending) {
      clearTimeout(pending.timer)
      pending.resolve({ status: "unavailable" })
      this.privatePending.delete(correlationId)
    }
    this.inboundPrivate.clear()
    await this.transport.close()
    const start = this.startPromise
    if (start) {
      await Promise.allSettled([start])
    }
    this.started = false
  }
  onContinuityLost(listener: () => void): () => void { this.continuityListeners.add(listener); return () => this.continuityListeners.delete(listener) }
  onReady(listener: () => void): () => void { this.readyListeners.add(listener); return () => this.readyListeners.delete(listener) }

  private attachTransportObservers(): void {
    this.transport.onContinuityLost(() => {
      for (const listener of this.continuityListeners) {
        try { listener() } catch { /* one consumer cannot block recovery */ }
      }
    })
    this.transport.onReady(() => {
      for (const listener of this.readyListeners) {
        try { listener() } catch { /* one consumer cannot block readiness */ }
      }
    })
  }

  on<K extends InternalEvent["kind"]>(kind: K, handler: Handler<K>): () => void {
    let handlers = this.handlers.get(kind)
    if (!handlers) { handlers = new Set(); this.handlers.set(kind, handlers) }
    const callback = handler as (envelope: InternalEnvelope) => void | Promise<void>
    handlers.add(callback)
    return () => handlers?.delete(callback)
  }

  async publish(input: Delivery): Promise<BrokerPublication> {
    const envelope = {
      version: 1, eventId: randomUUID(), originBootId: this.bootId, ...input,
    } as InternalEnvelope
    const channel = envelope.target.kind === "connection" || envelope.target.kind === "session"
      ? inboxChannel(envelope.target.bootId)
      : clusterChannel
    return this.transport.publish(channel, encodeEnvelope(envelope))
  }

  async requestPrivate(input: {
    target: PrivateTarget
    origin: PrivateTarget
    requestId: bigint
    payload: PrivateRequestPayload
    timeoutMs?: number
  }): Promise<{ status: "replied"; payload: PrivateReplyPayload } | { status: "unavailable" }> {
    if (this.privatePending.size >= 128 || input.requestId <= 0n) return { status: "unavailable" }
    const correlationId = randomUUID()
    const deadlineMs = Date.now() + Math.min(10_000, Math.max(1, input.timeoutMs ?? 10_000))
    const response = new Promise<{ status: "replied"; payload: PrivateReplyPayload } | { status: "unavailable" }>((resolve) => {
      const timer = setTimeout(() => {
        this.privatePending.delete(correlationId)
        resolve({ status: "unavailable" })
      }, deadlineMs - Date.now())
      this.privatePending.set(correlationId, { ...input, deadlineMs, resolve, timer })
    })
    try {
      const outcome = await this.publish({
        target: input.target,
        event: { kind: "PrivateRequest", correlationId, originBootId: this.bootId,
          originConnection: input.origin, requestId: input.requestId, deadlineMs, payload: input.payload },
      })
      if (outcome.status === "unavailable" || outcome.subscribers === 0) this.failPrivate(correlationId)
    } catch (error) {
      this.failPrivate(correlationId)
      throw error
    }
    return response
  }

  registerInboundPrivate(envelope: PrivateRequestEnvelope): boolean {
    for (const [key, request] of this.inboundPrivate) {
      if (request.event.deadlineMs <= Date.now()) this.inboundPrivate.delete(key)
    }
    if (envelope.target.bootId !== this.bootId || envelope.event.deadlineMs <= Date.now() || this.inboundPrivate.size >= 256) return false
    const key = `${envelope.event.payload.kind}:${envelope.event.requestId}`
    if (this.inboundPrivate.has(key)) return false
    this.inboundPrivate.set(key, envelope)
    return true
  }

  hasInboundPrivate(kind: "botSettings" | "botFilesystem", requestId: bigint): boolean {
    const key = `${kind}:${requestId}`
    const envelope = this.inboundPrivate.get(key)
    if (!envelope) return false
    if (envelope.event.deadlineMs <= Date.now()) {
      this.inboundPrivate.delete(key)
      return false
    }
    return true
  }

  /** Remove only the exact envelope whose delivery to the bot failed. */
  forgetInboundPrivate(envelope: PrivateRequestEnvelope): void {
    const key = `${envelope.event.payload.kind}:${envelope.event.requestId}`
    if (this.inboundPrivate.get(key) === envelope) {
      this.inboundPrivate.delete(key)
    }
  }

  async replyInboundPrivate(input: {
    kind: "botSettings" | "botFilesystem"
    requestId: bigint
    actualConnectionId: string
    actualSessionId: number
    botUserId: number
    payload: PrivateReplyPayload
  }): Promise<boolean> {
    const key = `${input.kind}:${input.requestId}`
    const envelope = this.inboundPrivate.get(key)
    if (!envelope) return false
    const { target, event } = envelope
    if (target.connectionId !== input.actualConnectionId || target.sessionId !== input.actualSessionId || target.userId !== input.botUserId || event.deadlineMs <= Date.now()) return false
    this.inboundPrivate.delete(key)
    const outcome = await this.publish({
      target: event.originConnection,
      event: { kind: "PrivateReply", correlationId: event.correlationId, originBootId: event.originBootId,
        replyFromConnectionId: target.connectionId, requestId: event.requestId,
        deadlineMs: event.deadlineMs, payload: input.payload },
    })
    return outcome.status === "published"
  }

  private failPrivate(correlationId: string): void {
    const pending = this.privatePending.get(correlationId)
    if (!pending) return
    clearTimeout(pending.timer)
    this.privatePending.delete(correlationId)
    pending.resolve({ status: "unavailable" })
  }

  private beginIncomingAdmission(): number {
    this.inboundGeneration += 1
    this.inboundAccepting = true
    return this.inboundGeneration
  }

  private stopIncomingAdmission(): void {
    this.inboundGeneration += 1
    this.inboundAccepting = false
    this.inboundRevocations.length = 0
    this.inboundTargeted.length = 0
    this.inboundNormal.length = 0
    this.durableBuckets.clear()
    this.revocationsBySession.clear()
    this.notifyInboundIdle()
  }

  /** Join active and queued broker handlers. Call stopIncoming() before this during shutdown. */
  async waitForIncomingWork(): Promise<void> {
    if (this.activeInbound.size === 0 && this.inboundRevocations.length === 0 &&
      this.inboundTargeted.length === 0 && this.inboundNormal.length === 0) {
      return
    }
    await new Promise<void>((resolve) => this.inboundIdleWaiters.add(resolve))
  }

  private notifyInboundIdle(): void {
    if (this.activeInbound.size !== 0 || this.inboundRevocations.length !== 0 ||
      this.inboundTargeted.length !== 0 || this.inboundNormal.length !== 0) return
    for (const resolve of this.inboundIdleWaiters) resolve()
    this.inboundIdleWaiters.clear()
  }

  private receive(
    frame: string,
    channel: string,
    generation = this.inboundGeneration,
    transport?: InternalRedisTransport,
  ): void {
    let envelope: InternalEnvelope
    try { envelope = decodeEnvelope(frame) } catch { this.invalidFrames++; return }
    if (envelope.originBootId === this.bootId) return
    if ((envelope.target.kind === "connection" || envelope.target.kind === "session") &&
      (channel !== inboxChannel(this.bootId) || envelope.target.bootId !== this.bootId)) {
      this.droppedFrames++; return
    }
    if (envelope.target.kind !== "connection" && envelope.target.kind !== "session" && channel !== clusterChannel) { this.droppedFrames++; return }
    if (!this.inboundAccepting || generation !== this.inboundGeneration ||
      (transport !== undefined && transport !== this.transport)) {
      this.droppedInboundEvents++
      return
    }
    if (envelope.event.kind === "PrivateReply" && envelope.target.kind === "connection") {
      const pending = this.privatePending.get(envelope.event.correlationId)
      if (!pending || envelope.event.originBootId !== this.bootId ||
        envelope.originBootId !== pending.target.bootId ||
        envelope.event.replyFromConnectionId !== pending.target.connectionId ||
        envelope.event.requestId !== pending.requestId ||
        envelope.target.connectionId !== pending.origin.connectionId ||
        envelope.target.userId !== pending.origin.userId ||
        envelope.target.sessionId !== pending.origin.sessionId ||
        envelope.event.deadlineMs !== pending.deadlineMs) { this.droppedFrames++; return }
      clearTimeout(pending.timer)
      this.privatePending.delete(envelope.event.correlationId)
      pending.resolve({ status: "replied", payload: envelope.event.payload })
      return
    }
    const now = Date.now()
    if (this.recentlySeen.has(envelope.eventId)) return
    this.recentlySeen.set(envelope.eventId, now)
    if (this.recentlySeen.size > 2048) {
      for (const [id, timestamp] of this.recentlySeen) {
        if (timestamp < now - 60_000 || this.recentlySeen.size > 2048) this.recentlySeen.delete(id)
        else break
      }
    }
    this.deliveredFrames++
    const handlers = [...(this.handlers.get(envelope.event.kind) ?? [])]
    if (handlers.length === 0) return
    this.enqueueInbound({
      envelope,
      handlers,
      generation,
      lane: this.inboundLane(envelope),
      durableBucketKey: this.durableBucketKey(envelope),
      revocationKey: this.revocationKey(envelope),
    })
  }

  private inboundLane(envelope: InternalEnvelope): InboundTask["lane"] {
    if (envelope.event.kind === "SessionRevoked") return "revocation"
    if (envelope.event.kind === "PrivateRequest" || envelope.target.kind === "connection" ||
      envelope.target.kind === "session") return "private"
    return "normal"
  }

  private revocationKey(envelope: InternalEnvelope): string | undefined {
    return envelope.event.kind === "SessionRevoked"
      ? `${envelope.event.userId}:${envelope.event.sessionId}`
      : undefined
  }

  private durableBucketKey(envelope: InternalEnvelope): string | undefined {
    if (envelope.event.kind !== "DurableUpdatesAvailable") return undefined
    const { bucket } = envelope.event
    return bucket.kind === "chat" ? `chat:${bucket.chatId}` :
      bucket.kind === "space" ? `space:${bucket.spaceId}` : `user:${bucket.userId}`
  }

  private enqueueInbound(task: InboundTask): void {
    if (!this.inboundAccepting || task.generation !== this.inboundGeneration) {
      this.droppedInboundEvents++
      return
    }
    if (task.lane === "revocation" && task.revocationKey) {
      if (this.revocationsBySession.has(task.revocationKey)) {
        this.coalescedRevocationEvents++
        return
      }
      if (!this.canQueueRevocationInbound()) {
        this.droppedInboundEvents++
        this.recordRevocationSaturation()
        return
      }
      this.revocationsBySession.set(task.revocationKey, task)
      this.inboundRevocations.push(task)
    } else if (task.durableBucketKey) {
      const state = this.durableBuckets.get(task.durableBucketKey)
      if (state?.pending) {
        this.mergeDurableTask(state.pending, task)
        return
      }
      if (!this.canQueueNormalInbound()) {
        this.droppedInboundEvents++
        return
      }
      if (state) state.pending = task
      else this.durableBuckets.set(task.durableBucketKey, { pending: task })
      this.inboundNormal.push(task)
    } else if (task.lane === "private") {
      if (!this.canQueuePrivateInbound()) {
        this.droppedInboundEvents++
        return
      }
      this.inboundTargeted.push(task)
    } else {
      if (!this.canQueueNormalInbound()) {
        this.droppedInboundEvents++
        return
      }
      this.inboundNormal.push(task)
    }
    this.pumpInbound()
  }

  private canQueueNormalInbound(): boolean {
    return this.inboundRevocations.length + this.inboundTargeted.length + this.inboundNormal.length <
      maxPendingInboundEvents - maxReservedPriorityInboundEvents
  }

  private canQueuePrivateInbound(): boolean {
    return this.inboundTargeted.length < maxReservedPrivateInboundEvents &&
      this.inboundRevocations.length + this.inboundTargeted.length + this.inboundNormal.length < maxPendingInboundEvents
  }

  private canQueueRevocationInbound(): boolean {
    return this.inboundRevocations.length < maxReservedRevocationInboundEvents &&
      this.inboundRevocations.length + this.inboundTargeted.length + this.inboundNormal.length < maxPendingInboundEvents
  }

  private recordRevocationSaturation(): void {
    this.droppedRevocationEvents++
    if (Date.now() - this.lastRevocationSaturationWarningAt < 60_000) return
    this.lastRevocationSaturationWarningAt = Date.now()
    // Session authority rechecks database state on its bounded reconciliation
    // cadence. Saturation is observable because Redis is a prompt hint, not a
    // guarantee of immediate cross-process session termination.
    log.warn("Inbound session-revocation queue saturated; authority reconciliation remains the fallback", {
      capacity: maxReservedRevocationInboundEvents,
    })
  }

  private mergeDurableTask(current: InboundTask, next: InboundTask): void {
    const currentEnvelope = current.envelope as DurableUpdatesAvailableEnvelope
    const nextEnvelope = next.envelope as DurableUpdatesAvailableEnvelope
    const currentEvent = currentEnvelope.event
    const nextEvent = nextEnvelope.event
    const highest = nextEvent.frontier > currentEvent.frontier ? nextEvent : currentEvent
    const hasSameDeliveryMetadata =
      nextEvent.senderUserId === currentEvent.senderUserId &&
      nextEvent.excludeSessionId === currentEvent.excludeSessionId
    // A coalesced frontier represents every update in the bucket up through
    // that sequence. An exclusion from only one of those updates could cause
    // its session to miss another one, including an older arrival after a
    // newer frontier. Preserve it only when every merged event agrees.
    current.envelope = {
      ...currentEnvelope,
      event: {
        kind: "DurableUpdatesAvailable",
        bucket: highest.bucket,
        frontier: highest.frontier,
        ...(hasSameDeliveryMetadata && highest.senderUserId !== undefined
          ? { senderUserId: highest.senderUserId }
          : {}),
        ...(hasSameDeliveryMetadata && highest.excludeSessionId !== undefined
          ? { excludeSessionId: highest.excludeSessionId }
          : {}),
      },
    }
  }

  private pumpInbound(): void {
    while (this.inboundAccepting) {
      const task = this.nextInboundTask()
      if (!task) return
      if (task.durableBucketKey) {
        const state = this.durableBuckets.get(task.durableBucketKey)
        if (state?.pending === task) {
          state.pending = undefined
          state.active = task
        }
      }
      this.startInboundTask(task)
    }
  }

  private nextInboundTask(): InboundTask | undefined {
    if (this.inboundRevocations.length > 0 &&
      this.inboundRevocationActiveCount < maxReservedRevocationInboundWorkers &&
      this.inboundActiveCount < maxConcurrentInboundEvents) {
      return this.inboundRevocations.shift()
    }
    if (this.inboundTargeted.length > 0 &&
      this.inboundPrivateActiveCount < maxReservedPrivateInboundWorkers &&
      this.inboundActiveCount < maxConcurrentInboundEvents) {
      return this.inboundTargeted.shift()
    }
    if (this.inboundNormal.length > 0 && this.inboundNormalActiveCount <
      maxConcurrentInboundEvents - maxReservedPriorityInboundWorkers &&
      this.inboundActiveCount < maxConcurrentInboundEvents) {
      // A durable successor waits for the previous event from its bucket, but
      // a blocked bucket cannot head-of-line block unrelated buckets.
      const index = this.inboundNormal.findIndex((candidate) => !candidate.durableBucketKey ||
        !this.durableBuckets.get(candidate.durableBucketKey)?.active)
      return index < 0 ? undefined : this.inboundNormal.splice(index, 1)[0]
    }
    return undefined
  }

  private startInboundTask(task: InboundTask): void {
    this.inboundActiveCount++
    if (task.lane === "normal") this.inboundNormalActiveCount++
    else {
      this.inboundPriorityActiveCount++
      if (task.lane === "revocation") this.inboundRevocationActiveCount++
      else this.inboundPrivateActiveCount++
    }
    let tracked: Promise<void>
    tracked = this.runInboundTask(task).finally(() => {
      this.activeInbound.delete(tracked)
      this.inboundActiveCount--
      if (task.lane === "normal") this.inboundNormalActiveCount--
      else {
        this.inboundPriorityActiveCount--
        if (task.lane === "revocation") this.inboundRevocationActiveCount--
        else this.inboundPrivateActiveCount--
      }
      this.finishDurableTask(task)
      this.finishRevocationTask(task)
      this.pumpInbound()
      this.notifyInboundIdle()
    })
    this.activeInbound.add(tracked)
  }

  private finishDurableTask(task: InboundTask): void {
    if (!task.durableBucketKey) return
    const state = this.durableBuckets.get(task.durableBucketKey)
    if (!state || state.active !== task) return
    state.active = undefined
    if (!state.pending) this.durableBuckets.delete(task.durableBucketKey)
  }

  private finishRevocationTask(task: InboundTask): void {
    if (!task.revocationKey) return
    if (this.revocationsBySession.get(task.revocationKey) === task) {
      this.revocationsBySession.delete(task.revocationKey)
    }
  }

  private async runInboundTask(task: InboundTask): Promise<void> {
    if (!this.inboundAccepting || task.generation !== this.inboundGeneration) return
    for (const handler of task.handlers) {
      // Close waits for a currently running handler, but must not begin a
      // later handler from the same event after it has stopped admission.
      if (!this.inboundAccepting || task.generation !== this.inboundGeneration) return
      try {
        await handler(task.envelope)
      } catch {
        this.droppedFrames++
      }
    }
  }

  /** Best-effort short-lived activity: never queued while disconnected. */
  recordDesktopActivity(userId: number, chatId: number): Promise<boolean> {
    return this.transport.setExpiring(`${prefix}:desktop-active:${userId}:${chatId}`, "1", 15_000)
  }

  /** undefined means unavailable and must be treated as allow-push. */
  async hasDesktopActivity(userId: number, chatId: number): Promise<boolean | undefined> {
    const result = await this.transport.get(`${prefix}:desktop-active:${userId}:${chatId}`)
    return result === undefined ? undefined : result !== null
  }

  /** Ephemeral values used by the connection directory and bot presence. */
  getEphemeral(key: string): Promise<string | null | undefined> { return this.transport.get(`${prefix}:${key}`) }
  setEphemeral(key: string, value: string, ttlMs: number): Promise<boolean> { return this.transport.setExpiring(`${prefix}:${key}`, value, ttlMs) }
  deleteEphemeral(key: string): Promise<boolean> { return this.transport.delete(`${prefix}:${key}`) }
  sendCommand(name: string, args: string[]): Promise<unknown | undefined> { return this.transport.command(name, args) }
  key(suffix: string): string { return `${prefix}:${suffix}` }

  /** Selected ordinary service-wide limits use an atomic expiring counter. */
  async consumeSharedBudget(family: "http", identity: string, windowMs: number): Promise<{ count: number; remainingMs: number } | undefined> {
    const hash = createHash("sha256").update(identity).digest("hex")
    const key = this.key(`limit:${family}:${hash}`)
    const result = await this.transport.command("EVAL", [
      "local count = redis.call('INCR', KEYS[1]); if count == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[1]) end; return {count, redis.call('PTTL', KEYS[1])}",
      "1", key, String(windowMs),
    ])
    if (!Array.isArray(result) || result.length !== 2) { this.degradedSharedLimitTotal++; return undefined }
    const count = Number(result[0])
    const remainingMs = Number(result[1])
    if (!Number.isSafeInteger(count) || !Number.isSafeInteger(remainingMs) || remainingMs < 0) {
      this.degradedSharedLimitTotal++
      return undefined
    }
    return { count, remainingMs }
  }

  async refundSharedBudget(family: "http", identity: string): Promise<void> {
    const hash = createHash("sha256").update(identity).digest("hex")
    await this.transport.command("EVAL", [
      "local value = redis.call('GET', KEYS[1]); if value and tonumber(value) > 0 then redis.call('DECR', KEYS[1]) end; return 1",
      "1", this.key(`limit:${family}:${hash}`),
    ])
  }
}

export const internalMessaging = new InternalMessagingService()
