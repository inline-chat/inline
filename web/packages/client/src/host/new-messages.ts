/**
 * The feed behind the `newMessages` query: incoming messages that arrived
 * live, for notifications. The rule is `NEW_MESSAGES_RULE` in
 * `@inline/core-protocol`, after the Mac app's `MacNotifications`:
 *
 * 1. `noteDelivered` sees the updates of every push and catch-up page before
 *    they apply (`HostSyncEngine`); each `newMessage` names a candidate key.
 *    History pages, repairs and disk reads never pass through it.
 * 2. When a committed batch inserts a candidate that the committed view did
 *    not hold before (`candidates`, called before the view applies the
 *    batch), and after the batch (`admit`) it is incoming, not silent, above
 *    the dialog's read frontier and at most `maxAgeSeconds` old, it joins
 *    the feed with the next sequence number.
 * 3. Entries leave after `retainSeconds` or when more than `limit` are held.
 *
 * Each subscription remembers the sequence it started at and lists only
 * entries after it, so the list is append-only from the subscriber's view
 * except for releases at its head.
 */
import type { Update } from "@inline-chat/protocol/core"
import { NEW_MESSAGES_RULE } from "@inline/core-protocol"
import { chatId as makeChatId, compareInlineIds, messageId as makeMessageId, type UserID } from "@inline/ids"
import type { DbResidentChangeBatch } from "../database"
import { DbObjectKind, messageKey, type Message, type MessageKey } from "../database/models"
import { MessageSendMode } from "@inline-chat/protocol/core"
import type { ReplicaView } from "../queries/view"

export type FeedEntry = {
  key: MessageKey
  seq: number
  /** Milliseconds since the epoch. */
  arrivedAt: number
}

export type NewMessageFeedOptions = {
  userId: UserID
  /** Milliseconds since the epoch. */
  now: () => number
  onChange: () => void
  limit?: number
  maxAgeSeconds?: number
  retainSeconds?: number
}

/** How long a delivered update may wait for its commit before it is forgotten. */
const CANDIDATE_TTL_MS = 60_000

export class NewMessageFeed {
  private readonly candidates = new Map<MessageKey, number>()
  private entries: FeedEntry[] = []
  private seq = 0
  private timer: ReturnType<typeof setTimeout> | undefined
  private stopped = false
  private readonly limit: number
  private readonly maxAgeSeconds: number
  private readonly retainMs: number

  constructor(private readonly options: NewMessageFeedOptions) {
    this.limit = options.limit ?? NEW_MESSAGES_RULE.limit
    this.maxAgeSeconds = options.maxAgeSeconds ?? NEW_MESSAGES_RULE.maxAgeSeconds
    this.retainMs = (options.retainSeconds ?? NEW_MESSAGES_RULE.retainSeconds) * 1_000
  }

  /** The sequence a new subscription starts after. */
  get cursor() {
    return this.seq
  }

  /** Keys of entries after `since`, oldest first. */
  since(since: number): MessageKey[] {
    return this.entries.filter((entry) => entry.seq > since).map((entry) => entry.key)
  }

  /** Updates about to apply from a push or a catch-up page. */
  noteDelivered(updates: readonly Update[]) {
    if (this.stopped) return
    const now = this.options.now()
    for (const [key, at] of this.candidates) {
      if (now - at > CANDIDATE_TTL_MS) this.candidates.delete(key)
    }
    for (const update of updates) {
      if (update.update.oneofKind !== "newMessage") continue
      const message = update.update.newMessage.message
      if (!message || message.id <= 0n) continue
      this.candidates.set(messageKey(makeChatId(message.chatId), makeMessageId(message.id)), now)
    }
  }

  /**
   * Candidate messages this batch inserts for the first time. Call before
   * the committed view applies the batch.
   */
  insertedCandidates(batch: DbResidentChangeBatch, before: ReplicaView): MessageKey[] {
    if (this.candidates.size === 0) return []
    const inserted: MessageKey[] = []
    for (const change of batch.changes) {
      if (change.kind !== DbObjectKind.Message || !change.object) continue
      const key = change.id as MessageKey
      if (!this.candidates.has(key)) continue
      this.candidates.delete(key)
      if (before.get(DbObjectKind.Message, key) == null) inserted.push(key)
    }
    return inserted
  }

  /** Admit inserted candidates that pass the rule. Call after the view applied the batch. */
  admit(keys: readonly MessageKey[], view: ReplicaView) {
    if (keys.length === 0 || this.stopped) return
    const now = this.options.now()
    let added = false
    for (const key of keys) {
      const message = view.get(DbObjectKind.Message, key)
      if (!message || !this.qualifies(message, view, now)) continue
      this.entries.push({ key, seq: ++this.seq, arrivedAt: now })
      added = true
    }
    if (!added) return
    if (this.entries.length > this.limit) this.entries.splice(0, this.entries.length - this.limit)
    this.schedule()
    this.options.onChange()
  }

  private qualifies(message: Message, view: ReplicaView, now: number) {
    if (message.out === true || message.fromId === this.options.userId) return false
    if (message.sendMode === MessageSendMode.MODE_SILENT) return false
    if (message.date == null || now / 1_000 - message.date > this.maxAgeSeconds) return false
    const dialog = view
      .all(DbObjectKind.Dialog)
      .find((candidate) => candidate.chatId === message.chatId)
    const readMaxId = dialog?.readMaxId
    return readMaxId == null || compareInlineIds(message.messageId, readMaxId) > 0
  }

  private schedule() {
    if (this.timer || this.stopped) return
    const head = this.entries[0]
    if (!head) return
    const delay = Math.max(0, head.arrivedAt + this.retainMs - this.options.now())
    this.timer = setTimeout(() => {
      this.timer = undefined
      this.expire()
    }, delay)
  }

  private expire() {
    if (this.stopped) return
    const now = this.options.now()
    const before = this.entries.length
    this.entries = this.entries.filter((entry) => now - entry.arrivedAt < this.retainMs)
    if (this.entries.length !== before) this.options.onChange()
    this.schedule()
  }

  stop() {
    this.stopped = true
    if (this.timer) clearTimeout(this.timer)
    this.timer = undefined
    this.candidates.clear()
    this.entries = []
  }
}
