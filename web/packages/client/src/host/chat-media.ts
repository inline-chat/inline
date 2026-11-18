/**
 * The `chatMedia` query's server side: per subscription, the pages fetched
 * from the server (`SEARCH_MESSAGES` with a filter) and the paging state.
 *
 * Local first: on open, the chat's stored messages that match the filter
 * are read from disk (`Db.scanChatMessages`, newest first, a bounded walk of
 * the `message` primary key) before the subscription's first result, so a
 * media tab of a chat on the device lists on the first frame; resident
 * matches (`chatMediaMatches`) are listed too. While connected the first
 * server page follows; `ensure older` reads further on disk and asks the
 * server for the next page. Pages commit to the replica (`store: true`), like
 * `GET_MESSAGES` results, so every listed row is on disk; a page certifies no
 * history range. The keys a disk read or a page named are kept per
 * subscription, so their rows stay listed even when they are not resident
 * (the materializer reads them from disk once). `loading` is the server
 * page only.
 */
import { SearchMessagesFilter } from "@inline-chat/protocol/core"
import type { ChatMediaFilter, ChatMediaResource, QueryDescriptor } from "@inline/core-protocol"
import { messageId as makeMessageId, type ChatID, type MessageID } from "@inline/ids"
import type { Log } from "@inline/log"
import type { Db } from "../database"
import { messageKey, type MessageKey } from "../database/models"
import type { RealtimeClient } from "../realtime/realtime"
import { searchMessages } from "../realtime/transactions/search-messages"
import { chatMediaMatches } from "../queries/chat-media"
import { inputPeerForChat } from "./peers"

export { chatMediaMatches } from "../queries/chat-media"

/** Messages per server page. */
export const CHAT_MEDIA_PAGE_SIZE = 50

/**
 * Disk reads: matches per read, and rows read at most (each row is decoded,
 * about 4 µs). Measured on one chat of 100,000 seeded messages, 5% photos
 * (`database/__tests__/chat-scan.test.ts`): the first 50 photos in 4.5 ms
 * (1,077 rows); a filter with no match stops at the budget in 7.3 ms; the
 * whole chat would take 387 ms, which is why a read is bounded and
 * `ensure older` continues it.
 */
export const CHAT_MEDIA_LOCAL = { limit: 50, firstScan: 2_000, olderScan: 5_000 } as const

const SERVER_FILTER: Record<ChatMediaFilter, SearchMessagesFilter> = {
  photosVideos: SearchMessagesFilter.FILTER_PHOTO_VIDEO,
  photos: SearchMessagesFilter.FILTER_PHOTOS,
  videos: SearchMessagesFilter.FILTER_VIDEOS,
  files: SearchMessagesFilter.FILTER_DOCUMENTS,
  voice: SearchMessagesFilter.FILTER_VOICE_MEMOS,
  links: SearchMessagesFilter.FILTER_LINKS,
}

type Entry = {
  chatId: ChatID
  filter: ChatMediaFilter
  /** Keys the disk reads and the server's pages listed. */
  listedKeys: Set<MessageKey>
  /** Where the next disk read starts; undefined before the first. */
  localBelow?: MessageID
  localExhausted: boolean
  localReading: boolean
  /** The oldest message ID a page listed: the next page's offset. */
  oldest?: bigint
  loading: boolean
  hasMore: boolean
  fetched: boolean
  failed: boolean
  /** Bumped on close, so a late page is dropped. */
  live: boolean
}

export type HostChatMediaOptions = {
  db: Db
  realtime: RealtimeClient
  online: () => boolean
  onChange: (handle: number) => void
  track: <T>(task: Promise<T>) => Promise<T>
  log: Log
}

export class HostChatMedia {
  private readonly entries = new Map<number, Entry>()
  private stopped = false

  constructor(private readonly options: HostChatMediaOptions) {}

  /**
   * Start a subscription. Resolves once the device's first matches are
   * resident and listed (never rejects): publish its first result then.
   */
  open(handle: number, query: Extract<QueryDescriptor, { kind: "chatMedia" }>): Promise<void> {
    this.close(handle)
    const entry: Entry = {
      chatId: query.chatId,
      filter: query.filter,
      listedKeys: new Set(),
      localExhausted: false,
      localReading: false,
      loading: false,
      hasMore: true,
      fetched: false,
      failed: false,
      live: true,
    }
    this.entries.set(handle, entry)
    if (this.options.online()) this.fetch(handle, entry)
    return this.readLocal(handle, entry, CHAT_MEDIA_LOCAL.firstScan)
  }

  close(handle: number) {
    const entry = this.entries.get(handle)
    if (!entry) return
    entry.live = false
    this.entries.delete(handle)
  }

  /** `ensure older` on the subscription: more from disk, and the next server page when there may be one. */
  older(handle: number) {
    const entry = this.entries.get(handle)
    if (!entry) return
    if (!entry.localExhausted && !entry.localReading) {
      void this.readLocal(handle, entry, CHAT_MEDIA_LOCAL.olderScan)
    }
    if (entry.loading || !entry.hasMore || !this.options.online()) return
    this.fetch(handle, entry)
  }

  /** The connection came back: subscriptions that never got a page fetch their first. */
  setOnline(online: boolean) {
    if (!online) return
    for (const [handle, entry] of this.entries) {
      if (!entry.fetched && !entry.loading) this.fetch(handle, entry)
    }
  }

  stop() {
    this.stopped = true
    for (const entry of this.entries.values()) entry.live = false
    this.entries.clear()
  }

  /** What the materializer needs for a subscription. */
  state(handle: number): { listedKeys: ReadonlySet<MessageKey>; resource: ChatMediaResource } | undefined {
    const entry = this.entries.get(handle)
    if (!entry) return undefined
    return {
      listedKeys: entry.listedKeys,
      resource: {
        kind: "chatMedia",
        loading: entry.loading,
        // Once the server answered, its paging decides; before, more on disk counts.
        hasMore: entry.hasMore || (!entry.fetched && !entry.localExhausted),
        fetched: entry.fetched,
        ...(entry.failed ? { failed: true } : {}),
      },
    }
  }

  /** One bounded disk read below the last one; its matches join the list. */
  private async readLocal(handle: number, entry: Entry, maxScanned: number): Promise<void> {
    if (this.stopped || entry.localExhausted || entry.localReading) return
    entry.localReading = true
    try {
      const filter = entry.filter
      const scan = await this.options.track(
        this.options.db.scanChatMessages(entry.chatId, (message) => chatMediaMatches(message, filter), {
          limit: CHAT_MEDIA_LOCAL.limit,
          maxScanned,
          ...(entry.localBelow != null ? { beforeMessageId: entry.localBelow } : {}),
        }),
      )
      if (!entry.live) return
      if (!scan) {
        // No disk to read (an in-memory replica): resident rows are all there is.
        entry.localExhausted = true
      } else {
        for (const message of scan.matches) entry.listedKeys.add(message.id)
        if (scan.lowest != null) entry.localBelow = scan.lowest
        entry.localExhausted = scan.exhausted
      }
    } catch (error) {
      // The list still shows resident rows and server pages.
      this.options.log.warn("chatMedia.local.failed", { error })
      entry.localExhausted = true
    } finally {
      entry.localReading = false
    }
    if (entry.live) this.options.onChange(handle)
  }

  private fetch(handle: number, entry: Entry) {
    if (this.stopped) return
    entry.loading = true
    entry.failed = false
    this.options.onChange(handle)
    const transaction = searchMessages({
      chatId: entry.chatId,
      peerId: inputPeerForChat(this.options.db, entry.chatId),
      filter: SERVER_FILTER[entry.filter],
      limit: CHAT_MEDIA_PAGE_SIZE,
      ...(entry.oldest != null ? { offsetId: entry.oldest } : {}),
      store: true,
    })
    void this.options.track(
      this.options.realtime.execute(transaction).then(
        () => {
          if (!entry.live) return
          const messages = (transaction.result?.messages ?? []).filter(
            (message) => String(message.chatId) === entry.chatId && message.id > 0n,
          )
          for (const message of messages) {
            entry.listedKeys.add(messageKey(entry.chatId, makeMessageId(message.id)))
            if (entry.oldest == null || message.id < entry.oldest) entry.oldest = message.id
          }
          entry.loading = false
          entry.fetched = true
          entry.hasMore = messages.length >= CHAT_MEDIA_PAGE_SIZE
          this.options.onChange(handle)
        },
        (error: unknown) => {
          if (!entry.live) return
          this.options.log.warn("chatMedia.page.failed", { error })
          entry.loading = false
          entry.failed = true
          this.options.onChange(handle)
        },
      ),
    )
  }
}
