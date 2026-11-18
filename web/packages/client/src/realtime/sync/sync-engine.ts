import {
  GetChatHistoryMode,
  GetChatsInput,
  GetMeInput,
  GetUpdatesResult_ResultType,
  Method,
  SyncSkippedSequence_Reason,
  type GetUpdatesResult,
  type RpcCall,
  type RpcResult,
  type Update,
} from "@inline-chat/protocol/core"
import { Log } from "@inline/log"
import { chatId, messageId, spaceId } from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { getChats } from "../transactions/get-chats"
import { getMe } from "../transactions/get-me"
import {
  upsertChat,
  upsertDialog,
  upsertMessage,
  upsertSpace,
} from "../transactions/mappers"
import { provenRanges } from "../../database/history-coverage"
import {
  applyUpdates,
  applyUpdateSidecars,
  type UpdateSidecarReport,
} from "../updates/apply-updates"
import {
  deferredMessageKeysFromUpdates,
  protocolMessageKey,
} from "../updates/deferred-message-updates"
import {
  clearBucketPurged,
  isBucketPurged,
} from "../updates/account-context"
import { reconcileSpaceMember } from "../updates/membership"
import { applySpaceSettings } from "../updates/settings"
import { replayProjectedDeferredUpdates } from "../updates/deferred-replay"
import { DbSyncStorage } from "./db-sync-storage"
import { FetchLimiter } from "./fetch-limiter"
import type { SyncStorage } from "./sync-storage"
import {
  protocolInputPeer,
  protocolUpdateBucket,
  syncBucketId,
  type SyncBucketCursor,
  type SyncBucketKey,
} from "./sync-types"
import {
  updateBucketKeys,
} from "./update-bucket-key"

export interface SyncRpcClient {
  callRpc(
    method: Method,
    input: RpcCall["input"],
    options?: { timeoutMs?: number },
  ): Promise<RpcResult["result"]>
}

/**
 * A bucket that stopped retrying. It stays stalled, holding its last
 * committed cursor, until the next connection opens or
 * `retryStalledBuckets()` is called. Pushed hints do not restart it.
 *
 * - `retry-limit`: `maxRetryAttempts` consecutive failures (network, invalid
 *   pages, a repair that failed) on this connection.
 * - `repair-unavailable`: the bucket needs an authoritative snapshot this
 *   client or server cannot produce, so retrying cannot help.
 */
export type SyncBucketStall = {
  bucketId: string
  key: SyncBucketKey
  reason: "retry-limit" | "repair-unavailable"
  attempts: number
  error: unknown
}

export type SyncEngineOptions = {
  db: Db
  client: SyncRpcClient
  storage?: SyncStorage
  logger?: Log
  now?: () => number
  maxConcurrentFetches?: number
  retryDelaysMs?: number[]
  /** Consecutive failed runs of one bucket before it stalls. Default 8. */
  maxRetryAttempts?: number
  /** Called once each time a bucket enters the stalled state. */
  onBucketStalled?: (stall: SyncBucketStall) => void
}

type BucketWork = {
  key: SyncBucketKey
  targetSeq?: number
  fetchLatest: boolean
  buffered: Map<number, Update>
  task?: Promise<void>
  retryTimer?: ReturnType<typeof setTimeout>
  retryAttempt: number
  stalled?: SyncBucketStall
}

const initialLookbackSeconds = 5 * 24 * 60 * 60
const staleStateSeconds = 14 * 24 * 60 * 60
const syncSafetyGapSeconds = 15
const maxTotalUpdates = 1_000
const coldStartTotalLimit = 50
const updatesPageLimit = 200
const repairHistoryLimit = 50
const rpcTimeoutMs = 15_000

class InvalidSyncEnvelope extends Error {}
/**
 * The bucket's chat or space was purged for access loss while this page or
 * repair was in flight. Its result is dropped and the bucket's work ends;
 * it is not an error to retry (core.md, "Sync").
 */
export class SyncBucketAccessLost extends Error {
  constructor(readonly bucketId: string) {
    super(`access to ${bucketId} was lost`)
    this.name = "SyncBucketAccessLost"
  }
}

/** A repair that failed this time and may succeed on retry. */
class SnapshotRepairRequired extends Error {}
/** A repair this client or server cannot perform; retrying cannot help. */
export class SyncRepairUnavailable extends Error {
  constructor(message: string) {
    super(message)
    this.name = "SyncRepairUnavailable"
  }
}

const maxUpdateDate = (updates: Update[]) =>
  updates.reduce(
    (maximum, update) =>
      Math.max(maximum, Number(update.date ?? 0n)),
    0,
  )

const hintedChatKey = (
  update: Extract<
    Update["update"],
    { oneofKind: "chatHasNewUpdates" }
  >["chatHasNewUpdates"],
): SyncBucketKey | undefined => {
  if (!update.peerId || update.peerId.type.oneofKind === undefined) {
    return undefined
  }
  return { kind: "chat", peer: update.peerId }
}

export class SyncEngine {
  private readonly db: Db
  private readonly client: SyncRpcClient
  private readonly storage: SyncStorage
  private readonly log: Log
  private readonly now: () => number
  private readonly limiter: FetchLimiter
  private readonly retryDelaysMs: number[]
  private readonly maxRetryAttempts: number
  private readonly onBucketStalled?: (stall: SyncBucketStall) => void
  private readonly workById = new Map<string, BucketWork>()
  /**
   * Per chat, the chat sequence through which a committed sidecar's unread
   * count is valid. A sidecar describes the dialog as of the server's
   * current chat sequence, which can be past the page that carried it; a
   * message pushed live in that range is already counted (KB-2).
   */
  private readonly countedThroughByChat = new Map<string, number>()

  private connected = false
  private stopped = false
  private connectionGeneration = 0
  private globalStateTask: Promise<void> = Promise.resolve()
  private discoveryTask: Promise<void> | null = null
  private deferredReplay: Promise<void> | null = null

  constructor(options: SyncEngineOptions) {
    this.db = options.db
    this.client = options.client
    this.storage = options.storage ?? new DbSyncStorage(options.db)
    this.log = options.logger ?? new Log("RealtimeV2.Sync")
    this.now = options.now ?? (() => Math.floor(Date.now() / 1_000))
    this.limiter = new FetchLimiter(options.maxConcurrentFetches ?? 4)
    this.retryDelaysMs =
      options.retryDelaysMs ?? [1_000, 2_000, 4_000, 8_000, 16_000, 30_000]
    this.maxRetryAttempts = Math.max(1, options.maxRetryAttempts ?? 8)
    this.onBucketStalled = options.onBucketStalled
  }

  /** Buckets that stopped retrying, with why. See `SyncBucketStall`. */
  stalledBuckets(): SyncBucketStall[] {
    return Array.from(this.workById.values()).flatMap((work) =>
      work.stalled ? [{ ...work.stalled }] : [],
    )
  }

  /** Give every stalled bucket a fresh retry budget and start it again. */
  retryStalledBuckets() {
    for (const work of this.workById.values()) {
      if (!work.stalled) continue
      work.stalled = undefined
      work.retryAttempt = 0
      work.fetchLatest = true
      this.startWork(work)
    }
  }

  async connectionOpened() {
    this.connected = true
    this.stopped = false
    const generation = ++this.connectionGeneration
    await this.storage.initialize()
    await this.replayDeferredOnce()
    if (!this.isCurrentConnection(generation)) return

    // Each connection gets a fresh retry budget for every bucket.
    for (const work of this.workById.values()) {
      if (work.stalled) work.fetchLatest = true
      work.stalled = undefined
      work.retryAttempt = 0
    }
    this.requestBucket({ kind: "user" }, undefined, true)
    for (const work of this.workById.values()) this.startWork(work)
    this.discoveryTask = this.discoverBuckets(generation)
    void this.discoveryTask.finally(() => {
      if (this.connectionGeneration === generation) this.discoveryTask = null
    })
  }

  connectionInterrupted() {
    this.connected = false
    this.connectionGeneration += 1
    this.clearRetryTimers()
  }

  async stop() {
    this.stopped = true
    this.connected = false
    this.connectionGeneration += 1
    this.clearRetryTimers()
    await this.idle()
  }

  /**
   * Raw rows of kinds that gained a model replay into it before any newer
   * update of the same kind is applied, once per engine. A failure leaves
   * the rows stored for the next start.
   */
  private replayDeferredOnce() {
    this.deferredReplay ??= replayProjectedDeferredUpdates(this.db).then(
      (report) => {
        if (report.applied > 0 || report.retained > 0) {
          this.log.debug("sync.deferred.replayed", report)
        }
      },
      (error: unknown) => {
        this.log.warn("sync.deferred.replay-failed", { error })
      },
    )
    return this.deferredReplay
  }

  /**
   * True when the bucket's chat or space was purged for access loss and has
   * not been stored again since. A stored row lifts the fence.
   */
  private isFenced(key: SyncBucketKey) {
    if (key.kind === "user") return false
    const id = syncBucketId(key)
    if (!isBucketPurged(this.db, id)) return false
    const present =
      key.kind === "space"
        ? this.db.get(this.db.ref(DbObjectKind.Space, key.spaceId)) != null
        : key.peer.type.oneofKind === "chat" &&
          this.db.get(
            this.db.ref(DbObjectKind.Chat, chatId(key.peer.type.chat.chatId)),
          ) != null
    if (present) {
      clearBucketPurged(this.db, id)
      return false
    }
    return true
  }

  /** Wrap a page or repair recipe so a fenced bucket applies nothing. */
  private fencedApply(key: SyncBucketKey, apply: () => void) {
    const state = { fenced: false }
    return {
      state,
      apply: () => {
        if (this.isFenced(key)) {
          state.fenced = true
          throw new SyncBucketAccessLost(syncBucketId(key))
        }
        apply()
      },
    }
  }

  async processPush(updates: Update[]) {
    await this.replayDeferredOnce()
    const direct: Update[] = []
    const ambiguousBuckets = new Map<string, SyncBucketKey>()

    for (const update of updates) {
      if (update.update.oneofKind === "userHasNewUpdates") {
        const targetSeq = update.update.userHasNewUpdates.updateSeq
        if (Number.isSafeInteger(targetSeq) && targetSeq > 0) {
          this.requestBucket({ kind: "user" }, targetSeq, false)
        }
        continue
      }
      if (update.update.oneofKind === "chatHasNewUpdates") {
        const key = hintedChatKey(update.update.chatHasNewUpdates)
        if (key) {
          this.requestBucket(
            key,
            update.update.chatHasNewUpdates.updateSeq,
            false,
          )
        }
        continue
      }
      if (update.update.oneofKind === "spaceHasNewUpdates") {
        this.requestBucket(
          {
            kind: "space",
            spaceId: spaceId(update.update.spaceHasNewUpdates.spaceId),
          },
          update.update.spaceHasNewUpdates.updateSeq,
          false,
        )
        continue
      }

      const seq = update.seq ?? 0
      const keys = seq > 0 ? updateBucketKeys(update) : []
      if (keys.length > 1) {
        // The sequence belongs to one of several buckets and the payload does
        // not say which, so it cannot be ordered against either cursor.
        // Applying it now could replay a stale copy over newer state (a
        // duplicate `participantAdd` after its `participantDelete`). Fetch
        // both journals instead; they deliver it in order.
        for (const candidate of keys) {
          ambiguousBuckets.set(
            syncBucketId(candidate),
            candidate,
          )
        }
        continue
      }
      const key = keys[0]
      if (!key) {
        direct.push(update)
        continue
      }

      const work = this.getWork(key)
      work.buffered.set(seq, update)
      this.requestBucket(key, seq, false)
    }

    try {
      if (direct.length === 0) return
      await this.db.hydrateDeferredUpdatesForMessageKeys(
        deferredMessageKeysFromUpdates(direct),
      )
      await this.db.commit(() => {
        applyUpdates(this.db, direct, "realtime")
      })
      await this.updateLastSyncDate(maxUpdateDate(direct))
    } finally {
      // Fetch every candidate bucket of an ambiguous sequence without
      // applying it to either cursor. Replay is safe; guessing is not.
      for (const key of ambiguousBuckets.values()) {
        this.requestBucket(key, undefined, true)
      }
    }
  }

  /**
   * Test/debug barrier. It waits for current work only; scheduled retry timers
   * intentionally remain outside the barrier.
   */
  async idle() {
    while (true) {
      const tasks = [
        ...Array.from(this.workById.values())
          .map((work) => work.task)
          .filter((task): task is Promise<void> => task != null),
        ...(this.discoveryTask ? [this.discoveryTask] : []),
      ]
      if (tasks.length === 0) return
      await Promise.allSettled(tasks)
    }
  }

  private requestBucket(
    key: SyncBucketKey,
    targetSeq: number | undefined,
    fetchLatest: boolean,
  ) {
    const work = this.getWork(key)
    if (targetSeq != null && targetSeq > 0) {
      work.targetSeq = Math.max(work.targetSeq ?? 0, targetSeq)
    }
    work.fetchLatest ||= fetchLatest
    this.startWork(work)
  }

  private getWork(key: SyncBucketKey) {
    const id = syncBucketId(key)
    let work = this.workById.get(id)
    if (!work) {
      work = {
        key,
        fetchLatest: false,
        buffered: new Map(),
        retryAttempt: 0,
      }
      this.workById.set(id, work)
    }
    return work
  }

  private startWork(work: BucketWork) {
    if (
      !this.connected ||
      this.stopped ||
      work.task ||
      work.retryTimer ||
      work.stalled
    ) {
      return
    }

    const task = this.runWork(work)
    work.task = task
    void task.then(
      () => {
        work.retryAttempt = 0
      },
      (error: unknown) => {
        if (error instanceof SyncBucketAccessLost) {
          // Purged for access loss: drop the work, never retry it.
          work.buffered.clear()
          work.targetSeq = undefined
          work.fetchLatest = false
          this.log.debug("sync.bucket.fenced", { bucketKind: work.key.kind })
          return
        }
        if (!this.connected || this.stopped) return
        this.log.warn("sync.bucket.paused", {
          bucketKind: work.key.kind,
          error,
        })
        this.scheduleRetry(work, error)
      },
    ).finally(() => {
      if (work.task === task) work.task = undefined
      if (
        !work.retryTimer &&
        !work.stalled &&
        (work.fetchLatest || work.targetSeq != null)
      ) {
        this.startWork(work)
      }
    })
  }

  private async runWork(work: BucketWork) {
    let state = await this.storage.getBucketState(work.key)

    while (this.connected && !this.stopped) {
      this.discardBufferedThrough(work, state.seq)
      const contiguous = this.takeContiguousUpdates(work, state.seq)
      if (contiguous.length > 0) {
        state = await this.commitBucketPage(
          work.key,
          state,
          contiguous,
          undefined,
          contiguous.at(-1)!.seq!,
          maxUpdateDate(contiguous),
          "realtime",
        )
        continue
      }

      if (work.targetSeq != null && work.targetSeq <= state.seq) {
        work.targetSeq = undefined
      }
      if (!work.fetchLatest && work.targetSeq == null) return

      const requestedLatest = work.fetchLatest
      const targetSeq = work.targetSeq
      const startSeq = state.seq
      state = await this.fetchBucket(work.key, state, targetSeq)
      if (requestedLatest) work.fetchLatest = false
      if (work.targetSeq != null && work.targetSeq <= state.seq) {
        work.targetSeq = undefined
      }
      if (
        targetSeq != null &&
        state.seq === startSeq &&
        work.targetSeq === targetSeq
      ) {
        // The server declared the bucket complete below the target it
        // hinted. Fetching again at once would spin; fail the run so it
        // backs off and counts toward the retry cap.
        throw new InvalidSyncEnvelope(
          `final page at ${state.seq} is below target ${targetSeq}`,
        )
      }
    }
  }

  private async fetchBucket(
    key: SyncBucketKey,
    initialState: SyncBucketCursor,
    targetSeq?: number,
  ) {
    let state = initialState
    let sliceEnd = targetSeq

    while (this.connected && !this.stopped) {
      const input: RpcCall["input"] = {
        oneofKind: "getUpdates",
        getUpdates: {
          bucket: protocolUpdateBucket(key),
          startSeq: BigInt(state.seq),
          totalLimit:
            state.seq === 0 && sliceEnd == null
              ? coldStartTotalLimit
              : maxTotalUpdates,
          seqEnd: BigInt(sliceEnd ?? 0),
          limit: updatesPageLimit,
        },
      }
      const result = await this.limiter.run(() =>
        this.client.callRpc(Method.GET_UPDATES, input, {
          timeoutMs: rpcTimeoutMs,
        }),
      )
      if (!result || result.oneofKind !== "getUpdates") {
        throw new InvalidSyncEnvelope("getUpdates returned the wrong result")
      }

      const payload = result.getUpdates
      if (payload.resultType === GetUpdatesResult_ResultType.TOO_LONG) {
        const serverSeq = Number(payload.seq)
        if (serverSeq <= state.seq) {
          throw new InvalidSyncEnvelope(
            `TOO_LONG did not advance beyond ${state.seq}`,
          )
        }
        if (state.seq === 0 && key.kind === "chat") {
          return await this.repairChatBucket(
            key,
            serverSeq,
            Number(payload.date),
          )
        }
        const nextSliceEnd = Math.min(
          targetSeq ?? serverSeq,
          serverSeq,
          state.seq + maxTotalUpdates,
        )
        if (sliceEnd != null && nextSliceEnd === sliceEnd) {
          // A bounded range is still TOO_LONG: the server's journal cannot
          // replay it (a gap or expired history). Replace the bucket's state
          // with an authoritative snapshot, as the Swift engine does.
          return await this.repairBucket(
            key,
            serverSeq,
            Number(payload.date),
          )
        }
        sliceEnd = nextSliceEnd
        continue
      }

      const requiresRepair = this.validateEnvelope(payload, state.seq)
      if (requiresRepair) {
        return await this.repairBucket(
          key,
          Number(payload.seq),
          Number(payload.date),
        )
      }

      const endSeq = Number(payload.seq)
      if (endSeq === state.seq && payload.final === false) {
        throw new InvalidSyncEnvelope("non-final getUpdates page made no progress")
      }
      state = await this.commitBucketPage(
        key,
        state,
        payload.updates.slice().sort((left, right) => (left.seq ?? 0) - (right.seq ?? 0)),
        payload.sidecars,
        endSeq,
        Number(payload.date),
        "syncCatchup",
      )

      if (targetSeq != null && state.seq >= targetSeq) return state
      if (payload.final !== false) return state
    }

    throw new Error("Bucket fetch interrupted")
  }

  private validateEnvelope(payload: GetUpdatesResult, startSeq: number) {
    if (
      payload.resultType !== GetUpdatesResult_ResultType.SLICE &&
      payload.resultType !== GetUpdatesResult_ResultType.EMPTY
    ) {
      throw new InvalidSyncEnvelope(
        `invalid result type ${payload.resultType}`,
      )
    }

    const endSeq = Number(payload.seq)
    if (!Number.isSafeInteger(endSeq) || endSeq < startSeq) {
      throw new InvalidSyncEnvelope("getUpdates moved backwards")
    }

    const accounted = new Set<number>()
    for (const update of payload.updates) {
      const seq = update.seq
      if (
        seq == null ||
        seq <= startSeq ||
        seq > endSeq ||
        accounted.has(seq)
      ) {
        throw new InvalidSyncEnvelope(
          `invalid or duplicate update sequence ${seq}`,
        )
      }
      accounted.add(seq)
    }

    let requiresRepair = false
    for (const skipped of payload.skippedSequences) {
      const seq = Number(skipped.seq)
      if (
        !Number.isSafeInteger(seq) ||
        seq <= startSeq ||
        seq > endSeq ||
        accounted.has(seq)
      ) {
        throw new InvalidSyncEnvelope(
          `invalid or duplicate skipped sequence ${seq}`,
        )
      }
      accounted.add(seq)

      if (
        skipped.reason ===
        SyncSkippedSequence_Reason.SNAPSHOT_REPAIR_REQUIRED
      ) {
        requiresRepair = true
      } else if (
        skipped.reason !==
        SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET
      ) {
        throw new InvalidSyncEnvelope(
          `unknown skipped sequence reason ${skipped.reason}`,
        )
      }
    }

    if (accounted.size !== endSeq - startSeq) {
      throw new InvalidSyncEnvelope(
        `page advanced ${endSeq - startSeq} sequences but accounted for ${accounted.size}`,
      )
    }
    return requiresRepair
  }

  private async commitBucketPage(
    key: SyncBucketKey,
    previous: SyncBucketCursor,
    updates: Update[],
    sidecars: GetUpdatesResult["sidecars"],
    seq: number,
    date: number,
    source: "realtime" | "syncCatchup",
  ): Promise<SyncBucketCursor> {
    const next = {
      seq,
      date: Math.max(previous.date, date, maxUpdateDate(updates)),
    }
    await this.db.hydrateDeferredUpdatesForMessageKeys(
      deferredMessageKeysFromUpdates(updates),
    )
    let counted: UpdateSidecarReport["countedChats"] = []
    const fence = this.fencedApply(key, () => {
      this.db.batch(() => {
        counted = applyUpdateSidecars(this.db, sidecars).countedChats
        this.applyPageUpdates(updates, source)
      })
    })
    const apply = fence.apply
    const committed = this.storage.commitBucketState
      ? await this.storage.commitBucketState(key, next, apply)
      : await (async () => {
          apply()
          await this.db.flushPersistence()
          return await this.storage.setBucketState(key, next)
        })()
    if (!committed) {
      if (fence.state.fenced) throw new SyncBucketAccessLost(syncBucketId(key))
      throw new Error("Could not persist sync cursor")
    }
    this.recordCountedChats(counted)
    await this.updateLastSyncDate(next.date)
    this.log.debug("sync.bucket.committed", {
      bucketKind: key.kind,
      source,
      updateCount: updates.length,
      previousSeq: previous.seq,
      nextSeq: next.seq,
    })
    return next
  }

  /**
   * Apply one page's updates in order. A live message the dialog's unread
   * count already includes (a sidecar counted it, see `countedThroughByChat`)
   * is applied as catch-up, which never adds to the count.
   */
  private applyPageUpdates(
    updates: Update[],
    source: "realtime" | "syncCatchup",
  ) {
    if (source === "syncCatchup") {
      applyUpdates(this.db, updates, source)
      return
    }
    let run: Update[] = []
    let runSource: "realtime" | "syncCatchup" = source
    for (const update of updates) {
      const updateSource = this.isCountedBySidecar(update)
        ? "syncCatchup"
        : source
      if (run.length > 0 && updateSource !== runSource) {
        applyUpdates(this.db, run, runSource)
        run = []
      }
      runSource = updateSource
      run.push(update)
    }
    if (run.length > 0) applyUpdates(this.db, run, runSource)
  }

  private isCountedBySidecar(update: Update) {
    if (update.update.oneofKind !== "newMessage") return false
    const message = update.update.newMessage.message
    if (!message || update.seq == null) return false
    const through = this.countedThroughByChat.get(String(message.chatId))
    return through != null && update.seq <= through
  }

  private recordCountedChats(
    counted: UpdateSidecarReport["countedChats"],
  ) {
    for (const { chatId: countedChat, seq } of counted) {
      const key = String(countedChat)
      this.countedThroughByChat.set(
        key,
        Math.max(this.countedThroughByChat.get(key) ?? 0, seq),
      )
    }
  }

  private repairBucket(
    key: SyncBucketKey,
    targetSeq: number,
    targetDate: number,
  ): Promise<SyncBucketCursor> {
    if (key.kind === "chat") {
      return this.repairChatBucket(key, targetSeq, targetDate)
    }
    if (key.kind === "space") {
      return this.repairSpaceBucket(key, targetSeq, targetDate)
    }
    return this.repairUserBucket(targetSeq)
  }

  /**
   * The user bucket's snapshot, as `Sync.repairUserBucket` in the Swift
   * engine builds it: a checkpoint of the user sequence taken first, then
   * the chat list and the current user. The cursor moves to the checkpoint,
   * so updates that land while the snapshot is fetched are replayed after
   * it (replay is idempotent).
   *
   * Not repaired yet: user settings (no model on the web) and removal of
   * chats that left the list during the gap (no access-loss purge yet).
   */
  private async repairUserBucket(
    targetSeq: number,
  ): Promise<SyncBucketCursor> {
    const key: SyncBucketKey = { kind: "user" }
    const checkpointResult = await this.limiter.run(() =>
      this.client.callRpc(
        Method.GET_UPDATES_STATE,
        { oneofKind: "getUpdatesState", getUpdatesState: {} },
        { timeoutMs: rpcTimeoutMs },
      ),
    )
    if (
      !checkpointResult ||
      checkpointResult.oneofKind !== "getUpdatesState"
    ) {
      throw new SnapshotRepairRequired("user checkpoint failed")
    }
    const checkpoint = checkpointResult.getUpdatesState
    if (checkpoint.seq == null) {
      throw new SyncRepairUnavailable(
        "the server does not report the user bucket sequence",
      )
    }
    const checkpointDate = Number(checkpoint.date)
    if (checkpoint.seq < targetSeq || !(checkpointDate > 0)) {
      throw new SnapshotRepairRequired(
        `user checkpoint ${checkpoint.seq} is behind ${targetSeq}`,
      )
    }

    const [chatsResult, meResult] = await Promise.all([
      this.limiter.run(() =>
        this.client.callRpc(
          Method.GET_CHATS,
          { oneofKind: "getChats", getChats: GetChatsInput.create() },
          { timeoutMs: rpcTimeoutMs },
        ),
      ),
      this.limiter.run(() =>
        this.client.callRpc(
          Method.GET_ME,
          { oneofKind: "getMe", getMe: GetMeInput.create() },
          { timeoutMs: rpcTimeoutMs },
        ),
      ),
    ])
    if (!chatsResult || chatsResult.oneofKind !== "getChats") {
      throw new SnapshotRepairRequired("getChats repair failed")
    }
    if (!meResult || meResult.oneofKind !== "getMe") {
      throw new SnapshotRepairRequired("getMe repair failed")
    }

    const next = { seq: checkpoint.seq, date: checkpointDate }
    await this.db.hydrateDeferredUpdatesForMessageKeys(
      chatsResult.getChats.messages.map(protocolMessageKey),
    )
    await this.commitRepair(key, next, () => {
      getChats().apply(chatsResult, this.db)
      getMe().apply(meResult, this.db)
      // A catalog proves no history interval, and the user bucket's gap may
      // have hidden chat-bucket work: every chat's coverage starts over
      // (InlineKit's root repair does the same).
      for (const chat of chatsResult.getChats.chats) {
        this.db.resetHistoryCoverage(chatId(chat.id))
      }
    })
    this.log.debug("sync.bucket.repaired", {
      bucketKind: key.kind,
      chatCount: chatsResult.getChats.chats.length,
      nextSeq: next.seq,
    })
    return next
  }

  /**
   * The space bucket's snapshot, as `Sync.repairSpaceBucket` in the Swift
   * engine: the space, the account's membership and the space settings,
   * then the cursor at the server's target. The member roster is not part
   * of the snapshot; the space is marked as needing it.
   */
  private async repairSpaceBucket(
    key: Extract<SyncBucketKey, { kind: "space" }>,
    targetSeq: number,
    targetDate: number,
  ): Promise<SyncBucketCursor> {
    const result = await this.limiter.run(() =>
      this.client.callRpc(
        Method.GET_SPACE,
        {
          oneofKind: "getSpace",
          getSpace: { spaceId: BigInt(key.spaceId) },
        },
        { timeoutMs: rpcTimeoutMs },
      ),
    )
    if (!result || result.oneofKind !== "getSpace") {
      throw new SnapshotRepairRequired("getSpace repair failed")
    }
    const space = result.getSpace.space
    if (!space || String(space.id) !== String(key.spaceId)) {
      throw new SnapshotRepairRequired(
        "space repair snapshot does not match the bucket",
      )
    }
    const next = { seq: targetSeq, date: targetDate }
    const { membership, settings } = result.getSpace
    await this.commitRepair(key, next, () => {
      upsertSpace(this.db, space)
      // The account's own membership and the settings come with the
      // snapshot; the roster does not, so it is marked incomplete (InlineKit
      // `applySpaceRepair`).
      if (membership && String(membership.spaceId) === String(key.spaceId)) {
        reconcileSpaceMember(this.db, membership)
      }
      if (settings) {
        applySpaceSettings(this.db, { ...settings, spaceId: space.id })
      }
      const stored = this.db.get(this.db.ref(DbObjectKind.Space, key.spaceId))
      if (stored) {
        this.db.replace({ ...stored, memberRosterComplete: false })
      }
    })
    this.log.debug("sync.bucket.repaired", {
      bucketKind: key.kind,
      nextSeq: next.seq,
    })
    return next
  }

  /** Commit a repair snapshot and its cursor in one transaction. */
  private async commitRepair(
    key: SyncBucketKey,
    next: SyncBucketCursor,
    apply: () => void,
  ) {
    const fence = this.fencedApply(key, () => this.db.batch(apply))
    const applyInBatch = fence.apply
    const committed = this.storage.commitBucketState
      ? await this.storage.commitBucketState(key, next, applyInBatch)
      : await (async () => {
          applyInBatch()
          await this.db.flushPersistence()
          return await this.storage.setBucketState(key, next)
        })()
    if (!committed) {
      if (fence.state.fenced) throw new SyncBucketAccessLost(syncBucketId(key))
      throw new Error("Could not persist repaired sync cursor")
    }
    await this.updateLastSyncDate(next.date)
  }

  private async repairChatBucket(
    key: Extract<SyncBucketKey, { kind: "chat" }>,
    targetSeq: number,
    targetDate: number,
  ): Promise<SyncBucketCursor> {
    const peerId = protocolInputPeer(key.peer)
    if (!peerId) throw new SnapshotRepairRequired("invalid chat peer")

    const chatResult = await this.limiter.run(() =>
      this.client.callRpc(
        Method.GET_CHAT,
        {
          oneofKind: "getChat",
          getChat: { peerId, includeRecentMessages: false },
        },
        { timeoutMs: rpcTimeoutMs },
      ),
    )
    if (!chatResult || chatResult.oneofKind !== "getChat") {
      throw new SnapshotRepairRequired("getChat repair failed")
    }

    const historyResult = await this.limiter.run(() =>
      this.client.callRpc(
        Method.GET_CHAT_HISTORY,
        {
          oneofKind: "getChatHistory",
          getChatHistory: {
            peerId,
            mode: GetChatHistoryMode.HISTORY_MODE_LATEST,
            limit: repairHistoryLimit,
          },
        },
        { timeoutMs: rpcTimeoutMs },
      ),
    )
    if (!historyResult || historyResult.oneofKind !== "getChatHistory") {
      throw new SnapshotRepairRequired("getChatHistory repair failed")
    }
    if (!chatResult.getChat.chat || !chatResult.getChat.dialog) {
      throw new SnapshotRepairRequired("chat repair snapshot is incomplete")
    }

    const next = { seq: targetSeq, date: targetDate }
    await this.db.hydrateDeferredUpdatesForMessageKeys([
      ...(chatResult.getChat.anchorMessage
        ? [protocolMessageKey(chatResult.getChat.anchorMessage)]
        : []),
      ...historyResult.getChatHistory.messages.map(
        protocolMessageKey,
      ),
    ])
    const applyRepair = () => {
      this.db.batch(() => {
        upsertChat(this.db, chatResult.getChat.chat!)
        upsertDialog(this.db, chatResult.getChat.dialog!)
        if (chatResult.getChat.anchorMessage) {
          upsertMessage(this.db, chatResult.getChat.anchorMessage)
        }
        for (const message of historyResult.getChatHistory.messages) {
          upsertMessage(this.db, message)
        }

        const repairedChatId = chatId(
          chatResult.getChat.chat!.id,
        )
        // The bucket skipped history: nothing certified before survives.
        // The latest page fetched for the repair is itself a proof.
        this.db.resetHistoryCoverage(repairedChatId)
        const returned = historyResult.getChatHistory.messages.filter(
          (message) => String(message.chatId) === repairedChatId,
        )
        const proven = provenRanges(
          { mode: "latest", limit: repairHistoryLimit },
          returned.map((message) => message.id),
        )
        if (
          proven &&
          returned.length === historyResult.getChatHistory.messages.length
        ) {
          const lastMsgId = chatResult.getChat.chat!.lastMsgId
          this.db.admitHistoryPage(
            repairedChatId,
            proven,
            returned.map((message) => messageId(message.id)),
            lastMsgId == null ? undefined : messageId(lastMsgId),
          )
        }
        const chat = this.db.get(
          this.db.ref(DbObjectKind.Chat, repairedChatId),
        )
        if (chat) {
          this.db.replace({
            ...chat,
            pinnedMessageIds:
              chatResult.getChat.pinnedMessageIds.map((id) =>
                messageId(id),
              ),
          })
        }
      })
    }
    const fence = this.fencedApply(key, applyRepair)
    const committed = this.storage.commitBucketState
      ? await this.storage.commitBucketState(
          key,
          next,
          fence.apply,
        )
      : await (async () => {
          fence.apply()
          await this.db.flushPersistence()
          return await this.storage.setBucketState(key, next)
        })()
    if (!committed) {
      if (fence.state.fenced) throw new SyncBucketAccessLost(syncBucketId(key))
      throw new Error("Could not persist repaired sync cursor")
    }
    const repairedSeq = chatResult.getChat.chat.seq
    if (repairedSeq != null && repairedSeq > 0) {
      this.recordCountedChats([
        { chatId: chatId(chatResult.getChat.chat.id), seq: repairedSeq },
      ])
    }
    await this.updateLastSyncDate(targetDate)
    this.log.debug("sync.bucket.repaired", {
      bucketKind: key.kind,
      messageCount: historyResult.getChatHistory.messages.length,
      nextSeq: next.seq,
    })
    return next
  }

  private takeContiguousUpdates(work: BucketWork, startSeq: number) {
    const updates: Update[] = []
    let seq = startSeq + 1
    while (true) {
      const update = work.buffered.get(seq)
      if (!update) return updates
      updates.push(update)
      work.buffered.delete(seq)
      seq += 1
    }
  }

  private discardBufferedThrough(work: BucketWork, seq: number) {
    for (const bufferedSeq of work.buffered.keys()) {
      if (bufferedSeq <= seq) work.buffered.delete(bufferedSeq)
    }
  }

  private async discoverBuckets(generation: number) {
    const state = await this.preparedGlobalState()
    const delays = [0, 1_000, 2_000, 5_000]

    for (let attempt = 0; attempt < delays.length; attempt += 1) {
      if (!this.isCurrentConnection(generation)) return
      const delay = delays[attempt] ?? 0
      if (delay > 0) {
        await new Promise<void>((resolve) =>
          setTimeout(resolve, delay),
        )
      }
      if (!this.isCurrentConnection(generation)) return

      try {
        const result = await this.client.callRpc(
          Method.GET_UPDATES_STATE,
          {
            oneofKind: "getUpdatesState",
            getUpdatesState: {
              date: BigInt(state.lastSyncDate),
            },
          },
          { timeoutMs: rpcTimeoutMs },
        )
        if (!result || result.oneofKind !== "getUpdatesState") {
          throw new Error("getUpdatesState returned the wrong result")
        }
        if (result.getUpdatesState.updatesFound === false) {
          await this.updateLastSyncDate(
            Number(result.getUpdatesState.date),
          )
        }
        return
      } catch (error) {
        if (attempt === delays.length - 1) {
          this.log.warn("sync.discovery.failed", { error })
        }
      }
    }
  }

  private async preparedGlobalState() {
    let state = await this.storage.getState()
    const now = this.now()
    if (
      state.lastSyncDate === 0 ||
      now - state.lastSyncDate > staleStateSeconds
    ) {
      state = {
        lastSyncDate: Math.max(0, now - initialLookbackSeconds),
      }
      if (!(await this.storage.setState(state))) {
        throw new Error("Could not persist initial sync state")
      }
    }
    return state
  }

  private updateLastSyncDate(maxAppliedDate: number) {
    if (maxAppliedDate <= 0) return this.globalStateTask

    this.globalStateTask = this.globalStateTask.catch(() => undefined).then(async () => {
      const current = await this.storage.getState()
      const proposed = Math.max(
        current.lastSyncDate,
        maxAppliedDate - syncSafetyGapSeconds,
      )
      if (proposed === current.lastSyncDate) return
      if (!(await this.storage.setState({ lastSyncDate: proposed }))) {
        throw new Error("Could not persist global sync date")
      }
    })
    return this.globalStateTask
  }

  private scheduleRetry(work: BucketWork, error: unknown) {
    if (work.retryTimer || !this.connected || this.stopped) return
    if (error instanceof SyncRepairUnavailable) {
      this.stall(work, "repair-unavailable", error)
      return
    }
    if (work.retryAttempt + 1 >= this.maxRetryAttempts) {
      this.stall(work, "retry-limit", error)
      return
    }
    const delay =
      this.retryDelaysMs[
        Math.min(work.retryAttempt, this.retryDelaysMs.length - 1)
      ] ?? 30_000
    work.retryAttempt += 1
    work.retryTimer = setTimeout(() => {
      work.retryTimer = undefined
      this.startWork(work)
    }, delay)
  }

  private stall(
    work: BucketWork,
    reason: SyncBucketStall["reason"],
    error: unknown,
  ) {
    const stall: SyncBucketStall = {
      bucketId: syncBucketId(work.key),
      key: work.key,
      reason,
      attempts: work.retryAttempt + 1,
      error,
    }
    work.stalled = stall
    this.log.error("sync.bucket.stalled", {
      bucketKind: work.key.kind,
      reason,
      attempts: stall.attempts,
      error,
    })
    try {
      this.onBucketStalled?.({ ...stall })
    } catch (listenerError) {
      this.log.error("sync.bucket.stalled_listener_failed", {
        error: listenerError,
      })
    }
  }

  private clearRetryTimers() {
    for (const work of this.workById.values()) {
      if (work.retryTimer) clearTimeout(work.retryTimer)
      work.retryTimer = undefined
    }
  }

  private isCurrentConnection(generation: number) {
    return (
      this.connected &&
      !this.stopped &&
      generation === this.connectionGeneration
    )
  }
}
