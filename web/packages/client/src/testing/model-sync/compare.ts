import { DialogNotificationSettings_Mode } from "@inline-chat/protocol/core"
import { MessageSendingStatus, type Message } from "../../database/models"
import { syncBucketId } from "../../realtime/sync/sync-types"
import { bucketKeyFor, type ReplicaSnapshot } from "../core-harness"
import type { ServerModel } from "../server-model"

/**
 * The convergence properties a settled replica must satisfy against the
 * server model. Each property has a stable name, used in reports and to
 * mark known divergences.
 *
 * Checked after `CoreHarness.heal()`: faults removed, a fresh connection
 * opened (discovery and the user bucket ran), the outbox drained and sync
 * idle. Message rows are read back from SQLite, not from memory.
 *
 * | Property | Holds when |
 * | --- | --- |
 * | `messages.set` | Per chat, the replica's server-ID message rows are exactly the model's live messages. |
 * | `messages.text` | Each message's text equals the model's text after every edit. |
 * | `messages.reactions` | Each message's reactions (user, emoji) equal the model's, for messages whose every reaction push reached the client in order (reactions are realtime only on the server; a lost push is unrecoverable by design). |
 * | `optimistic.none-stuck` | No row has a temporary (non-positive) ID or a sending/failed status. |
 * | `optimistic.no-duplicates` | Each message the model's user sent appears exactly once, under its server ID. |
 * | `outbox.empty` | No pending or failed intent remains. |
 * | `dialog.readMaxId` | The dialog's read boundary equals the model's. |
 * | `dialog.unread` | The dialog's unread count equals the model's, unless the model changed it in a way the server never reports (deleting an unread message) and nothing authoritative was served since. |
 * | `chat.lastMsgId` | The chat's last message is the model's newest live message. |
 * | `cursor.not-ahead` | No bucket cursor is beyond the model's sequence for that bucket. |
 * | `members.set` | Per space, the replica's members (user and membership generation) are exactly those the space bucket's events build through the replica's space cursor. |
 * | `dialog.notificationMode` | The dialog's notification mode equals the model's (the user bucket is caught up after healing). |
 * | `deferred.retained` | Every user-bucket record at or below the replica's user cursor that the client has no model for (`agentSettings`) is stored for replay (invariant 7). |
 * | `resident.durable` | Every message in memory has the same text in SQLite (invariant 1). |
 * | `durable.flushed` | Every accepted write reached SQLite. |
 */

export type Divergence = {
  property: string
  chatId?: string
  detail: string
  /** Set when this divergence matches a recorded, already-reported bug. */
  knownBug?: string
}

export type CompareContext = {
  /** `${chatId}:${messageId}` of messages whose reaction state is unverifiable. */
  unverifiableReactions: ReadonlySet<string>
}

const isServerId = (message: Message) => {
  try {
    return BigInt(message.messageId) > 0n
  } catch {
    return false
  }
}

const reactionKey = (userId: bigint | string, emoji: string) => `${userId}:${emoji}`

export const compareReplica = (
  model: ServerModel,
  replica: ReplicaSnapshot,
  context: CompareContext,
): Divergence[] => {
  const divergences: Divergence[] = []
  const add = (divergence: Divergence) => divergences.push(divergence)

  if (replica.flushError !== undefined) {
    add({ property: "durable.flushed", detail: String(replica.flushError) })
  }

  for (const message of replica.messages) {
    const id = BigInt(message.messageId)
    if (id <= 0n || message.status === MessageSendingStatus.Sending || message.status === MessageSendingStatus.Failed) {
      add({
        property: "optimistic.none-stuck",
        chatId: message.chatId,
        detail: `row ${message.id} status=${message.status ?? "none"} text=${JSON.stringify(message.message)}`,
      })
    }
  }

  if (replica.pendingTransactions.length > 0) {
    add({
      property: "outbox.empty",
      detail: replica.pendingTransactions
        .map((record) => `${record.type}:${record.status}`)
        .join(", "),
    })
  }

  for (const chat of model.chats.values()) {
    const chatId = String(chat.id)
    const state = model.chatState(chat.id)
    const rows = replica.messages.filter(
      (message) => message.chatId === chatId && isServerId(message),
    )
    const rowsById = new Map(rows.map((row) => [BigInt(row.messageId), row]))
    const modelIds = new Set(state.messages.map((message) => message.id))

    const missing = state.messages.filter((message) => !rowsById.has(message.id))
    const extra = rows.filter((row) => !modelIds.has(BigInt(row.messageId)))
    if (missing.length > 0 || extra.length > 0) {
      add({
        property: "messages.set",
        chatId,
        detail:
          `missing [${missing.map((message) => message.id).join(",")}]` +
          ` extra [${extra.map((row) => row.messageId).join(",")}]`,
      })
    }

    for (const message of state.messages) {
      const row = rowsById.get(message.id)
      if (!row) continue
      if ((row.message ?? "") !== message.text) {
        add({
          property: "messages.text",
          chatId,
          detail: `message ${message.id}: replica ${JSON.stringify(row.message)} model ${JSON.stringify(message.text)}`,
        })
      }
      if (!context.unverifiableReactions.has(`${chatId}:${message.id}`)) {
        const replicaReactions = (row.reactions?.reactions ?? [])
          .map((reaction) => reactionKey(reaction.userId, reaction.emoji))
          .sort()
        const modelReactions = message.reactions
          .map((reaction) => reactionKey(reaction.userId, reaction.emoji))
          .sort()
        if (replicaReactions.join("|") !== modelReactions.join("|")) {
          add({
            property: "messages.reactions",
            chatId,
            detail: `message ${message.id}: replica [${replicaReactions}] model [${modelReactions}]`,
          })
        }
      }
      if (message.randomId != null) {
        const copies = replica.messages.filter(
          (candidate) =>
            candidate.chatId === chatId &&
            (BigInt(candidate.messageId) === message.id || candidate.randomId === message.randomId),
        )
        if (copies.length !== 1) {
          add({
            property: "optimistic.no-duplicates",
            chatId,
            detail: `sent message ${message.id} has ${copies.length} rows`,
          })
        }
      }
    }

    const chatRow = replica.chats.find((candidate) => candidate.id === chatId)
    const replicaLast = chatRow?.lastMsgId == null ? undefined : BigInt(chatRow.lastMsgId)
    if (replicaLast !== state.lastMsgId) {
      add({
        property: "chat.lastMsgId",
        chatId,
        detail: `replica ${replicaLast ?? "none"} model ${state.lastMsgId ?? "none"}`,
      })
    }

    const dialog = replica.dialogs.find((candidate) => candidate.chatId === chatId)
    const replicaRead = dialog?.readMaxId == null ? 0n : BigInt(dialog.readMaxId)
    const replicaUnread = dialog?.unreadCount ?? 0
    if (replicaRead !== state.readMaxId) {
      add({
        property: "dialog.readMaxId",
        chatId,
        detail: `replica ${replicaRead} model ${state.readMaxId}`,
      })
    }
    const modelMode = model.dialogs.get(chat.id)?.notificationMode
    const expectedMode =
      modelMode === DialogNotificationSettings_Mode.ALL
        ? "all"
        : modelMode === DialogNotificationSettings_Mode.MENTIONS
          ? "mentions"
          : modelMode === DialogNotificationSettings_Mode.NONE
            ? "none"
            : undefined
    if (dialog?.notificationMode !== expectedMode) {
      add({
        property: "dialog.notificationMode",
        chatId,
        detail: `replica ${dialog?.notificationMode ?? "global"} model ${expectedMode ?? "global"}`,
      })
    }
    if (!model.isUnreadStale(chat.id) && replicaUnread !== state.unreadCount) {
      add({
        property: "dialog.unread",
        chatId,
        detail: `replica ${replicaUnread} model ${state.unreadCount} (readMaxId replica ${replicaRead} model ${state.readMaxId})`,
      })
    }
  }

  for (const bucketId of model.bucketIds()) {
    const id = syncBucketId(bucketKeyFor(bucketId))
    const cursor = replica.buckets.find((bucket) => bucket.id === id)?.seq ?? 0
    const modelSeq = model.bucketSeq(bucketId)
    if (cursor > modelSeq) {
      add({ property: "cursor.not-ahead", detail: `${id}: replica ${cursor} model ${modelSeq}` })
    }
    if (bucketId.startsWith("space:")) {
      const spaceId = BigInt(bucketId.slice("space:".length))
      const expected = model.spaceMembersThrough(spaceId, cursor)
      const stored = new Map(
        replica.spaceMembers
          .filter((member) => BigInt(member.spaceId) === spaceId)
          .map((member) => [BigInt(member.userId), BigInt(member.memberId)]),
      )
      const describe = (members: Map<bigint, bigint>) =>
        Array.from(members)
          .sort(([left], [right]) => (left < right ? -1 : 1))
          .map(([userId, memberId]) => `${userId}#${memberId}`)
          .join(",")
      if (describe(expected) !== describe(stored)) {
        add({
          property: "members.set",
          detail: `${id}@${cursor}: replica [${describe(stored)}] model [${describe(expected)}]`,
        })
      }
    }
    if (bucketId === "user") {
      const expected = model
        .journalKinds(bucketId)
        .filter((entry) => entry.kind === "agentSettings" && entry.seq <= cursor)
        .map((entry) => entry.seq)
      const stored = new Set(
        replica.deferredUpdates
          .filter((update) => update.updateType === "agentSettings")
          .map((update) => update.seq),
      )
      const lost = expected.filter((seq) => !stored.has(seq))
      if (lost.length > 0) {
        add({
          property: "deferred.retained",
          detail: `${id}: records [${lost.join(",")}] passed by the cursor but not stored`,
        })
      }
    }
  }

  const durableText = new Map(replica.messages.map((message) => [message.id, message.message]))
  for (const message of replica.residentMessages) {
    if (!durableText.has(message.id) || durableText.get(message.id) !== message.message) {
      add({
        property: "resident.durable",
        chatId: message.chatId,
        detail: `resident ${message.id} ${JSON.stringify(message.message)} durable ${
          durableText.has(message.id) ? JSON.stringify(durableText.get(message.id)) : "absent"
        }`,
      })
    }
  }

  return divergences
}
