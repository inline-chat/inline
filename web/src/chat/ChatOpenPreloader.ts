import {
  DbObjectKind,
  DbQueryPlanType,
  compareMessagesByWindow,
  type Chat,
  type Dialog,
  type Message,
  type User,
} from "@inline/client/core"
import type {
  ChatID,
  DialogID,
  MessageID,
  UserID,
} from "@inline/ids"
import { authSession } from "../inline/auth/auth-session-core"
import {
  dialogMatchesPeer,
  type InlinePeerRoute,
} from "../inline/data/peer"
import {
  acquireInlineRuntimeCore,
  type InlineRuntimeCore,
} from "../inline/runtime/InlineRuntimeCore"
import { waitUntilInlineCoreCacheReady } from "../inline/runtime/InlineCoreReadiness"
import {
  chatOpenPerformance,
  type ChatOpenPerformance,
} from "./ChatOpenPerformance"
import {
  inlineAvatarMediaDescriptor,
  promoteInlineFirstFrameMedia,
} from "../inline/media/InlineFirstFrameMedia"
import {
  makeMessagePresentation,
  messagePresentationMediaDescriptors,
} from "./MessageContent"

const INITIAL_MESSAGE_LIMIT = 60
const AROUND_BEFORE_LIMIT = 30
const AROUND_AFTER_LIMIT = 29
const PREPARED_PAYLOAD_TTL_MS = 5_000
const CACHE_READY_TIMEOUT_MS = 10_000
const FIRST_FRAME_MESSAGE_LIMIT = 12

export type PreparedChatPayload = {
  preparationId: string
  accountId: UserID
  peer: InlinePeerRoute
  targetMessageId?: MessageID
  dialogId: DialogID
  chatId: ChatID
  pinnedMessageId?: MessageID
  messagesInitialState: Message[]
  preparedMessageIds: MessageID[]
  source: "latest" | "around"
  preparedMessageCount: number
  /** The local projection was valid but had no usable message window. The
   * mounted chat owns the background history refresh; route readiness never
   * waits for realtime. */
  needsHistoryRefresh: boolean
  promotedMediaCount: number
  preparedAt: number
  performanceTraceId: string
}

type CoreLease = {
  core: InlineRuntimeCore
  release: () => void
}

export type ChatOpenPreloaderOptions = {
  targetMessageId?: MessageID
  signal?: AbortSignal
}

export type ChatOpenPreloaderDependencies = {
  acquireCore: (accountId: UserID) => CoreLease
  now?: () => number
  payloadTtlMs?: number
  cacheReadyTimeoutMs?: number
  performance?: ChatOpenPerformance
}

type PreparedEntry = {
  preparationId: string
  promise: Promise<PreparedChatPayload | undefined>
  resolved: boolean
  result: PreparedChatPayload | undefined
  release: () => void
  expiresAt: number
  releaseTimer: ReturnType<typeof setTimeout> | null
}

const abortError = () =>
  new DOMException("Inline chat preload was cancelled", "AbortError")

const withCallerCancellation = <T>(
  promise: Promise<T>,
  signal?: AbortSignal,
) => {
  if (!signal) return promise
  if (signal.aborted) return Promise.reject(abortError())
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(abortError())
    signal.addEventListener("abort", onAbort, { once: true })
    void promise.then(resolve, reject).finally(() => {
      signal.removeEventListener("abort", onAbort)
    })
  })
}

const entryKey = (
  accountId: UserID,
  peer: InlinePeerRoute,
  targetMessageId?: MessageID,
) => `${accountId}:${peer.peerKind}:${peer.peerId}:${targetMessageId ?? "latest"}`

export const likelyVisibleMessagesForChatOpen = (
  messages: readonly Message[],
  targetMessageId?: MessageID,
) => {
  if (messages.length <= FIRST_FRAME_MESSAGE_LIMIT) {
    return [...messages]
  }
  const targetIndex =
    targetMessageId == null
      ? -1
      : messages.findIndex(
          (message) => message.messageId === targetMessageId,
        )
  if (targetIndex < 0) {
    return messages.slice(-FIRST_FRAME_MESSAGE_LIMIT)
  }
  const desiredStart = Math.max(
    0,
    targetIndex - Math.floor(FIRST_FRAME_MESSAGE_LIMIT / 3),
  )
  const end = Math.min(
    messages.length,
    desiredStart + FIRST_FRAME_MESSAGE_LIMIT,
  )
  const start = Math.max(0, end - FIRST_FRAME_MESSAGE_LIMIT)
  return messages.slice(start, end)
}

export class ChatOpenPreloader {
  private readonly entries = new Map<string, PreparedEntry>()
  private nextPreparationNumber = 0
  private readonly now: () => number
  private readonly payloadTtlMs: number
  private readonly cacheReadyTimeoutMs: number
  private readonly performance: ChatOpenPerformance

  constructor(private readonly dependencies: ChatOpenPreloaderDependencies) {
    this.now = dependencies.now ?? Date.now
    this.payloadTtlMs =
      dependencies.payloadTtlMs ?? PREPARED_PAYLOAD_TTL_MS
    this.cacheReadyTimeoutMs =
      dependencies.cacheReadyTimeoutMs ?? CACHE_READY_TIMEOUT_MS
    this.performance = dependencies.performance ?? chatOpenPerformance
  }

  prepare(
    accountId: UserID,
    peer: InlinePeerRoute,
    options: ChatOpenPreloaderOptions = {},
  ) {
    const key = entryKey(accountId, peer, options.targetMessageId)
    const existing = this.entries.get(key)
    if (existing && existing.expiresAt > this.now()) {
      return withCallerCancellation(existing.promise, options.signal)
    }
    if (existing) this.releaseEntry(key, existing)

    const lease = this.dependencies.acquireCore(accountId)
    const preparationId = `prepared-chat-${++this.nextPreparationNumber}`
    const performanceTraceId = this.performance.begin(
      peer,
      options.targetMessageId,
    )
    let released = false
    let releaseChat: (() => void) | undefined
    const retainChat = (release: () => void) => {
      if (released) release()
      else {
        releaseChat?.()
        releaseChat = release
      }
    }
    const promise = this.prepareWithCore(
      lease.core,
      accountId,
      peer,
      options.targetMessageId,
      preparationId,
      performanceTraceId,
      retainChat,
    )
    const entry: PreparedEntry = {
      preparationId,
      promise,
      resolved: false,
      result: undefined,
      release: () => {
        if (released) return
        released = true
        releaseChat?.()
        lease.release()
      },
      expiresAt: Number.POSITIVE_INFINITY,
      releaseTimer: null,
    }
    this.entries.set(key, entry)
    void promise.then(
      (result) => {
        entry.resolved = true
        entry.result = result
        this.markPrepared(key, entry)
      },
      () => {
        this.performance.markFailed(performanceTraceId, "projection")
        this.releaseEntry(key, entry)
      },
    )
    return withCallerCancellation(promise, options.signal)
  }

  /**
   * Returns only a presentation that intent warming has already completed.
   * Route correctness never waits for this optional optimization: an absent
   * result means ChatView mounts immediately and performs its bounded local
   * hydration after commit.
   */
  preparedPresentation(
    accountId: UserID,
    peer: InlinePeerRoute,
    targetMessageId?: MessageID,
  ) {
    const key = entryKey(accountId, peer, targetMessageId)
    const entry = this.entries.get(key)
    if (
      !entry ||
      !entry.resolved ||
      entry.expiresAt <= this.now()
    ) {
      return undefined
    }
    return entry.result
  }

  clear() {
    for (const [key, entry] of this.entries) {
      this.releaseEntry(key, entry)
    }
  }

  /**
   * Ends the preloader-owned projection lease after the mounted chat view has
   * acquired its own lease. This is the renderer equivalent of Inline Mac's
   * consume-once prepared payload handoff and avoids keeping recently opened
   * chats resident for an arbitrary timeout.
   */
  releasePreparedLease(payload: PreparedChatPayload) {
    const key = entryKey(
      payload.accountId,
      payload.peer,
      payload.targetMessageId,
    )
    const entry = this.entries.get(key)
    if (
      !entry ||
      entry.preparationId !== payload.preparationId
    ) {
      return false
    }
    this.releaseEntry(key, entry)
    return true
  }

  private releaseEntry(key: string, entry: PreparedEntry) {
    if (this.entries.get(key) !== entry) return
    this.entries.delete(key)
    if (entry.releaseTimer) clearTimeout(entry.releaseTimer)
    entry.release()
  }

  private markPrepared(key: string, entry: PreparedEntry) {
    if (this.entries.get(key) !== entry) return
    entry.expiresAt = this.now() + this.payloadTtlMs
    entry.releaseTimer = setTimeout(
      () => this.releaseEntry(key, entry),
      this.payloadTtlMs,
    )
  }

  private async prepareWithCore(
    core: InlineRuntimeCore,
    accountId: UserID,
    peer: InlinePeerRoute,
    targetMessageId?: MessageID,
    preparationId?: string,
    performanceTraceId?: string,
    retainChat?: (release: () => void) => void,
  ): Promise<PreparedChatPayload | undefined> {
    let phase = "core cache"
    try {
    void core.start().catch(() => undefined)
    try {
      await waitUntilInlineCoreCacheReady(
        core,
        this.cacheReadyTimeoutMs,
      )
    } catch (error) {
      if (performanceTraceId) {
        this.performance.markFailed(performanceTraceId, "cache")
      }
      throw error
    }
    if (performanceTraceId) {
      this.performance.markCacheReady(performanceTraceId)
    }
    phase = "dialog projection"
    const db = core.client.db
    const findDialog = () =>
      db
        .queryCollection<
          DbObjectKind.Dialog,
          Dialog,
          DbQueryPlanType.Objects
        >(DbQueryPlanType.Objects, DbObjectKind.Dialog)
        .find((candidate) => dialogMatchesPeer(candidate, peer))
    const dialog = findDialog()
    if (!dialog) {
      // A direct cold route still has enough identity to mount ChatView. It
      // will query getChat in the background and adopt the dialog as soon as
      // the owner projects it. A route loader must never become a network
      // loading screen.
      if (performanceTraceId) {
        this.performance.markProjectionReady(performanceTraceId, {
          source: "missing",
          preparedMessageCount: 0,
          promotedMediaCount: 0,
        })
      }
      return undefined
    }

    // Projection is renderer-scoped. Retain the chat before asking the owner
    // database to hydrate so the complete cached window is projected into this
    // renderer before the route is allowed to commit its first frame.
    phase = "resident chat projection"
    retainChat?.(core.fullChatProgressive.activateChat(dialog.chatId))
    const chat = db.get(
      db.ref(DbObjectKind.Chat, dialog.chatId),
    ) as Chat | undefined
    const pinnedMessageId = chat?.pinnedMessageIds?.at(0)
    const residentMessagesForChat = () =>
      db
        .queryCollection<
          DbObjectKind.Message,
          Message,
          DbQueryPlanType.Objects
        >(DbQueryPlanType.Objects, DbObjectKind.Message)
        .filter((message) => message.chatId === dialog.chatId)

    let source: PreparedChatPayload["source"] = "latest"
    if (targetMessageId != null) {
      phase = "target message history"
      const found = await db.loadLocalWindowAroundMessage(
        dialog.chatId,
        {
          messageId: targetMessageId,
          beforeLimit: AROUND_BEFORE_LIMIT,
          afterLimit: AROUND_AFTER_LIMIT,
        },
      )
      if (found) source = "around"
      else {
        // Preserve any useful cached latest window for immediate paint. The
        // mounted chat performs the around-target network request without
        // blocking navigation.
        await db.hydrateMessageWindow(dialog.chatId, {
          limit: INITIAL_MESSAGE_LIMIT,
        })
      }
    } else {
      phase = "latest message history"
      await db.hydrateMessageWindow(
        dialog.chatId,
        { limit: INITIAL_MESSAGE_LIMIT },
      )
    }

    const preparedMessages = residentMessagesForChat()
      .sort(compareMessagesByWindow)
    const firstFrameMessages = likelyVisibleMessagesForChatOpen(
      preparedMessages,
      targetMessageId,
    )
    const firstFrameUsers = firstFrameMessages.map(
      (message) =>
        db.get(
          db.ref(DbObjectKind.User, message.fromId),
        ) as User | undefined,
    )
    if (dialog.peerUserId != null) {
      firstFrameUsers.push(
        db.get(
          db.ref(DbObjectKind.User, dialog.peerUserId),
        ) as User | undefined,
      )
    }
    phase = "first-frame media"
    const promotedMediaCount = await promoteInlineFirstFrameMedia(
      core.mediaRepository,
      [
      ...firstFrameMessages.flatMap((message) =>
        messagePresentationMediaDescriptors(
          makeMessagePresentation(message),
        ),
      ),
      ...firstFrameUsers.map(inlineAvatarMediaDescriptor),
      ],
    )
    const preparedMessageCount = preparedMessages.length
    const knownEmptyChat = chat != null && chat.lastMsgId == null
    const needsHistoryRefresh =
      targetMessageId == null &&
      preparedMessageCount === 0 &&
      !knownEmptyChat
    const payload: PreparedChatPayload = {
      preparationId: preparationId ?? "untracked",
      accountId,
      peer,
      targetMessageId,
      dialogId: dialog.id,
      chatId: dialog.chatId,
      pinnedMessageId,
      messagesInitialState: preparedMessages,
      preparedMessageIds: preparedMessages.map(
        (message) => message.messageId,
      ),
      source,
      preparedMessageCount,
      needsHistoryRefresh,
      promotedMediaCount,
      preparedAt: this.now(),
      performanceTraceId: performanceTraceId ?? "untraced",
    }
    if (performanceTraceId) {
      this.performance.markProjectionReady(performanceTraceId, payload)
    }
    return payload
    } catch (cause) {
      if (cause instanceof Error) throw cause
      throw new Error(
        `Inline chat preparation failed during ${phase}`,
        { cause },
      )
    }
  }

}

export const chatOpenPreloader = new ChatOpenPreloader({
  acquireCore: (accountId) => {
    const state = authSession.getState()
    if (!state.token || state.currentUserId == null) {
      throw new Error("Inline chat preload requires an authenticated session")
    }
    if (state.currentUserId !== accountId) {
      throw new Error("Inline account changed during chat preload")
    }
    return acquireInlineRuntimeCore(accountId)
  },
})

/**
 * Product-owned intent warming. Chat projection and first-frame media are
 * prepared without creating a speculative TanStack match whose cancellation
 * can race the following navigation.
 */
export const prepareChatOpenIntent = (peer: InlinePeerRoute) => {
  const state = authSession.getState()
  if (!state.token || state.currentUserId == null) {
    return Promise.resolve()
  }
  return chatOpenPreloader
    .prepare(state.currentUserId, peer)
    .then(() => undefined, () => undefined)
}
