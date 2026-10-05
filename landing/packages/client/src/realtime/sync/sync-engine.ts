import {
  GetChatHistoryMode,
  GetUpdatesResult_ResultType,
  Method,
  SyncSkippedSequence_Reason,
  type GetUpdatesResult,
  type Dialog,
  type RpcCall,
  type RpcResult,
  type Update,
} from "@inline-chat/protocol/core"
import { Log } from "@inline/log"
import {
  chatId,
  messageId,
  spaceId,
  userId,
  type ChatID,
  type DialogID,
  type SpaceID,
  type UserID,
} from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import {
  upsertChat,
  upsertDialog,
  upsertMessage,
  getDialogId,
  upsertSpace,
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
  getCurrentUserId?: () => UserID | undefined
}

type BucketWork = {
  key: SyncBucketKey
  targetSeq?: number
  fetchLatest: boolean
  latestRequestGeneration: number
  buffered: Map<number, Update>
  task?: Promise<void>
  retryTimer?: ReturnType<typeof setTimeout>
  retryAttempt: number
}

type SnapshotAdmission = {
  assertCurrent: (
    snapshotChatIds?: readonly ChatID[],
    snapshotSpaceIds?: readonly SpaceID[],
  ) => void
  sidecars: (
    sidecars: GetUpdatesResult["sidecars"],
  ) => GetUpdatesResult["sidecars"]
  acceptsDialog: (id: DialogID) => boolean
  close: () => void
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
class StaleSyncSnapshot extends Error {}

const maxUpdateDate = (updates: Update[]) =>
  updates.reduce(
    (maximum, update) =>
      Math.max(maximum, Number(update.date ?? 0n)),
    0,
  )

const getDialogIdForProtocol = (dialog: Dialog): DialogID | undefined => {
  if (dialog.peer?.type.oneofKind === "user") {
    return getDialogId({ peerUserId: userId(dialog.peer.type.user.userId) })
  }
  const id =
    dialog.peer?.type.oneofKind === "chat"
      ? dialog.peer.type.chat.chatId
      : dialog.chatId
  return id == null ? undefined : getDialogId({ peerThreadId: chatId(id) })
}

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

const selfSpaceEvent = (update: Update, currentUserId: UserID | undefined) => {
  if (currentUserId == null) return undefined
  if (update.update.oneofKind === "spaceMemberDelete") {
    const removal = update.update.spaceMemberDelete
    if (userId(removal.userId) === currentUserId)
      return { spaceId: spaceId(removal.spaceId), joined: false }
  }
  if (update.update.oneofKind === "joinSpace") {
    const { member, space } = update.update.joinSpace
    if (member && userId(member.userId) === currentUserId)
      return { spaceId: spaceId(member.spaceId), joined: true, seq: space?.seq }
  }
  return undefined
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
  private readonly activeTasks = new Set<Promise<void>>()
  private accessChangesInCommit: Set<ChatID> | undefined
  private spaceAccessChangesInCommit: Set<SpaceID> | undefined
  private readonly getCurrentUserId: () => UserID | undefined

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
    this.getCurrentUserId = options.getCurrentUserId ?? (() => undefined)
  }

  async connectionOpened() {
    this.connected = true
    this.stopped = false
    const generation = ++this.connectionGeneration
    await this.storage.initialize()
    await this.db.ready
    await this.db.hydrateKinds(
      [DbObjectKind.Space, DbObjectKind.Chat, DbObjectKind.Dialog].filter(
        (kind) => !this.db.collections[kind]?.hasHydrated,
      ),
    )
    if (!this.isCurrentConnection(generation)) return

    this.requestBucket({ kind: "user" }, undefined, true)
    for (const work of this.workById.values()) this.startWork(work)
    const discovery = this.discoverBuckets(generation)
    this.discoveryTask = discovery
    this.activeTasks.add(discovery)
    void discovery.finally(() => {
      this.activeTasks.delete(discovery)
      if (this.discoveryTask === discovery) this.discoveryTask = null
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
    const generation = this.connectionGeneration
    const currentUserId = this.getCurrentUserId()
    const direct: Update[] = []
    const ambiguousBuckets = new Map<string, SyncBucketKey>()

    for (const update of updates) {
      if (selfSpaceEvent(update, currentUserId)?.joined === false) {
        // A self removal cannot use an inaccessible Space cursor. Replay its
        // ordered user bucket, including a possible newer join.
        this.requestBucket({ kind: "user" }, undefined, true)
        continue
      }
      if (update.update.oneofKind === "userAddedToChat") {
        // A grant contains no chat snapshot. Fetch its authorized user-bucket
        // sidecars instead of consuming a contiguous payload-only push.
        this.requestBucket({ kind: "user" }, update.seq, true)
        continue
      }
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
        if (generation !== this.connectionGeneration || this.stopped) return
        applyUpdates(this.db, direct, "realtime", { currentUserId })
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
      const tasks = Array.from(this.activeTasks)
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
    if (fetchLatest) {
      work.fetchLatest = true
      work.latestRequestGeneration += 1
    }
    this.startWork(work)
  }

  private getWork(key: SyncBucketKey) {
    const id = syncBucketId(key)
    let work = this.workById.get(id)
    if (!work) {
      work = {
        key,
        fetchLatest: false,
        latestRequestGeneration: 0,
        buffered: new Map(),
        retryAttempt: 0,
      }
      this.workById.set(id, work)
    }
    return work
  }

  private startWork(work: BucketWork) {
    if (
      this.workById.get(syncBucketId(work.key)) !== work ||
      !this.connected ||
      this.stopped ||
      work.task ||
      work.retryTimer
    ) {
      return
    }

    const generation = this.connectionGeneration
    const task = this.runWork(work, generation)
    work.task = task
    this.activeTasks.add(task)
    void task.then(
        () => {
          work.retryAttempt = 0
        },
        (error: unknown) => {
          if (!this.isCurrentWork(work, generation)) return
          this.log.warn("sync.bucket.paused", {
            bucketKind: work.key.kind,
            error,
          })
          this.scheduleRetry(work)
        },
      )
      .finally(() => {
        this.activeTasks.delete(task)
        if (work.task === task) work.task = undefined
        if (!work.retryTimer && (work.fetchLatest || work.targetSeq != null)) {
          this.startWork(work)
        }
      })
  }

  private async runWork(work: BucketWork, generation: number) {
    let state = await this.storage.getBucketState(work.key)

    while (this.isCurrentWork(work, generation)) {
      this.discardBufferedThrough(work, state.seq)
      const contiguous = this.takeContiguousUpdates(work, state.seq)
      if (contiguous.length > 0) {
        const admission = this.snapshotAdmission(work, generation)
        try {
          state = await this.commitBucketPage(
            work.key,
            state,
            contiguous,
            undefined,
            contiguous.at(-1)!.seq!,
            maxUpdateDate(contiguous),
            "realtime",
            admission,
          )
        } finally {
          admission.close()
        }
        continue
      }

      if (work.targetSeq != null && work.targetSeq <= state.seq) {
        work.targetSeq = undefined
      }
      if (!work.fetchLatest && work.targetSeq == null) return

      const requestedLatest = work.latestRequestGeneration
      const targetSeq = work.targetSeq
      state = await this.fetchBucket(work, state, targetSeq, generation)
      if (requestedLatest === work.latestRequestGeneration)
        work.fetchLatest = false
      if (work.targetSeq != null && work.targetSeq <= state.seq) {
        work.targetSeq = undefined
      }
    }
  }

  private async fetchBucket(
    work: BucketWork,
    initialState: SyncBucketCursor,
    targetSeq: number | undefined,
    generation: number,
  ) {
    const key = work.key
    let state = initialState
    let sliceEnd = targetSeq
    while (this.isCurrentWork(work, generation)) {
      const admission = this.snapshotAdmission(work, generation)
      try {
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
        admission.assertCurrent()
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
              admission,
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
            admission,
          )
        }

        const endSeq = Number(payload.seq)
        if (endSeq === state.seq && payload.final === false) {
          throw new InvalidSyncEnvelope(
            "non-final getUpdates page made no progress",
          )
        }
        state = await this.commitBucketPage(
          key,
          state,
          payload.updates
            .slice()
            .sort((left, right) => (left.seq ?? 0) - (right.seq ?? 0)),
          payload.sidecars,
          endSeq,
          Number(payload.date),
          "syncCatchup",
          admission,
        )

        if (targetSeq != null && state.seq >= targetSeq) return state
        if (payload.final !== false) return state
      } finally {
        admission.close()
      }
    }
    throw new Error("Bucket fetch interrupted")
  }

  private validateEnvelope(payload: GetUpdatesResult, startSeq: number) {
    if (
      payload.resultType !== GetUpdatesResult_ResultType.SLICE &&
      payload.resultType !== GetUpdatesResult_ResultType.EMPTY
    ) {
      throw new InvalidSyncEnvelope(`invalid result type ${payload.resultType}`)
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
    admission: SnapshotAdmission,
  ): Promise<SyncBucketCursor> {
    const next = {
      seq,
      date: Math.max(previous.date, date, maxUpdateDate(updates)),
    }
    const currentUserId = this.getCurrentUserId()
    await this.db.hydrateDeferredUpdatesForMessageKeys(
      deferredMessageKeysFromUpdates(updates),
    )
    const accessChanges = new Set<ChatID>()
    const spaceAccessChanges = new Set<SpaceID>()
    const spaceGrants = new Map<SpaceID, number | undefined>()
    for (const update of updates) {
      if (update.update.oneofKind === "userRemovedFromChat") {
        accessChanges.add(chatId(update.update.userRemovedFromChat.chatId))
      } else if (update.update.oneofKind === "userAddedToChat") {
        accessChanges.add(chatId(update.update.userAddedToChat.chatId))
      }
      const event =
        key.kind === "user" ? selfSpaceEvent(update, currentUserId) : undefined
      if (event) {
        spaceAccessChanges.add(event.spaceId)
        if (event.joined) spaceGrants.set(event.spaceId, event.seq)
        else spaceGrants.delete(event.spaceId)
      }
    }
    const apply = () => {
      admission.assertCurrent(
        [
          ...(sidecars?.chats.map((chat) => chatId(chat.id)) ?? []),
          ...(sidecars?.dialogs.flatMap((dialog) =>
            dialog.chatId == null ? [] : [chatId(dialog.chatId)],
          ) ?? []),
        ],
        [
          ...spaceAccessChanges,
          ...(sidecars?.spaces.map((space) => spaceId(space.id)) ?? []),
          ...(sidecars?.chats.flatMap((chat) =>
            chat.spaceId == null ? [] : [spaceId(chat.spaceId)],
          ) ?? []),
        ],
      )
      this.accessChangesInCommit = accessChanges
      this.spaceAccessChangesInCommit = spaceAccessChanges
      this.db.batch(() => {
        applyUpdateSidecars(this.db, admission.sidecars(sidecars))
        applyUpdates(this.db, updates, source, {
          currentUserId,
          bucketKind: key.kind,
        })
        // A page can contain revoke followed by rejoin. Restore only the final
        // effective grants from the server's currently authorized snapshots.
        const grants = new Set<ChatID>()
        for (const update of updates) {
          if (update.update.oneofKind === "userRemovedFromChat") {
            grants.delete(chatId(update.update.userRemovedFromChat.chatId))
          } else if (update.update.oneofKind === "userAddedToChat") {
            grants.add(chatId(update.update.userAddedToChat.chatId))
          }
        }
        for (const chat of sidecars?.chats ?? []) {
          if (
            grants.has(chatId(chat.id)) ||
            (chat.spaceId != null && spaceGrants.has(spaceId(chat.spaceId)))
          )
            upsertChat(this.db, chat)
        }
        for (const space of sidecars?.spaces ?? []) {
          if (spaceGrants.has(spaceId(space.id))) upsertSpace(this.db, space)
        }
        for (const dialog of admission.sidecars(sidecars)?.dialogs ?? []) {
          if (
            (dialog.chatId != null && grants.has(chatId(dialog.chatId))) ||
            (dialog.spaceId != null && spaceGrants.has(spaceId(dialog.spaceId)))
          ) {
            upsertDialog(this.db, dialog)
          }
        }
      })
    }
    let committed: boolean
    try {
      committed = this.storage.commitBucketState
        ? await this.storage.commitBucketState(key, next, apply)
        : await (async () => {
            apply()
            await this.db.flushPersistence()
            return await this.storage.setBucketState(key, next)
          })()
    } finally {
      if (this.accessChangesInCommit === accessChanges)
        this.accessChangesInCommit = undefined
      if (this.spaceAccessChangesInCommit === spaceAccessChanges)
        this.spaceAccessChangesInCommit = undefined
    }
    if (!committed) {
      throw new Error("Could not persist sync cursor")
    }
    await this.updateLastSyncDate(next.date)
    for (const [id, spaceSeq] of spaceGrants) {
      this.requestBucket({ kind: "space", spaceId: id }, spaceSeq, true)
    }
    if (
      key.kind !== "user" &&
      updates.some(
        (update) => selfSpaceEvent(update, currentUserId)?.joined === false,
      )
    ) {
      this.requestBucket({ kind: "user" }, undefined, true)
    }
    this.log.debug("sync.bucket.committed", {
      bucketKind: key.kind,
      source,
      updateCount: updates.length,
      previousSeq: previous.seq,
      nextSeq: next.seq,
    })
    return next
  }

  private async repairChatBucket(
    key: Extract<SyncBucketKey, { kind: "chat" }>,
    targetSeq: number,
    targetDate: number,
    admission: SnapshotAdmission,
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
    admission.assertCurrent(
      chatResult?.oneofKind === "getChat" && chatResult.getChat.chat
        ? [chatId(chatResult.getChat.chat.id)]
        : undefined,
      chatResult?.oneofKind === "getChat" &&
        chatResult.getChat.chat?.spaceId != null
        ? [spaceId(chatResult.getChat.chat.spaceId)]
        : undefined,
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
    admission.assertCurrent()
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
      admission.assertCurrent(
        [chatId(chatResult.getChat.chat!.id)],
        chatResult.getChat.chat!.spaceId == null
          ? []
          : [spaceId(chatResult.getChat.chat!.spaceId)],
      )
      this.db.batch(() => {
        upsertChat(this.db, chatResult.getChat.chat!)
        const dialog = chatResult.getChat.dialog!
        const id = getDialogIdForProtocol(dialog)
        if (id == null || admission.acceptsDialog(id))
          upsertDialog(this.db, dialog)
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
      throw new Error("Could not persist repaired sync cursor")
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

  /** Request-local admission survives deletion and rejoin of the same ID. */
  private snapshotAdmission(
    work: BucketWork,
    generation: number,
  ): SnapshotAdmission {
    const removed = new Set<ChatID>()
    const accessChanged = new Set<ChatID>()
    const removedSpaces = new Set<SpaceID>()
    const changedSpaces = new Set<SpaceID>()
    const changedDialogs = new Set<DialogID>()
    const targetChatId = this.chatIdForWork(work)
    const targetSpaces = new Set<SpaceID>()
    const ancestors = new Set<ChatID>()
    let ancestor = targetChatId
    while (ancestor != null && !ancestors.has(ancestor)) {
      ancestors.add(ancestor)
      const chat = this.db.get(this.db.ref(DbObjectKind.Chat, ancestor))
      if (chat?.spaceId != null) targetSpaces.add(chat.spaceId)
      ancestor = chat?.parentChatId
    }
    const close = this.db.subscribeToResidentChanges((batch) => {
      const userCursorCommitted = batch.changes.some(
        (change) =>
          change.kind === DbObjectKind.SyncBucketState && change.id === "user",
      )
      for (const change of batch.changes) {
        if (change.kind === DbObjectKind.Space) {
          const id = change.id as SpaceID
          if (change.object == null) removedSpaces.add(id)
          if (userCursorCommitted && this.spaceAccessChangesInCommit?.has(id))
            changedSpaces.add(id)
          if (
            work.key.kind === "space" &&
            work.key.spaceId === id &&
            change.object == null
          )
            this.retireWork(work)
        }
        if (change.kind === DbObjectKind.Dialog) {
          changedDialogs.add(change.id as DialogID)
        }
        if (change.kind !== DbObjectKind.Chat) continue
        const id = change.id as ChatID
        if (change.object == null) removed.add(id)
        if (userCursorCommitted && this.accessChangesInCommit?.has(id))
          accessChanged.add(id)
        if (
          work.key.kind === "chat" &&
          id === targetChatId &&
          change.object == null
        ) {
          this.retireWork(work)
        }
      }
    })
    return {
      close,
      acceptsDialog: (id) => !changedDialogs.has(id),
      sidecars: (sidecars) =>
        sidecars && {
          ...sidecars,
          dialogs: sidecars.dialogs.filter((dialog) => {
            const id = getDialogIdForProtocol(dialog)
            return id == null || !changedDialogs.has(id)
          }),
        },
      assertCurrent: (ids = [], spaceIds = []) => {
        if (!this.isCurrentWork(work, generation)) {
          throw new StaleSyncSnapshot("Sync work was interrupted or retired")
        }
        const spaces = [...spaceIds, ...targetSpaces]
        if (work.key.kind === "space") spaces.push(work.key.spaceId)
        if (spaces.some((id) => removedSpaces.has(id))) {
          if (work.key.kind !== "user") this.retireWork(work)
          throw new StaleSyncSnapshot(
            "Space membership changed while its snapshot was in flight",
          )
        }
        if (spaces.some((id) => changedSpaces.has(id))) {
          throw new StaleSyncSnapshot(
            "A newer Space membership committed while its snapshot was in flight",
          )
        }
        if (
          work.key.kind === "chat" &&
          spaces.length === 0 &&
          (removedSpaces.size > 0 || changedSpaces.size > 0)
        ) {
          // Older inherited-chat snapshots may omit their owning Space ID.
          // Refetch after membership churn rather than infer their authority.
          throw new StaleSyncSnapshot(
            "Space membership changed during an unscoped chat snapshot",
          )
        }
        if (ids.some((id) => removed.has(id))) {
          if (work.key.kind === "chat") this.retireWork(work)
          throw new StaleSyncSnapshot(
            "Chat access changed while its snapshot was in flight",
          )
        }
        if (ids.some((id) => accessChanged.has(id))) {
          // Refetch after an effective grant changed, retaining the desired
          // catch-up frontier. Ordinary read sidecars do not invalidate it.
          throw new StaleSyncSnapshot(
            "A newer user snapshot committed while this snapshot was in flight",
          )
        }
      },
    }
  }

  private chatIdForWork(work: BucketWork): ChatID | undefined {
    if (work.key.kind !== "chat") return undefined
    const peer = work.key.peer
    if (peer.type.oneofKind === "chat") return chatId(peer.type.chat.chatId)
    if (peer.type.oneofKind !== "user") return undefined
    const peerUserId = userId(peer.type.user.userId)
    return this.db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Dialog,
      (dialog) => dialog.peerUserId === peerUserId,
    )[0]?.chatId
  }

  private retireWork(work: BucketWork) {
    if (this.workById.get(syncBucketId(work.key)) === work) {
      this.workById.delete(syncBucketId(work.key))
    }
    if (work.retryTimer) clearTimeout(work.retryTimer)
    work.retryTimer = undefined
    work.fetchLatest = false
    work.targetSeq = undefined
    work.buffered.clear()
  }

  private isCurrentWork(work: BucketWork, generation: number) {
    return (
      this.isCurrentConnection(generation) &&
      this.workById.get(syncBucketId(work.key)) === work
    )
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
        if (!this.isCurrentConnection(generation)) return
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
