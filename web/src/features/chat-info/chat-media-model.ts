/**
 * One shared-media tab of the chat info pane: Media (photos and videos),
 * Files, Voice or Links, over the core's `chatMedia` query. Framework-free;
 * `ChatMediaTab.tsx` renders it.
 *
 * Mac reference: `InlineMac/Views/ChatInfo/ChatInfo.swift` (`ChatInfoMediaList`:
 * a grid of square cells, adaptive with a 100 pt minimum and 4 pt gaps;
 * `ChatInfoDocumentRow`, `ChatInfoVoiceMemoRow`, `ChatInfoLinkRow`: rows) and
 * `ChatInfoResourceFooter.swift` (the footer's words).
 *
 * - **Local first.** The core lists what is on the device in its first
 *   result (the newest 2,000 rows read) and the server page fills in; the
 *   list shows as soon as the subscription answers, never an empty flash.
 * - **Pages.** `loadMore()` is `ensure older`, only while the core says
 *   there may be more and no page is loading. The grid asks when its last
 *   row comes near (`sentinel`), and when the keyboard reaches the end.
 * - **States** (`footer`): `pending` (nothing answered: draw nothing),
 *   `loading` ("Loading history…" under the rows the device has), `more`
 *   (a page can be asked for), `failed` ("Couldn't load history." and
 *   Retry, which subscribes again), `end`, and `empty` with the Mac's
 *   words once the list is answered and empty.
 * - **Rows are pure.** Each item is prepared here (file name stripped of
 *   bidi controls, sizes, durations, dates, the link's URL through the link
 *   allowlist) in one cached computed per row key.
 */

import {
  formatDuration,
  formatFileSize,
  safeLink,
  userDisplayName,
} from "@inline/chat-ui"
import type {
  ChatMediaFilter,
  ChatMediaResource,
  MediaContent,
  MessageRow,
  MessageRowId,
  PhotoInfo,
  RowKey,
  VideoInfo,
  VoiceInfo,
} from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import { batch, computed, effect, plainEqual, signal, untracked, type ReadSignal, type StoreClient, type SubscriptionHandle } from "@inline/reactive"
import type { Part } from "@inline/ui"
import type { MediaOwner } from "../content/sources"
import { displayFileName } from "../content/file-name"

/** The pane's media tabs, in the Mac's order. */
export type ChatMediaTabId = "media" | "files" | "voice" | "links"

export const CHAT_MEDIA_FILTERS: Readonly<Record<ChatMediaTabId, ChatMediaFilter>> = {
  media: "photosVideos",
  files: "files",
  voice: "voice",
  links: "links",
}

/** The Mac's empty-state words (`ChatInfo.swift`, `emptyMessage:`). */
export const CHAT_MEDIA_EMPTY: Readonly<Record<ChatMediaTabId, string>> = {
  media: "No media found in this chat.",
  files: "No files found in this chat.",
  voice: "No voice memos found in this chat.",
  links: "No links found in this chat.",
}

type Base = {
  readonly key: RowKey
  readonly rowId: MessageRowId
  readonly messageId: MessageID | undefined
  readonly owner: MediaOwner
  /** "Nov 17, 2026". */
  readonly dateText: string
  readonly senderName: string
}

export type ChatMediaItem =
  | (Base & {
      readonly kind: "media"
      readonly media: MediaContent
      /** What the cell draws: the photo, or the video's poster. */
      readonly photo: PhotoInfo | undefined
      readonly video: VideoInfo | undefined
      /** "0:12" for a video. */
      readonly durationText?: string
      /** "Photo, Nov 17, 2026" or "Video, 0:12, Nov 17, 2026". */
      readonly label: string
    })
  | (Base & {
      readonly kind: "file"
      readonly media: MediaContent
      readonly fileName: string
      readonly sizeText: string
      /** "PDF", from the name's extension or the type. */
      readonly typeText: string
    })
  | (Base & {
      readonly kind: "voice"
      readonly voice: VoiceInfo
      readonly durationText: string
    })
  | (Base & {
      readonly kind: "link"
      /** Safe to open (the link allowlist); undefined when no link passes it. */
      readonly url: string | undefined
      readonly title: string
      readonly subtitle: string | undefined
    })

export type ChatMediaFooter =
  | { readonly kind: "pending" }
  | { readonly kind: "loading"; readonly empty: boolean }
  | { readonly kind: "more" }
  | { readonly kind: "failed" }
  | { readonly kind: "end" }
  | { readonly kind: "empty"; readonly text: string }

export type ChatMediaModelOptions = {
  readonly client: StoreClient
  readonly chatId: ChatID
  readonly tab: ChatMediaTabId
  /** Default: the browser's medium date. */
  readonly formatDate?: (seconds: number) => string
  readonly locale?: string
}

export type ChatMediaModel = {
  readonly tab: ChatMediaTabId
  readonly filter: ChatMediaFilter
  /** Message row keys, newest first. A list view observes only this. */
  readonly ids: ReadSignal<readonly RowKey[]>
  /** One cached computed per key. */
  item(key: RowKey): ReadSignal<ChatMediaItem | undefined>
  readonly footer: ReadSignal<ChatMediaFooter>
  /** The core's resource, for labs and diagnostics. */
  readonly resource: ReadSignal<ChatMediaResource | undefined>
  /** Ask for the next older page, if there may be one and none is loading. Returns whether it asked. */
  loadMore(): boolean
  /** After a failure: subscribe again (the core fetches on subscribe). */
  retry(): void
  /** An element after the last row: near the viewport, it asks for the next page (and again while it stays near). */
  readonly sentinel: Part
  dispose(): void
}

const defaultDate = (() => {
  let format: Intl.DateTimeFormat | undefined
  return (seconds: number) => {
    format ??= new Intl.DateTimeFormat(undefined, { dateStyle: "medium" })
    return format.format(new Date(seconds * 1000))
  }
})()

const extension = (name: string, mimeType: string): string => {
  const dot = name.lastIndexOf(".")
  const ext = dot > 0 && dot < name.length - 1 ? name.slice(dot + 1) : mimeType.split("/")[1] ?? ""
  return ext.slice(0, 5).toUpperCase()
}

/** The first link a message carries: a preview's URL, then a text link, then a URL in its text. */
const linkOf = (row: MessageRow): { url: string | undefined; title: string; subtitle: string | undefined } => {
  const preview = row.attachments?.find((attachment) => attachment.kind === "urlPreview")
  const candidates: string[] = []
  if (preview?.kind === "urlPreview" && preview.url) candidates.push(preview.url)
  for (const entity of row.entities ?? []) {
    if (entity.type === "textUrl" && entity.url) candidates.push(entity.url)
    else if (entity.type === "url") candidates.push(row.text.slice(entity.offset, entity.offset + entity.length))
  }
  let url: string | undefined
  for (const candidate of candidates) {
    const link = safeLink(candidate)
    if (link?.kind === "web") {
      url = link.href
      break
    }
  }
  const host = url ? new URL(url).host : undefined
  const text = row.text.trim()
  const title =
    (preview?.kind === "urlPreview" ? preview.title?.trim() : undefined) || host || (text !== "" ? text : "Link")
  const subtitle = url ?? (text !== "" && text !== title ? text : undefined)
  return { url, title, subtitle }
}

export const createChatMediaModel = (options: ChatMediaModelOptions): ChatMediaModel => {
  const { client, chatId, tab } = options
  const store = client.store
  const filter = CHAT_MEDIA_FILTERS[tab]
  const formatDate = options.formatDate ?? defaultDate

  const handle = signal<SubscriptionHandle>(client.subscribe({ kind: "chatMedia", chatId, filter }))
  /** The subscription a retry replaced: its list stays on screen until the new one answers. */
  const held = signal<SubscriptionHandle | undefined>(undefined)
  let disposed = false

  const shown = computed(() => {
    const current = handle.get()
    const previous = held.get()
    return previous && current.resource.get() === undefined ? previous : current
  })
  const stopHeld = effect(() => {
    const previous = held.get()
    if (!previous || handle.get().resource.get() === undefined) return
    untracked(() => {
      previous.unsubscribe()
      held.set(undefined)
    })
  })

  const resource = computed<ChatMediaResource | undefined>(() => {
    const value = shown.get().resource.get()
    return value?.kind === "chatMedia" ? value : undefined
  }, { equals: plainEqual })

  const ids = computed<readonly RowKey[]>(() => shown.get().list.get(), { equals: plainEqual })

  const footer = computed<ChatMediaFooter>(
    () => {
      const value = resource.get()
      const empty = ids.get().length === 0
      if (!value) return empty ? { kind: "pending" } : { kind: "loading", empty }
      if (value.failed && !value.loading) return empty && value.fetched ? { kind: "empty", text: CHAT_MEDIA_EMPTY[tab] } : { kind: "failed" }
      if (value.loading) return { kind: "loading", empty }
      if (value.hasMore) return empty && !value.fetched ? { kind: "loading", empty } : { kind: "more" }
      return empty ? { kind: "empty", text: CHAT_MEDIA_EMPTY[tab] } : { kind: "end" }
    },
    { equals: plainEqual },
  )

  const owners = new Map<RowKey, MediaOwner>()
  const ownerOf = (key: RowKey, row: MessageRow): MediaOwner => {
    const previous = owners.get(key)
    const attachmentId = row.upload?.attachmentId
    if (
      previous &&
      previous.messageId === row.messageId &&
      previous.attachmentId === attachmentId &&
      previous.clientKey === row.clientKey &&
      previous.state === row.state
    ) {
      return previous
    }
    const owner: MediaOwner = { chatId: row.chatId, messageId: row.messageId, attachmentId, clientKey: row.clientKey, state: row.state }
    owners.set(key, owner)
    return owner
  }

  const items = new Map<RowKey, ReadSignal<ChatMediaItem | undefined>>()
  const item = (key: RowKey): ReadSignal<ChatMediaItem | undefined> => {
    let cached = items.get(key)
    if (cached) return cached
    cached = computed<ChatMediaItem | undefined>(
      () => {
        const row = store.rowByKey(key).get()
        if (!row || row.kind !== "message") return undefined
        const sender = store.row("user", row.fromId).get()
        const base: Base = {
          key,
          rowId: row.id,
          messageId: row.messageId,
          owner: ownerOf(key, row),
          dateText: formatDate(row.date),
          senderName: row.out ? "You" : userDisplayName(sender),
        }
        const media = row.media
        switch (tab) {
          case "media": {
            if (media?.kind === "photo") return { ...base, kind: "media", media, photo: media.photo, video: undefined, label: `Photo, ${base.dateText}` }
            if (media?.kind === "video") {
              const durationText = media.video.duration > 0 ? formatDuration(media.video.duration) : undefined
              return {
                ...base,
                kind: "media",
                media,
                photo: media.video.thumbnail,
                video: media.video,
                ...(durationText ? { durationText } : {}),
                label: durationText ? `Video, ${durationText}, ${base.dateText}` : `Video, ${base.dateText}`,
              }
            }
            return undefined
          }
          case "files": {
            if (media?.kind !== "document") return undefined
            const fileName = displayFileName(media.document.fileName)
            return {
              ...base,
              kind: "file",
              media,
              fileName,
              sizeText: formatFileSize(media.document.size, options.locale),
              typeText: extension(fileName, media.document.mimeType),
            }
          }
          case "voice":
            if (media?.kind !== "voice") return undefined
            return { ...base, kind: "voice", voice: media.voice, durationText: formatDuration(media.voice.duration) }
          case "links":
            return { ...base, kind: "link", ...linkOf(row) }
        }
      },
      { equals: plainEqual },
    )
    items.set(key, cached)
    return cached
  }

  const loadMore = (): boolean => {
    if (disposed) return false
    const value = resource.peek()
    if (!value || value.loading || !value.hasMore || value.failed) return false
    handle.peek().ensure("older")
    return true
  }

  const retry = () => {
    if (disposed) return
    const previous = handle.peek()
    batch(() => {
      held.peek()?.unsubscribe()
      held.set(previous)
      handle.set(client.subscribe({ kind: "chatMedia", chatId, filter }))
    })
  }

  /** The sentinel is within a screen of the viewport. */
  const near = signal(false)
  const stopNear = effect(() => {
    if (!near.get() || footer.get().kind !== "more") return
    untracked(() => loadMore())
  })
  const sentinel: Part = {
    attach: (element) => {
      const Observer = element.ownerDocument.defaultView?.IntersectionObserver
      if (!Observer) return () => {}
      const observer = new Observer(
        (entries) => {
          const entry = entries[entries.length - 1]
          if (entry) near.set(entry.isIntersecting)
        },
        { rootMargin: "100% 0px" },
      )
      observer.observe(element)
      return () => {
        observer.disconnect()
        near.set(false)
      }
    },
  }

  return {
    tab,
    filter,
    ids,
    item,
    footer,
    resource,
    loadMore,
    retry,
    sentinel,
    dispose: () => {
      disposed = true
      stopNear()
      stopHeld()
      held.peek()?.unsubscribe()
      handle.peek().unsubscribe()
      items.clear()
      owners.clear()
    },
  }
}
