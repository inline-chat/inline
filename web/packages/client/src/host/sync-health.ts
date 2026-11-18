/**
 * The account's sync engine as the host runs it: the realtime client's
 * `SyncEngine`, built here so the host hears what it needs without changing
 * the engine.
 *
 * - Stalls: a bucket that stopped retrying (`onBucketStalled`), and the
 *   points where stalls clear (a new connection, an explicit retry), are
 *   reported through `onStallsChanged`; `stalledSync` maps them to the
 *   protocol's `SyncStall`.
 * - Live delivery: the updates of every push and every `getUpdates` page are
 *   shown to `onDelivered` before they apply, so the new-message feed can
 *   tell a live arrival from a row loaded by history paging or a repair
 *   (which never pass through here).
 */
import type { Method, RpcCall, RpcResult, Update } from "@inline-chat/protocol/core"
import type { SyncStall } from "@inline/core-protocol"
import { spaceId as makeSpaceId, userId as makeUserId, chatId as makeChatId } from "@inline/ids"
import type { Log } from "@inline/log"
import type { Db } from "../database"
import { DbObjectKind } from "../database/models"
import type { ReplicaView } from "../queries/view"
import { SyncEngine, type SyncBucketStall } from "../realtime/sync"

export type HostSyncEngineOptions = {
  db: Db
  /** The realtime client's RPC client, resolved late (it is built after this). */
  client: () => {
    callRpc(
      method: Method,
      input: RpcCall["input"],
      options?: { timeoutMs?: number },
    ): Promise<RpcResult["result"]>
  }
  logger: Log
  onDelivered: (updates: readonly Update[]) => void
  onStallsChanged: () => void
}

export class HostSyncEngine extends SyncEngine {
  private readonly hooks: Pick<HostSyncEngineOptions, "onDelivered" | "onStallsChanged">

  constructor(options: HostSyncEngineOptions) {
    super({
      db: options.db,
      client: {
        callRpc: async (method, input, rpcOptions) => {
          const result = await options.client().callRpc(method, input, rpcOptions)
          if (result.oneofKind === "getUpdates") {
            options.onDelivered(result.getUpdates.updates)
          }
          return result
        },
      },
      logger: options.logger,
      onBucketStalled: () => options.onStallsChanged(),
    })
    this.hooks = options
  }

  override async processPush(updates: Update[]) {
    this.hooks.onDelivered(updates)
    return await super.processPush(updates)
  }

  override async connectionOpened() {
    try {
      await super.connectionOpened()
    } finally {
      // A new connection gives every stalled bucket a fresh budget.
      this.hooks.onStallsChanged()
    }
  }

  override retryStalledBuckets() {
    super.retryStalledBuckets()
    this.hooks.onStallsChanged()
  }
}

/** The protocol's view of the engine's stalled buckets, in a stable order. */
export const stalledSync = (
  stalls: readonly SyncBucketStall[],
  view: ReplicaView,
): SyncStall[] =>
  stalls
    .map((stall): SyncStall => {
      const reason = stall.reason === "retry-limit" ? "retryLimit" : "repairUnavailable"
      const key = stall.key
      if (key.kind === "user") return { scope: "account", reason }
      if (key.kind === "space") return { scope: "space", spaceId: makeSpaceId(key.spaceId), reason }
      const peer = key.peer.type
      if (peer.oneofKind === "chat") {
        return { scope: "chat", chatId: makeChatId(peer.chat.chatId), reason }
      }
      if (peer.oneofKind === "user") {
        const peerUserId = makeUserId(peer.user.userId)
        const chatId =
          view.all(DbObjectKind.Dialog).find((dialog) => dialog.peerUserId === peerUserId)?.chatId ??
          view.all(DbObjectKind.Chat).find((chat) => chat.peerUserId === peerUserId)?.id
        return { scope: "chat", peerUserId, ...(chatId ? { chatId } : {}), reason }
      }
      return { scope: "chat", reason }
    })
    .sort((left, right) => sortKey(left).localeCompare(sortKey(right)))

const sortKey = (stall: SyncStall) =>
  `${stall.scope}:${stall.spaceId ?? ""}:${stall.chatId ?? ""}:${stall.peerUserId ?? ""}`
