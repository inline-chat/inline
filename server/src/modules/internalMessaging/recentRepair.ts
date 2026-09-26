import type { Peer, Update } from "@inline-chat/protocol/core"
import { RecentRealtimeBuckets, RECENT_REALTIME_BUCKET_TTL_MS, type RecentRealtimeBucketCursor } from "@in/server/db/models/recentRealtimeBuckets"
import type { RecentRealtimeBucket } from "@in/server/db/schema/recentRealtimeBuckets"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { connectionManager } from "@in/server/ws/connections"
import { isDistributedRealtimeEnabled } from "./config"
import type { DurableBucket, DurableReference } from "./durable"
import { connectedUserRepair, deliverTargetedBucketHint, emitUserHasNewUpdates, replayCurrentUserUpdate, type CurrentUserReplayResult, type TargetedRepairControls } from "./repair"
import { ChatId, SpaceId, UserId } from "@in/server/core/schema/identifiers"
import { Log } from "@in/server/utils/log"

const POLL_MS = 1_000
const CATCHUP_POLL_MS = 100
const LIVE_GRACE_MS = 1_000
const CLEANUP_MS = 5_000
const MAX_PENDING = 4_096
const MAX_RECEIPTS = 16_384
const MAX_REPAIRS_PER_TICK = 16
const MAX_CONCURRENT_REPAIRS = 4
const log = new Log("internalMessaging.recentRepair")

type Receipt = { seq: number; epoch: number; at: number }
type Pending = { bucket: DurableBucket; frontier: number; requestedAt: number; dueAt: number }
type Settled = { frontier: number; generation: number; at: number }
type PeerAlias = { chatId: number; at: number }

export type RecentRepairRuntime = {
  enabled: () => boolean
  now: () => number
  connectedUsers: () => number[]
  epoch: (userId: number) => number
  readPage: (input: { after?: RecentRealtimeBucketCursor; limit: number }) => Promise<RecentRealtimeBucket[]>
  cleanup: () => Promise<number>
  hintBucket: (input: DurableReference, controls: TargetedRepairControls) => Promise<void>
  hintUser: (userId: number, frontier: number, current: () => boolean) => Promise<number>
  replayUser: (userId: number, frontier: number, current: () => boolean) => Promise<CurrentUserReplayResult>
  fallbackUser: (userId: number, frontier: number) => Promise<void>
  reconcile: () => void
}

const runtime: RecentRepairRuntime = {
  enabled: isDistributedRealtimeEnabled,
  now: Date.now,
  connectedUsers: () => connectionManager.getAuthenticatedUserIds(),
  epoch: (userId) => connectionManager.getUserConnectionEpoch(userId),
  readPage: (input) => RecentRealtimeBuckets.readPage(input),
  cleanup: () => RecentRealtimeBuckets.cleanupExpired(),
  hintBucket: (event, controls) => deliverTargetedBucketHint({
    kind: "DurableUpdatesAvailable", frontier: event.frontier,
    bucket: brandedBucket(event.bucket),
  }, controls),
  hintUser: emitUserHasNewUpdates,
  replayUser: replayCurrentUserUpdate,
  fallbackUser: (userId, frontier) => connectedUserRepair.observeBucket({
    kind: "DurableUpdatesAvailable", bucket: { kind: "user", userId: UserId.make(userId) }, frontier,
  }),
  reconcile: () => connectedUserRepair.observeConnectedUsers(),
}

const brandedBucket = (bucket: DurableBucket) => bucket.kind === "chat"
  ? { kind: "chat" as const, chatId: ChatId.make(bucket.chatId) }
  : bucket.kind === "space" ? { kind: "space" as const, spaceId: SpaceId.make(bucket.spaceId) }
    : { kind: "user" as const, userId: UserId.make(bucket.userId) }

const keyOf = (bucket: DurableBucket): string => bucket.kind === "chat" ? `c:${bucket.chatId}`
  : bucket.kind === "space" ? `s:${bucket.spaceId}` : `u:${bucket.userId}`
const positiveId = (id: bigint | number | undefined): number | undefined => {
  const value = Number(id)
  return Number.isSafeInteger(value) && value > 0 ? value : undefined
}

/** One bounded owner for grace, discovery, local hints and expiry. */
export class RecentRealtimeRepair {
  private active = false
  private timer: ReturnType<typeof setTimeout> | undefined
  private task: Promise<void> | undefined
  private cursor: RecentRealtimeBucketCursor | undefined
  private readonly pending = new Map<string, Pending>()
  private readonly receipts = new Map<string, Receipt>()
  private readonly settled = new Map<string, Settled>()
  private readonly peerAliases = new Map<string, PeerAlias>()
  private users = new Map<number, number>()
  private admissionGeneration = 0
  private nextCleanupAt = 0
  private lastReadAt: number | undefined
  private cycleStartedAt = 0
  private lastCycleMs = 0
  private overflowCount = 0
  private failures = 0
  private expiredRowsCleaned = 0
  private fullCleanupBatches = 0
  private lastBudgetWarningAt = Number.NEGATIVE_INFINITY

  constructor(private readonly source: RecentRepairRuntime = runtime) {}

  start(): void {
    if (this.active || !this.source.enabled()) return
    this.active = true
    this.cycleStartedAt = this.source.now()
    this.lastReadAt = this.source.now()
    this.schedule()
  }

  async stop(): Promise<void> {
    this.active = false
    if (this.timer) clearTimeout(this.timer)
    this.timer = undefined
    await this.task
    this.pending.clear()
    this.receipts.clear()
    this.settled.clear()
    this.peerAliases.clear()
    this.users.clear()
    this.cursor = undefined
    this.lastReadAt = undefined
  }

  get diagnostics() {
    const now = this.source.now()
    let oldestPendingAgeMs = 0
    for (const item of this.pending.values()) oldestPendingAgeMs = Math.max(oldestPendingAgeMs, now - item.requestedAt)
    return { active: this.active, pending: this.pending.size, receipts: this.receipts.size, peerAliases: this.peerAliases.size,
      oldestPendingAgeMs, scanCycleMs: this.users.size === 0 ? 0 : Math.max(this.lastCycleMs, this.active ? now - this.cycleStartedAt : 0),
      expiredRowsCleaned: this.expiredRowsCleaned, fullCleanupBatches: this.fullCleanupBatches,
      overflowCount: this.overflowCount, failures: this.failures }
  }

  observeBucket(event: DurableReference): void {
    if (!this.active || !Number.isInteger(event.frontier) || event.frontier <= 0) return
    const key = keyOf(event.bucket)
    const previous = this.pending.get(key)
    if (previous) {
      previous.frontier = Math.max(previous.frontier, event.frontier)
      return
    }
    if (this.pending.size >= MAX_PENDING) {
      this.overflowCount += 1
      // The database row is retained. A later fair scan re-admits this bucket;
      // fallback also covers old publishers which have no discovery row.
      this.source.reconcile()
      return
    }
    const now = this.source.now()
    this.pending.set(key, { bucket: event.bucket, frontier: event.frontier, requestedAt: now, dueAt: now + LIVE_GRACE_MS })
  }

  /** Receipts suppress only this exact observed frontier, never missing history. */
  observeDelivery(userId: number, updates: Update[], expectedEpoch: number, peerChatIds?: ReadonlyMap<number, number>): void {
    if (!this.active || this.source.epoch(userId) !== expectedEpoch) return
    const peerLookup = { get: (peerId: number) => peerChatIds?.get(peerId) ?? this.knownPeerChatId(userId, peerId) }
    for (const update of updates) {
      const value = update.update
      const identified = value.oneofKind === "newMessage" ? value.newMessage.message
        : value.oneofKind === "editMessage" ? value.editMessage.message : undefined
      const identifiedChat = value.oneofKind === "newChat" ? value.newChat.chat
        : value.oneofKind === "chatOpen" ? value.chatOpen.chat
          : value.oneofKind === "chatMoved" ? value.chatMoved.chat : undefined
      const peer = identified?.peerId ?? identifiedChat?.peerId
      const chatId = positiveId(identified?.chatId ?? identifiedChat?.id)
      const peerId = peer?.type.oneofKind === "user" ? positiveId(peer.type.user.userId) : undefined
      if (peerId !== undefined && chatId !== undefined) {
        const key = `${userId}/${peerId}`
        if (!this.peerAliases.has(key) && this.peerAliases.size >= MAX_RECEIPTS) {
          this.peerAliases.delete(this.peerAliases.keys().next().value!)
        }
        this.peerAliases.set(key, { chatId, at: this.source.now() })
      }
      if (!Number.isInteger(update.seq) || (update.seq ?? 0) <= 0) continue
      const bucket = updateBucket(userId, update, peerLookup)
      if (bucket) this.recordReceipt(userId, bucket, update.seq!, expectedEpoch)
    }
  }

  /** An optimization only; absence never means a DM does not exist. */
  knownPeerChatId(userId: number, peerId: number): number | undefined {
    const alias = this.peerAliases.get(`${userId}/${peerId}`)
    return alias !== undefined && this.source.now() - alias.at < RECENT_REALTIME_BUCKET_TTL_MS ? alias.chatId : undefined
  }

  /** Also useful for deterministic scheduler tests; concurrent calls share ownership. */
  poll(): Promise<void> {
    if (!this.active) return Promise.resolve()
    if (this.task) return this.task
    const task = this.runPoll().catch((error) => {
      this.failures += 1
      log.warn("Recent realtime repair could not complete its bounded tick", { error })
    }).finally(() => { if (this.task === task) this.task = undefined })
    this.task = task
    return task
  }

  private schedule(): void {
    const now = this.source.now()
    const catchingUp = this.cursor !== undefined || [...this.pending.values()].some((item) => item.dueAt <= now)
    const delay = Math.min(catchingUp ? CATCHUP_POLL_MS : POLL_MS,
      Math.max(CATCHUP_POLL_MS, this.nextCleanupAt - now))
    this.timer = setTimeout(() => {
      this.timer = undefined
      void this.poll().finally(() => { if (this.active) this.schedule() })
    }, delay)
    this.timer.unref?.()
  }

  private async runPoll(): Promise<void> {
    const now = this.source.now()
    this.refreshUsers()
    this.prune(now)
    if (now >= this.nextCleanupAt) {
      const deleted = await this.source.cleanup()
      this.expiredRowsCleaned += deleted
      if (deleted >= 256) this.fullCleanupBatches += 1
      this.nextCleanupAt = now + (deleted >= 256 ? CATCHUP_POLL_MS : CLEANUP_MS)
      if (!this.active) return
    }
    if (this.users.size > 0) {
      const rows = await this.source.readPage({ after: this.cursor, limit: 256 })
      if (!this.active) return
      if (this.lastReadAt !== undefined && now - this.lastReadAt >= RECENT_REALTIME_BUCKET_TTL_MS) {
        this.cursor = undefined
        this.settled.clear()
        this.source.reconcile()
      }
      this.lastReadAt = now
      for (const row of rows) {
        const bucket: DurableBucket = row.bucket === UpdateBucket.Chat ? { kind: "chat", chatId: row.entityId }
          : row.bucket === UpdateBucket.Space ? { kind: "space", spaceId: row.entityId }
            : { kind: "user", userId: row.entityId }
        const completed = this.settled.get(keyOf(bucket))
        if (completed?.frontier === row.seq && completed.generation === this.admissionGeneration) continue
        this.observeBucket({ bucket, frontier: row.seq })
      }
      if (rows.length < 256) {
        this.cursor = undefined
        this.lastCycleMs = this.source.now() - this.cycleStartedAt
        this.cycleStartedAt = this.source.now()
        if (this.lastCycleMs >= RECENT_REALTIME_BUCKET_TTL_MS) this.source.reconcile()
      } else {
        const last = rows.at(-1)!
        this.cursor = { bucket: last.bucket, entityId: last.entityId }
      }
    } else {
      this.cursor = undefined
      this.pending.clear()
      this.lastReadAt = now
      this.lastCycleMs = 0
      this.cycleStartedAt = now
    }
    const work: [string, Pending][] = []
    for (const [key, item] of this.pending) {
      if (work.length >= MAX_REPAIRS_PER_TICK) break
      if (item.dueAt > this.source.now()) continue
      this.pending.delete(key)
      work.push([key, item])
    }
    // Discovery/cleanup have completed, so the repair owner has at most four
    // resource operations in flight; one failed bucket cannot strand its peers.
    for (let offset = 0; this.active && offset < work.length; offset += MAX_CONCURRENT_REPAIRS) {
      await Promise.all(work.slice(offset, offset + MAX_CONCURRENT_REPAIRS).map(async ([key, item]) => {
        const generation = this.admissionGeneration
        try {
          await this.deliver(item)
          if (!this.active) return
          this.settled.set(key, { frontier: item.frontier, generation, at: this.source.now() })
        } catch (error) {
          this.failures += 1
          // Retry at the tail so one failing resource cannot starve quiet chats.
          item.dueAt = this.source.now() + POLL_MS
          if (!this.pending.has(key)) this.pending.set(key, item)
          log.warn("Recent realtime bucket remains pending", { kind: item.bucket.kind, error })
        }
      }))
    }
    const diagnostics = this.diagnostics
    if ((diagnostics.oldestPendingAgeMs > 5_000 || diagnostics.scanCycleMs > 5_000) &&
      this.source.now() - this.lastBudgetWarningAt >= 60_000) {
      this.lastBudgetWarningAt = this.source.now()
      log.warn("Realtime repair exceeded its qualified five-second budget", diagnostics)
    }
  }

  private async deliver(item: Pending): Promise<void> {
    const epochs = new Map(this.users)
    const current = (userId: number) => this.active && epochs.has(userId) && this.source.epoch(userId) === epochs.get(userId)
    const needs = (userId: number) => {
      if (!current(userId)) return false
      const receipt = this.receipts.get(`${userId}/${keyOf(item.bucket)}`)
      return receipt === undefined || receipt.epoch !== epochs.get(userId) || receipt.seq !== item.frontier
    }
    if (item.bucket.kind === "user") {
      const userId = item.bucket.userId
      if (!needs(userId)) return
      const isCurrent = () => current(userId)
      const accepted = await this.source.hintUser(userId, item.frontier, isCurrent)
      if (!isCurrent()) return
      if (accepted <= 0) throw new Error("User repair hint was not accepted")
      const result = await this.source.replayUser(userId, item.frontier, isCurrent)
      if (!isCurrent()) return
      if (result === "missing_record" || result === "filtered_record") {
        await this.source.fallbackUser(userId, item.frontier)
      } else if (result !== "replayed") {
        throw new Error("Current user replay remains incomplete")
      }
      this.recordReceipt(userId, item.bucket, item.frontier, epochs.get(userId)!)
      return
    }
    if (![...epochs.keys()].some(needs)) return
    await this.source.hintBucket(item, {
      shouldDeliver: needs,
      onDelivered: (userId, accepted) => {
        if (accepted <= 0 && current(userId)) throw new Error("Bucket repair hint was not accepted")
        if (accepted > 0 && current(userId)) this.recordReceipt(userId, item.bucket, item.frontier, epochs.get(userId)!)
      },
    })
  }

  private recordReceipt(userId: number, bucket: DurableBucket, seq: number, epoch: number): void {
    const key = `${userId}/${keyOf(bucket)}`
    const existing = this.receipts.get(key)
    if (existing?.epoch === epoch && existing.seq > seq) return
    if (!existing && this.receipts.size >= MAX_RECEIPTS) this.receipts.delete(this.receipts.keys().next().value!)
    this.receipts.set(key, { seq, epoch, at: this.source.now() })
  }

  private refreshUsers(): void {
    const next = new Map(this.source.connectedUsers().map((userId) => [userId, this.source.epoch(userId)]))
    if (next.size !== this.users.size || [...next].some(([userId, epoch]) => this.users.get(userId) !== epoch)) {
      this.admissionGeneration += 1
    }
    this.users = next
  }

  private prune(now: number): void {
    const cutoff = now - RECENT_REALTIME_BUCKET_TTL_MS
    for (const [key, receipt] of this.receipts) if (receipt.at < cutoff) this.receipts.delete(key)
    for (const [key, item] of this.settled) if (item.at < cutoff) this.settled.delete(key)
    for (const [key, alias] of this.peerAliases) if (alias.at < cutoff) this.peerAliases.delete(key)
    while (this.settled.size > MAX_PENDING) this.settled.delete(this.settled.keys().next().value!)
  }
}

/** Ambiguous legacy bucket variants deliberately retain catch-up fallback. */
export function updateBucket(userId: number, update: Update, peerChatIds?: Pick<ReadonlyMap<number, number>, "get">): DurableBucket | undefined {
  const chat = (id: bigint | number | undefined): DurableBucket | undefined => {
    const chatId = positiveId(id)
    return chatId === undefined ? undefined : { kind: "chat", chatId }
  }
  const space = (id: bigint | undefined): DurableBucket | undefined => {
    const spaceId = positiveId(id)
    return spaceId === undefined ? undefined : { kind: "space", spaceId }
  }
  const peer = (value: Peer | undefined): DurableBucket | undefined => value?.type.oneofKind === "chat"
    ? chat(value.type.chat.chatId)
    : value?.type.oneofKind === "user" ? chat(peerChatIds?.get(Number(value.type.user.userId))) : undefined
  const value = update.update
  switch (value.oneofKind) {
    case "newMessage": return chat(value.newMessage.message?.chatId)
    case "editMessage": return chat(value.editMessage.message?.chatId)
    case "messageAttachment": return chat(value.messageAttachment.chatId)
    case "newChat": return chat(value.newChat.chat?.id)
    case "chatMoved": return chat(value.chatMoved.chat?.id)
    case "chatVisibility": return chat(value.chatVisibility.chatId)
    case "chatInfo": return chat(value.chatInfo.chatId)
    case "acknowledgement": return chat(value.acknowledgement.chatId)
    case "deleteMessages": return peer(value.deleteMessages.peerId)
    case "deleteChat": return peer(value.deleteChat.peerId)
    case "pinnedMessages": return peer(value.pinnedMessages.peerId)
    case "clearChatHistory": return value.clearChatHistory.target.oneofKind === "peerId"
      ? peer(value.clearChatHistory.target.peerId)
      : value.clearChatHistory.target.oneofKind === "spaceId" ? space(value.clearChatHistory.target.spaceId) : undefined
    case "spaceMemberAdd": return space(value.spaceMemberAdd.member?.spaceId)
    case "spaceMemberUpdate": return space(value.spaceMemberUpdate.member?.spaceId)
    case "spaceMemberDelete": return value.spaceMemberDelete.userId === BigInt(userId)
      ? { kind: "user", userId } : space(value.spaceMemberDelete.spaceId)
    case "spaceSettings": return space(value.spaceSettings.spaceId)
    case "spaceProfile": return space(value.spaceProfile.spaceId)
    case "dialogArchived": case "joinSpace": case "updateReadMaxId": case "markAsUnread":
    case "dialogNotificationSettings": case "chatOpen": case "dialogFollowMode": case "updatedUser":
    case "chatPermissions": case "dialogCollapsedMaxId": case "userAddedToChat": case "userRemovedFromChat":
    case "updateUserSettings": case "dialogFolder": case "dialogTranslation":
    case "messageActionInvoked": case "messageActionAnswered": return { kind: "user", userId }
    default: return undefined
  }
}

export const recentRealtimeRepair = new RecentRealtimeRepair()
