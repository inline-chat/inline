import { randomUUID } from "node:crypto"
import { Update, UpdatesPayload } from "@inline-chat/protocol/core"
import { RealtimeDelivery } from "@in/server/protocol/server"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { connectionManager } from "@in/server/ws/connections"
import { isDistributedRealtimeEnabled } from "./config"
import { internalMessaging, type InternalMessagingService } from "./service"
import type { InternalEnvelope } from "./schemas"
import { authorizeLiveRecipients, positiveId } from "./liveAuthorization"
import { recentRealtimeRepair, updateBucket } from "./recentRepair"
import { Log } from "@in/server/utils/log"

export const MAX_LIVE_UPDATE_BYTES = 256 * 1024
export const MAX_LIVE_QUEUE_BYTES = 4 * 1024 * 1024
export const MAX_LIVE_QUEUE_ENTRIES = 512
export const MAX_LIVE_RECIPIENTS = 256
const ownedElsewhere = new Set<Update["update"]["oneofKind"]>([
  undefined, "updateComposeAction", "updateUserStatus", "botPresence", "chatSkipPts",
  "chatHasNewUpdates", "spaceHasNewUpdates", "userHasNewUpdates",
])
const log = new Log("internalMessaging.liveDelivery")
type LiveEnvelope = Extract<InternalEnvelope, { event: { kind: "RealtimeDelivery" } }>
type Pending = { bytes: Buffer; userIds: number[]; spaceId?: number; skipSessionId?: number; expiresAt: number; partition: number }

export function decodeLiveDelivery(envelope: LiveEnvelope, now = Date.now()): RealtimeDelivery {
  const payload = RealtimeDelivery.fromBinary(Encryption2.decryptBinary(Buffer.from(envelope.event.payload, "base64")))
  if (payload.version !== 1 || payload.eventId !== envelope.eventId || payload.originBootId !== envelope.originBootId ||
    payload.partition !== envelope.event.partition ||
    payload.expiresAtMs <= BigInt(now) || payload.expiresAtMs > BigInt(now + 10_000) ||
    payload.updates.length === 0 || payload.updates.length > 64 ||
    payload.updates.some((update) => ownedElsewhere.has(update.update.oneofKind)) ||
    payload.userIds.length > MAX_LIVE_RECIPIENTS ||
    (payload.spaceId === undefined) === (payload.userIds.length === 0)) {
    throw new Error("Invalid realtime delivery envelope")
  }
  for (const id of payload.userIds) positiveId(id)
  if (payload.userIds.some((id) => deliveryPartition(payload.updates, Number(id)) !== payload.partition) ||
    (payload.spaceId !== undefined && Number(payload.spaceId) % 16 !== payload.partition)) {
    throw new Error("Invalid realtime ordering lane")
  }
  if (new Set(payload.userIds).size !== payload.userIds.length) throw new Error("Duplicate realtime recipients")
  if (payload.spaceId !== undefined) positiveId(payload.spaceId)
  if (payload.skipSessionId !== undefined) positiveId(payload.skipSessionId)
  return payload
}

export type LiveDeliveryRuntime = {
  enabled: () => boolean
  receive: (payload: RealtimeDelivery) => Promise<void>
}

/** Local fanout never awaits this bounded, FIFO, best-effort publication owner. */
export class LiveRealtimeDelivery {
  private queue: Pending[] = []
  private readonly lastByPartition = new Map<number, Pending>()
  private bytes = 0
  private task: Promise<void> | undefined
  private accepting = false
  private unsubscribe = () => {}
  private dropped = 0
  private published = 0
  private received = 0
  private lastWarningAt = 0
  constructor(private readonly service: InternalMessagingService = internalMessaging,
    private readonly runtime: LiveDeliveryRuntime = { enabled: isDistributedRealtimeEnabled, receive: receiveLiveDelivery }) {}

  get diagnostics() { return { queued: this.queue.length, queuedBytes: this.bytes, dropped: this.dropped, published: this.published, received: this.received } }
  start(): void {
    if (this.accepting || !this.runtime.enabled()) return
    this.accepting = true
    this.unsubscribe = this.service.on("RealtimeDelivery", async (envelope) => {
      try {
        await this.runtime.receive(decodeLiveDelivery(envelope))
        this.received++
      } catch { this.drop("invalid_or_failed_delivery") }
    })
  }
  async stop(): Promise<void> {
    this.accepting = false
    await this.drain()
    this.unsubscribe()
  }
  async drain(): Promise<void> { while (this.task) await this.task }

  toUser(userId: number, updates: readonly Update[], skipSessionId?: number): void {
    this.enqueue({ userIds: [userId], skipSessionId }, updates)
  }
  toSpace(spaceId: number, updates: readonly Update[]): void {
    this.enqueue({ userIds: [], spaceId }, updates)
  }
  private enqueue(target: Pick<Pending, "userIds" | "spaceId" | "skipSessionId">, updates: readonly Update[]): void {
    if (!this.accepting || !this.runtime.enabled() || this.service.health !== "ready") return
    const selected = updates.filter((update) => !ownedElsewhere.has(update.update.oneofKind))
    if (selected.length === 0) return
    try {
      if (selected.length > 64) throw new Error("Realtime update batch too large")
      const bytes = Buffer.from(UpdatesPayload.toBinary({ updates: selected }))
      if (bytes.length > MAX_LIVE_UPDATE_BYTES) throw new Error("Realtime update too large")
      const expiresAt = Date.now() + (selected.every((u) => u.update.oneofKind === "updateReaction" || u.update.oneofKind === "deleteReaction") ? 2_000 : 5_000)
      const partition = deliveryPartition(selected, target.userIds[0] ?? 0, target.spaceId)
      const previous = this.lastByPartition.get(partition)
      // Adjacent identical projections within one ordered lane may share a
      // publication. Events in other lanes do not affect this lane's order.
      if (target.spaceId === undefined && previous?.spaceId === undefined && previous !== undefined &&
        previous.skipSessionId === target.skipSessionId && previous.userIds.length < MAX_LIVE_RECIPIENTS &&
        !previous.userIds.includes(target.userIds[0]!) && previous.bytes.equals(bytes)) {
        if (this.bytes + 8 > MAX_LIVE_QUEUE_BYTES) { this.drop("queue_full"); return }
        previous.userIds.push(target.userIds[0]!)
        this.bytes += 8
        return
      }
      const size = bytes.length + target.userIds.length * 8
      if (this.queue.length >= MAX_LIVE_QUEUE_ENTRIES || this.bytes + size > MAX_LIVE_QUEUE_BYTES) { this.drop("queue_full"); return }
      const pending = { ...target, bytes, expiresAt, partition }
      this.queue.push(pending)
      this.lastByPartition.set(partition, pending)
      this.bytes += size
      this.pump()
    } catch { this.drop("unencodable_or_oversized") }
  }
  private drop(reason: string): void {
    this.dropped++
    if (Date.now() - this.lastWarningAt < 60_000) return
    this.lastWarningAt = Date.now()
    log.warn("Live realtime publication degraded; durable discovery remains available", { reason, ...this.diagnostics })
  }
  private pump(): void {
    if (this.task || this.queue.length === 0) return
    this.task = Promise.resolve().then(() => this.flush()).finally(() => {
      this.task = undefined
      this.pump()
    })
  }
  private async flush(): Promise<void> {
    while (this.queue.length > 0) {
      const next = this.queue.shift()!
      if (this.lastByPartition.get(next.partition) === next) this.lastByPartition.delete(next.partition)
      this.bytes -= next.bytes.length + next.userIds.length * 8
      if (next.expiresAt <= Date.now() || this.service.health !== "ready") { this.drop("expired_or_unavailable"); continue }
      try {
        const eventId = randomUUID()
        const updates = UpdatesPayload.fromBinary(next.bytes).updates
        const partition = next.partition
        const payload = RealtimeDelivery.toBinary({
          version: 1, originBootId: this.service.bootId, eventId, expiresAtMs: BigInt(next.expiresAt),
          userIds: next.userIds.map(BigInt), spaceId: next.spaceId === undefined ? undefined : BigInt(next.spaceId),
          skipSessionId: next.skipSessionId === undefined ? undefined : BigInt(next.skipSessionId),
          updates, partition,
        })
        const result = await this.service.publish({ target: { kind: "cluster" }, event: {
          kind: "RealtimeDelivery", partition, payload: Encryption2.encrypt(payload).toString("base64"),
        } }, eventId)
        if (result.status === "published") this.published++
        else this.drop("broker_unavailable")
      } catch { this.drop("publication_failed") }
    }
  }
}

/** Observe only a handoff covering every surviving socket in this admission. */
export function observeLocalDelivery(userId: number, updates: Update[], epoch: number, accepted: number, skipSessionId?: number, peerChatIds?: ReadonlyMap<number, number>): void {
  if (!isDistributedRealtimeEnabled() || connectionManager.getUserConnectionEpoch(userId) !== epoch) return
  // An explicit exclusion means this exact session receives the update in
  // its mutation RPC result. It has the same repair semantics as a handoff.
  const excluded = skipSessionId !== undefined && connectionManager.getUserConnections(userId).some((c) => c.sessionId === skipSessionId)
  if (accepted <= 0 && !excluded) return
  recentRealtimeRepair.observeDelivery(userId, updates, epoch, peerChatIds)
}

/** Chat/user events use the recipient (including legacy DM aliases). Space
 * events share their space lane with broadcast profile updates. */
export function deliveryPartition(updates: readonly Update[], userId: number, spaceId?: number): number {
  if (spaceId !== undefined) return spaceId % 16
  for (const update of updates) {
    const bucket = updateBucket(userId, update)
    if (bucket?.kind === "space") return bucket.spaceId % 16
  }
  return userId % 16
}

async function receiveLiveDelivery(payload: RealtimeDelivery): Promise<void> {
  const candidates = payload.spaceId === undefined ? payload.userIds.map(Number)
    : connectionManager.getAuthenticatedUserIds()
  const local = candidates.filter((id) => connectionManager.getUserConnections(id).length > 0)
  const { RealtimeUpdates } = await import("@in/server/realtime/message")
  for (let offset = 0; offset < local.length; offset += MAX_LIVE_RECIPIENTS) {
    const batch = local.slice(offset, offset + MAX_LIVE_RECIPIENTS)
    const epochs = new Map(batch.map((id) => [id, connectionManager.getUserConnectionEpoch(id)]))
    // A space target must not let a valid envelope move unrelated personal
    // updates to every member. Current senders only broadcast space profiles.
    if (payload.spaceId !== undefined && payload.updates.some((u) =>
      u.update.oneofKind !== "spaceProfile" || u.update.spaceProfile.spaceId !== payload.spaceId)) {
      throw new Error("Unsupported space broadcast")
    }
    const peerChatIds = new Map<number, Map<number, number>>()
    const recipients = await authorizeLiveRecipients(payload.updates, batch, peerChatIds)
    if (payload.expiresAtMs <= BigInt(Date.now())) return
    // Raw transport submission is synchronous. Start the entire bounded batch
    // before awaiting results, preserving the final authority handoff boundary.
    await Promise.all(recipients.map(async (userId) => {
      // New admissions use their own normal bootstrap/recovery. Never let an
      // authorization begun before an admission mark its sockets as current.
      if (connectionManager.getUserConnectionEpoch(userId) !== epochs.get(userId)) return
      const skipSessionId = payload.skipSessionId === undefined ? undefined : Number(payload.skipSessionId)
      const accepted = await RealtimeUpdates.pushToUserWithDelivery(userId, payload.updates, { skipSessionId })
      observeLocalDelivery(userId, payload.updates, epochs.get(userId)!, accepted, skipSessionId, peerChatIds.get(userId))
    }))
  }
}

export const liveRealtimeDelivery = new LiveRealtimeDelivery()
