/**
 * Chat windows for `chatWindow` subscriptions, built on the replica's
 * `FullChatWindowState` (one contiguous window per chat, shared by every
 * subscription to that chat) and the existing history transaction.
 *
 * - Opening reads the local window first, so rows on the device arrive in the
 *   subscription's first result, then refreshes from the server in the
 *   background.
 * - While connected, an older or newer page comes from local rows only
 *   inside the certified range next to the window (core.md invariant 5);
 *   anything else comes from the server, so a local page never stitches
 *   cached rows across a hole. Offline, local pages are used.
 * - The window resource's edges (`hasOlder`, `hasNewer`, `atLatest`) are
 *   computed from the stored coverage in `queries/compute.ts`.
 * - A server result for a window that has since moved is discarded by the
 *   replica's window intent versions.
 */
import type { WindowAnchor, WindowResource } from "@inline/core-protocol"
import {
  compareInlineIds,
  messageId as makeMessageId,
  type ChatID,
  type MessageID,
} from "@inline/ids"
import { Log } from "@inline/log"
import type { Db } from "../database"
import { certifiedRangeAt, HISTORY_TOP, isCertified } from "../database/history-coverage"
import { compareMessagesByWindow, messageWindowCursor } from "../database/message-window"
import { DbObjectKind, messageKey, type Message, type MessageKey } from "../database/models"
import type { RealtimeClient } from "../realtime/realtime"
import {
  getChatHistory,
  GetChatHistoryMode,
  type GetChatHistoryContext,
} from "../realtime/transactions"
import { isServerMessageId } from "../queries/rows"
import { dialogForChat, inputPeerForChat } from "./peers"

export type EnsureRange = "older" | "newer" | "latest" | { around: MessageID }

type Loading = WindowResource["loading"]

type WindowEntry = {
  refs: number
  /** Operations in flight, by kind; the resource shows the most relevant. */
  loading: Map<Exclude<Loading, "none">, number>
  /** An older load found no rows below the window (see `windowEdges`). */
  olderExhausted: boolean
  /** `ensure` work in flight, by range, so a repeated request joins it. */
  ensuring: Map<string, Promise<void>>
}

export type ChatWindowsOptions = {
  db: Db
  realtime: RealtimeClient
  pageSize: number
  logger: Log
  /** Window state changed in a way the replica does not notify. */
  onChange: (chatId: ChatID) => void
  /** Keep bounded local work visible to `CoreHost.idle()`. */
  track: <T>(task: Promise<T>) => Promise<T>
}

export class ChatWindows {
  private readonly windows = new Map<ChatID, WindowEntry>()

  constructor(private readonly options: ChatWindowsOptions) {}

  state(chatId: ChatID): Pick<WindowResource, "loading"> & { olderExhausted: boolean } {
    const entry = this.windows.get(chatId)
    if (!entry) return { loading: "none", olderExhausted: false }
    const loading: Loading = entry.loading.has("initial")
      ? "initial"
      : entry.loading.has("older")
        ? "older"
        : entry.loading.has("newer")
          ? "newer"
          : "none"
    return { loading, olderExhausted: entry.olderExhausted }
  }

  /**
   * Take a reference on a chat's window and load it. Resolves once the local
   * window is in memory, with the read boundary to show.
   */
  async open(chatId: ChatID, anchor: WindowAnchor): Promise<{ unreadBoundary?: MessageID }> {
    const { db } = this.options
    const readMaxId = dialogForChat(db, chatId)?.readMaxId
    const boundary = readMaxId ? { unreadBoundary: readMaxId } : {}
    const existing = this.windows.get(chatId)
    if (existing) {
      existing.refs += 1
      return boundary
    }
    this.windows.set(chatId, {
      refs: 1,
      loading: new Map(),
      olderExhausted: false,
      ensuring: new Map(),
    })
    db.activateResidentMessageWindow(chatId)
    let around: MessageID | undefined
    if (typeof anchor === "object") {
      around = anchor.around
    } else if (anchor === "unread") {
      const lastMsgId = db.get(db.ref(DbObjectKind.Chat, chatId))?.lastMsgId
      if (readMaxId && lastMsgId && compareInlineIds(readMaxId, lastMsgId) < 0) {
        around = readMaxId
      }
    }
    if (around) await this.loadAround(chatId, around)
    else await this.loadLatest(chatId, false)
    return boundary
  }

  close(chatId: ChatID) {
    const entry = this.windows.get(chatId)
    if (!entry) return
    entry.refs -= 1
    if (entry.refs > 0) return
    this.windows.delete(chatId)
    this.options.db.releaseResidentMessageWindow(chatId)
  }

  closeAll() {
    for (const chatId of Array.from(this.windows.keys())) {
      this.windows.delete(chatId)
      this.options.db.releaseResidentMessageWindow(chatId)
    }
  }

  /**
   * Load more of a window. A request for a range that is already loading
   * joins that load, and one for a range already in the window (the latest
   * end when the window is at latest, an anchor already shown) does nothing:
   * the timeline may ask more than once.
   */
  ensure(chatId: ChatID, range: EnsureRange): Promise<void> {
    const entry = this.windows.get(chatId)
    if (!entry) return Promise.resolve()
    const { db } = this.options
    if (range === "latest" && db.fullChatWindows.isAtLatest(chatId)) {
      return entry.ensuring.get("latest") ?? Promise.resolve()
    }
    if (
      typeof range === "object" &&
      db.fullChatWindows.contains(chatId, messageKey(chatId, range.around))
    ) {
      return Promise.resolve()
    }
    // The page a request names: "older" from the current oldest row is one
    // page, and "older" after that page has landed is the next one.
    const messages = this.windowMessages(chatId)
    const key =
      typeof range === "object"
        ? `around:${range.around}`
        : range === "older"
          ? `older:${messages.at(0)?.id ?? ""}`
          : range === "newer"
            ? `newer:${messages.at(-1)?.id ?? ""}`
            : range
    const inFlight = entry.ensuring.get(key)
    if (inFlight) return inFlight
    const task = (async () => {
      if (range === "latest") return this.loadLatest(chatId, true)
      if (typeof range === "object") return this.loadAround(chatId, range.around)
      if (range === "older") return this.loadOlder(chatId)
      return this.loadNewer(chatId)
    })().finally(() => {
      if (entry.ensuring.get(key) === task) entry.ensuring.delete(key)
    })
    entry.ensuring.set(key, task)
    return task
  }

  /**
   * Release the window's rows outside `keep` (inclusive message IDs) from
   * memory, as the UI trims what it renders. Local sends stay. The rows stay
   * on disk and coverage is untouched: trimming memory is not losing
   * history, and a later page reads them back.
   */
  trim(chatId: ChatID, keep: { from: MessageID; to: MessageID }) {
    if (!this.windows.has(chatId)) return
    const { db } = this.options
    const from = BigInt(keep.from)
    const to = BigInt(keep.to)
    if (from > to) return
    const members = this.windowMessages(chatId)
    const kept = members.filter((message) => {
      if (!isServerMessageId(message.messageId)) return true
      const id = BigInt(message.messageId)
      return id >= from && id <= to
    })
    if (kept.length === members.length) return
    const droppedNewer = members.some(
      (message) => isServerMessageId(message.messageId) && BigInt(message.messageId) > to,
    )
    const droppedOlder = members.some(
      (message) => isServerMessageId(message.messageId) && BigInt(message.messageId) < from,
    )
    db.replaceResidentMessageWindow(
      chatId,
      kept.map((message) => message.id),
      db.fullChatWindows.isAtLatest(chatId) && !droppedNewer,
    )
    db.reconcileResidentMessageWindow(chatId)
    const entry = this.windows.get(chatId)
    if (entry && droppedOlder) entry.olderExhausted = false
    this.options.onChange(chatId)
  }

  private async loadOlder(chatId: ChatID) {
    const { db, pageSize } = this.options
    const messages = this.windowMessages(chatId)
    const oldest = messages.at(0)
    if (!oldest) return
    const oldestServer = messages.find((message) => isServerMessageId(message.messageId))
    if (!this.connected() || !oldestServer) {
      await this.local(chatId, "older", () =>
        db.hydrateMessageWindow(chatId, { limit: pageSize, before: messageWindowCursor(oldest) }),
      )
      return
    }
    const ranges = db.historyCoverage(chatId)
    // Rows shown below the window's certified run (a first frame or an
    // offline page) are not proven contiguous with it: page from the bottom
    // of the run, so the server re-proves them and the ranges join.
    const newestServer = messages
      .slice()
      .reverse()
      .find((message) => isServerMessageId(message.messageId))
    const run = newestServer ? certifiedRangeAt(ranges, BigInt(newestServer.messageId)) : undefined
    if (run && BigInt(oldestServer.messageId) < run[0]) {
      await this.fetch(chatId, "older", {
        mode: GetChatHistoryMode.HISTORY_MODE_OLDER,
        beforeId: makeMessageId(run[0]),
        limit: pageSize,
      })
      return
    }
    const lowest = BigInt(oldestServer.messageId)
    if (lowest <= 1n) return
    if (
      this.windows.get(chatId)?.olderExhausted &&
      isCertified(ranges, 1n, lowest - 1n)
    ) {
      return
    }
    const below = certifiedRangeAt(ranges, lowest - 1n)
    if (below) {
      // Certified right below the window: its stored rows are the history.
      const count = await this.local(chatId, "older", () =>
        db.hydrateMessageWindow(chatId, {
          limit: pageSize,
          before: messageWindowCursor(oldestServer),
          minMessageId: makeMessageId(below[0]),
        }),
      )
      if ((count ?? 0) > 0) return
      if (below[0] <= 1n) {
        this.markOlderExhausted(chatId)
        return
      }
      // The certified run holds no rows: page on from below it.
      await this.fetch(chatId, "older", {
        mode: GetChatHistoryMode.HISTORY_MODE_OLDER,
        beforeId: makeMessageId(below[0]),
        limit: pageSize,
      })
      return
    }
    await this.fetch(chatId, "older", {
      mode: GetChatHistoryMode.HISTORY_MODE_OLDER,
      beforeId: oldestServer.messageId,
      limit: pageSize,
    })
  }

  private async loadNewer(chatId: ChatID) {
    const { db, pageSize } = this.options
    if (db.fullChatWindows.isAtLatest(chatId)) return
    const messages = this.windowMessages(chatId)
    const newest = messages.at(-1)
    if (!newest) return
    const newestServer = messages
      .slice()
      .reverse()
      .find((message) => isServerMessageId(message.messageId))
    if (!this.connected() || !newestServer) {
      await this.local(chatId, "newer", () =>
        db.hydrateMessageWindow(chatId, { limit: pageSize, after: messageWindowCursor(newest) }),
      )
      return
    }
    const ranges = db.historyCoverage(chatId)
    const oldestServer = messages.find((message) => isServerMessageId(message.messageId))
    const run = oldestServer ? certifiedRangeAt(ranges, BigInt(oldestServer.messageId)) : undefined
    if (run && run[1] < HISTORY_TOP && BigInt(newestServer.messageId) > run[1]) {
      await this.fetch(chatId, "newer", {
        mode: GetChatHistoryMode.HISTORY_MODE_NEWER,
        afterId: makeMessageId(run[1]),
        limit: pageSize,
      })
      return
    }
    const highest = BigInt(newestServer.messageId)
    const above = certifiedRangeAt(ranges, highest + 1n)
    if (above) {
      const count = await this.local(chatId, "newer", () =>
        db.hydrateMessageWindow(chatId, {
          limit: pageSize,
          after: messageWindowCursor(newestServer),
          ...(above[1] < HISTORY_TOP ? { maxMessageId: makeMessageId(above[1]) } : {}),
        }),
      )
      if ((count ?? 0) > 0 || above[1] >= HISTORY_TOP) return
      await this.fetch(chatId, "newer", {
        mode: GetChatHistoryMode.HISTORY_MODE_NEWER,
        afterId: makeMessageId(above[1]),
        limit: pageSize,
      })
      return
    }
    await this.fetch(chatId, "newer", {
      mode: GetChatHistoryMode.HISTORY_MODE_NEWER,
      afterId: newestServer.messageId,
      limit: pageSize,
    })
  }

  private async loadLatest(chatId: ChatID, promote: boolean) {
    const { db, pageSize } = this.options
    // While connected, show only the certified run that holds the chat's
    // newest message; the server page that follows extends it.
    const lastMsgId = db.get(db.ref(DbObjectKind.Chat, chatId))?.lastMsgId
    const run =
      this.connected() && lastMsgId && isServerMessageId(lastMsgId)
        ? certifiedRangeAt(db.historyCoverage(chatId), BigInt(lastMsgId))
        : undefined
    const bound = run ? { minMessageId: makeMessageId(run[0]) } : {}
    await this.local(chatId, "initial", () =>
      promote
        ? db.promoteResidentMessageWindowToLatest(chatId, pageSize)
        : db.hydrateMessageWindow(chatId, { limit: pageSize, ...bound }).then(() => undefined),
    )
    this.refresh(chatId, {
      mode: GetChatHistoryMode.HISTORY_MODE_LATEST,
      limit: pageSize,
    })
  }

  private async loadAround(chatId: ChatID, messageId: MessageID) {
    const { db, pageSize } = this.options
    const half = Math.floor(pageSize / 2)
    const found = await this.local(chatId, "initial", () =>
      db.loadLocalWindowAroundMessage(chatId, {
        messageId,
        beforeLimit: half,
        afterLimit: half,
      }),
    )
    if (!found) {
      // Nothing local around the anchor: show the latest local window until
      // the server answers rather than an empty one.
      await this.local(chatId, "initial", () => db.hydrateMessageWindow(chatId, { limit: pageSize }))
    }
    this.refresh(chatId, {
      mode: GetChatHistoryMode.HISTORY_MODE_AROUND,
      anchorId: messageId,
      beforeLimit: half,
      afterLimit: half,
      includeAnchor: true,
    })
  }

  /** Background server refresh. Shows a spinner only when the window is empty. */
  private refresh(chatId: ChatID, context: Omit<GetChatHistoryContext, "peerId">) {
    const empty = this.windowMessages(chatId).length === 0
    void this.fetch(chatId, empty ? "initial" : null, context)
  }

  private async local<T>(chatId: ChatID, loading: Exclude<Loading, "none">, load: () => Promise<T>) {
    const done = this.begin(chatId, loading)
    try {
      return await this.options.track(load())
    } catch (error) {
      this.options.logger.warn("window.local.failed", { error })
      return undefined
    } finally {
      done()
    }
  }

  private async fetch(
    chatId: ChatID,
    loading: Exclude<Loading, "none"> | null,
    context: Omit<GetChatHistoryContext, "peerId">,
  ) {
    const { db, realtime } = this.options
    const done = loading ? this.begin(chatId, loading) : () => this.options.onChange(chatId)
    try {
      const result = await realtime.query(
        getChatHistory({ ...context, peerId: inputPeerForChat(db, chatId) }),
      )
      if (
        context.mode === GetChatHistoryMode.HISTORY_MODE_OLDER &&
        result?.oneofKind === "getChatHistory" &&
        result.getChatHistory.messages.length === 0
      ) {
        // An empty older page certified everything below its boundary.
        this.markOlderExhausted(chatId)
      }
    } catch (error) {
      // Stopped or failed: the window keeps what it has.
      this.options.logger.debug("window.fetch.failed", { error })
    } finally {
      done()
    }
  }

  private markOlderExhausted(chatId: ChatID) {
    const entry = this.windows.get(chatId)
    if (!entry || entry.olderExhausted) return
    entry.olderExhausted = true
    this.options.onChange(chatId)
  }

  private begin(chatId: ChatID, loading: Exclude<Loading, "none">) {
    const entry = this.windows.get(chatId)
    if (entry) entry.loading.set(loading, (entry.loading.get(loading) ?? 0) + 1)
    this.options.onChange(chatId)
    return () => {
      const count = entry?.loading.get(loading) ?? 0
      if (count <= 1) entry?.loading.delete(loading)
      else entry?.loading.set(loading, count - 1)
      this.options.onChange(chatId)
    }
  }

  private windowMessages(chatId: ChatID): Message[] {
    const { db } = this.options
    return db.fullChatWindows
      .keys(chatId)
      .flatMap((key) => {
        const message = db.get(db.ref(DbObjectKind.Message, key as MessageKey))
        return message ? [message] : []
      })
      .sort(compareMessagesByWindow)
  }

  private connected() {
    return this.options.realtime.connectionState === "connected"
  }
}
