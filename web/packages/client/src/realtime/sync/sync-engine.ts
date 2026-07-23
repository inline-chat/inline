import {
  GetChatHistoryMode,
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
import {
  upsertChat,
  upsertDialog,
  upsertMessage,
} from "../transactions/mappers"
import { applyUpdates, applyUpdateSidecars } from "../updates/apply-updates"
import {
  deferredMessageKeysFromUpdates,
  protocolMessageKey,
} from "../updates/deferred-message-updates"
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

export type SyncEngineOptions = {
  db: Db
  client: SyncRpcClient
  storage?: SyncStorage
  logger?: Log
  now?: () => number
  maxConcurrentFetches?: number
  retryDelaysMs?: number[]
}

type BucketWork = {
  key: SyncBucketKey
  targetSeq?: number
  fetchLatest: boolean
  buffered: Map<number, Update>
  task?: Promise<void>
  retryTimer?: ReturnType<typeof setTimeout>
  retryAttempt: number
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
class SnapshotRepairRequired extends Error {}

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
  private readonly workById = new Map<string, BucketWork>()

  private connected = false
  private stopped = false
  private connectionGeneration = 0
  private globalStateTask: Promise<void> = Promise.resolve()
  private discoveryTask: Promise<void> | null = null

  constructor(options: SyncEngineOptions) {
    this.db = options.db
    this.client = options.client
    this.storage = options.storage ?? new DbSyncStorage(options.db)
    this.log = options.logger ?? new Log("RealtimeV2.Sync")
    this.now = options.now ?? (() => Math.floor(Date.now() / 1_000))
    this.limiter = new FetchLimiter(options.maxConcurrentFetches ?? 4)
    this.retryDelaysMs =
      options.retryDelaysMs ?? [1_000, 2_000, 4_000, 8_000, 16_000, 30_000]
  }

  async connectionOpened() {
    this.connected = true
    this.stopped = false
    const generation = ++this.connectionGeneration
    await this.storage.initialize()
    if (!this.isCurrentConnection(generation)) return

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

  async processPush(updates: Update[]) {
    const direct: Update[] = []
    const ambiguousBuckets = new Map<string, SyncBucketKey>()

    for (const update of updates) {
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
        direct.push(update)
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

    if (direct.length === 0) return
    try {
      await this.db.hydrateDeferredUpdatesForMessageKeys(
        deferredMessageKeysFromUpdates(direct),
      )
      await this.db.commit(() => {
        applyUpdates(this.db, direct, "realtime")
      })
      await this.updateLastSyncDate(maxUpdateDate(direct))
    } finally {
      // Fetch both candidate buckets without applying the ambiguous sequence
      // to either cursor. Duplicate replay is safe; cursor corruption is not.
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
      work.retryTimer
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
        if (!this.connected || this.stopped) return
        this.log.warn(
          `Bucket sync paused for ${syncBucketId(work.key)}`,
          error,
        )
        this.scheduleRetry(work)
      },
    ).finally(() => {
      if (work.task === task) work.task = undefined
      if (
        !work.retryTimer &&
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
      state = await this.fetchBucket(work.key, state, targetSeq)
      if (requestedLatest) work.fetchLatest = false
      if (work.targetSeq != null && work.targetSeq <= state.seq) {
        work.targetSeq = undefined
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
          throw new InvalidSyncEnvelope(
            `TOO_LONG repeated slice boundary ${sliceEnd}`,
          )
        }
        sliceEnd = nextSliceEnd
        continue
      }

      const requiresRepair = this.validateEnvelope(payload, state.seq)
      if (requiresRepair) {
        if (key.kind !== "chat") throw new SnapshotRepairRequired()
        return await this.repairChatBucket(
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
    const apply = () => {
      this.db.batch(() => {
        applyUpdateSidecars(this.db, sidecars)
        applyUpdates(this.db, updates, source)
      })
    }
    const committed = this.storage.commitBucketState
      ? await this.storage.commitBucketState(key, next, apply)
      : await (async () => {
          apply()
          await this.db.flushPersistence()
          return await this.storage.setBucketState(key, next)
        })()
    if (!committed) {
      throw new Error(`Could not persist cursor for ${syncBucketId(key)}`)
    }
    await this.updateLastSyncDate(next.date)
    return next
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
          getChat: { peerId },
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
    const committed = this.storage.commitBucketState
      ? await this.storage.commitBucketState(
          key,
          next,
          applyRepair,
        )
      : await (async () => {
          applyRepair()
          await this.db.flushPersistence()
          return await this.storage.setBucketState(key, next)
        })()
    if (!committed) {
      throw new Error(`Could not persist repaired cursor for ${syncBucketId(key)}`)
    }
    await this.updateLastSyncDate(targetDate)
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
          this.log.warn("Bucket discovery failed", error)
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

  private scheduleRetry(work: BucketWork) {
    if (work.retryTimer || !this.connected || this.stopped) return
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
