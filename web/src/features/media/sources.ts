/**
 * The UI side of media: the content views' `MediaSources` over the core's
 * `media` query. Framework-free; one per signed-in session.
 *
 * - **One entry per asset and variant** (`refs.ts` keys), shared by every
 *   box that shows it: ten rows showing one image hold one subscription and
 *   one object URL.
 * - **Held while a box shows it.** A view hands its media box to the source's
 *   `part` (`useElement`); the entry is held while any box is attached.
 * - **Asked for when visible.** A held box inside a timeline that has a
 *   visibility controller (`createVisibility`) subscribes when it first
 *   becomes visible, then stays subscribed while held; boxes within a
 *   viewport of it go to the core as `mediaHints` (warmed, not shown). A box
 *   outside any such timeline subscribes at once.
 * - **Object URLs.** One per blob, made only when the resource is `ready`
 *   with a `Blob`, never for `absent`, `queued`, `downloading` or `failed`;
 *   replaced when a later resource carries a different blob; revoked when the
 *   entry leaves `ready`, when it is dropped, and on `dispose`.
 * - **Grace period.** After the last box lets go, the entry keeps its
 *   subscription and URL for `MEDIA_GRACE_MS` (10 s), so a row that leaves
 *   the window and comes back (the timeline trims rows far from the
 *   viewport; a chat switched away from and back to) shows its image at once
 *   instead of asking the core again and fading in. At most
 *   `MEDIA_IDLE_LIMIT` released entries wait; beyond that the oldest goes
 *   first. The core keeps the file pinned while the subscription lives, so
 *   the blob stays readable for exactly as long as its URL exists.
 * - **Retry and open** subscribe again with priority `opened` (first in line,
 *   no auto-download limit), keeping what is shown until the new answer.
 */

import type { Box } from "@inline/chat-ui"
import type {
  Intent,
  IntentResult,
  MediaRef,
  MediaResource,
  PhotoInfo,
  QueryDescriptor,
  ResourceValue,
  VideoInfo,
  VoiceInfo,
} from "@inline/core-protocol"
import { batch, type Clock, computed, type Dispose, effect, type ReadSignal, signal, untracked } from "@inline/reactive"
import {
  cdnMediaSources,
  constantSource,
  type ElementPart,
  type MediaOwner,
  type MediaSource,
  type MediaSources,
  type MediaSourceState,
  type UploadSource,
  type UploadSourceState,
} from "../content/sources"
import { type BlobUrlApi, browserBlobUrls, safeBlob } from "./object-urls"
import { attachmentKey, attachmentTarget, fileTarget, type MediaTarget, photoTarget, refId } from "./refs"
import { type CreateObserver, MediaVisibility } from "./visibility"

/** How long a released entry keeps its subscription and URL. See the file comment. */
export const MEDIA_GRACE_MS = 10_000
/** Released entries kept at most; the oldest is dropped first. */
export const MEDIA_IDLE_LIMIT = 256

/** The part of the store client the media layer uses (`StoreClient` fits). */
export type MediaClient = {
  subscribe(query: QueryDescriptor): { readonly resource: ReadSignal<ResourceValue | undefined>; unsubscribe(): void }
  intent(intent: Intent): PromiseLike<IntentResult>
}

/** Where an entry is, in more detail than `MediaSourceState` (labs, diagnostics, a download button). */
export type MediaEntryState = {
  /** `waiting`: held but not asked for yet (off screen), or asked and not answered. */
  readonly phase: "waiting" | MediaResource["state"]
  readonly receivedBytes?: number
  readonly totalBytes?: number
  readonly failure?: string
  readonly opened: boolean
}

export type MediaStats = {
  /** Entries known (held, idle, or created by a render and not yet held). */
  readonly entries: number
  readonly held: number
  readonly subscribed: number
  /** Object URLs alive. */
  readonly urls: number
  /** Released entries in their grace period. */
  readonly idle: number
}

export type CoreMediaSourcesOptions = {
  readonly client: MediaClient
  readonly urls?: BlobUrlApi
  readonly clock?: Pick<Clock, "now" | "setTimeout" | "clearTimeout">
  /** Default `MEDIA_GRACE_MS`. */
  readonly graceMs?: number
  /** Default `MEDIA_IDLE_LIMIT`. */
  readonly idleLimit?: number
  /** Device pixel ratio for choosing a photo size. Default `globalThis.devicePixelRatio` or 1. */
  readonly pixelRatio?: () => number
  /** Media without an owner, or one the core cannot serve (no file ID): default `cdnMediaSources`. */
  readonly fallback?: MediaSources
  /** When to decide about a newly attached box (after the commit that attached it). Default `queueMicrotask`. */
  readonly defer?: (fn: () => void) => void
  /** Coalesces visibility changes into one update per frame. Default `requestAnimationFrame`, else a 16 ms timer. */
  readonly frame?: (fn: () => void) => void
  /** For tests: the observers a visibility controller uses. Default `IntersectionObserver`. */
  readonly createObserver?: CreateObserver
  /** Replace the default "Cancel Upload" (`deleteMessages` by client key), e.g. to route through the chat model. */
  readonly onCancelUpload?: (owner: MediaOwner) => void
  /** Replace the default "Resend" (`retrySend`). */
  readonly onResend?: (owner: MediaOwner) => void
}

export interface CoreMediaSources extends MediaSources {
  upload(owner: MediaOwner): UploadSource | undefined
  /** A source for a reference directly (a media viewer, a lab). Hold it with `hold` or its `part`. */
  source(ref: MediaRef): MediaSource
  /** The entry's detailed state, for a source this layer made. */
  detail(source: MediaSource): ReadSignal<MediaEntryState> | undefined
  /** Hold a source from code (no element). The returned function lets go. */
  hold(source: MediaSource): Dispose
  /** The user opened it: ask again with priority `opened` (no auto-download limit). */
  open(source: MediaSource): void
  /** A visibility controller for one timeline; attach it to the scroll container (`useElement`). */
  createVisibility(): MediaVisibility<object>
  stats(): MediaStats
  /** Drop everything: unsubscribe, revoke every URL. Sign-out and session end. */
  dispose(): void
}

type Subscription = {
  readonly handle: { readonly resource: ReadSignal<ResourceValue | undefined>; unsubscribe(): void }
  readonly stop: Dispose
}

type Entry = {
  readonly key: string
  readonly ref: MediaRef
  holders: number
  /** Boxes attached, with how many times each is attached. */
  readonly elements: Map<Element, number>
  heldOnce: boolean
  active: boolean
  priority: "visible" | "opened"
  current: Subscription | undefined
  /** The subscription a retry or open replaced, kept until the new one answers. */
  previous: Subscription | undefined
  url: string | undefined
  urlBlob: Blob | undefined
  freshUrl: boolean
  idleAt: number | undefined
  readonly state: ReturnType<typeof signal<MediaSourceState>>
  readonly detail: ReturnType<typeof signal<MediaEntryState>>
  readonly upload: ReturnType<typeof signal<UploadSourceState>>
  readonly source: MediaSource
  uploadSource: UploadSource | undefined
  owner: MediaOwner | undefined
}

/**
 * A sent photo's source while its server copy is not ready: the local image
 * (the attachment's URL) until the server's is, so the box never goes back
 * to its placeholder and fades in again when the send completes.
 */
type Handoff = {
  readonly key: string
  readonly rowKey: string
  readonly local: Entry
  readonly server: Entry
  readonly source: MediaSource
  holders: number
}

const PENDING: MediaSourceState = { status: "pending" }
const FAILED: MediaSourceState = { status: "failed" }
const WAITING: MediaEntryState = { phase: "waiting", opened: false }
const UPLOAD_PENDING: UploadSourceState = { phase: "pending", fraction: undefined }
const pendingSource = constantSource(PENDING)

const sameState = (a: MediaSourceState, b: MediaSourceState) =>
  a === b ||
  (a.status === b.status &&
    (a.status !== "ready" || a.url === (b as { url: string }).url) &&
    (a.status !== "pending" || a.progress === (b as { progress?: number }).progress))

const sameDetail = (a: MediaEntryState, b: MediaEntryState) =>
  a.phase === b.phase &&
  a.receivedBytes === b.receivedBytes &&
  a.totalBytes === b.totalBytes &&
  a.failure === b.failure &&
  a.opened === b.opened

const sameUpload = (a: UploadSourceState, b: UploadSourceState) => a.phase === b.phase && a.fraction === b.fraction

const defaultFrame = (fn: () => void) => {
  const raf = (globalThis as { requestAnimationFrame?: (callback: () => void) => unknown }).requestAnimationFrame
  if (typeof raf === "function") raf(fn)
  else setTimeout(fn, 16)
}

const defaultClock: Pick<Clock, "now" | "setTimeout" | "clearTimeout"> = {
  now: () => (typeof performance !== "undefined" ? performance.now() : Date.now()),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
}

const ignore = (result: PromiseLike<unknown>) => {
  void Promise.resolve(result).then(undefined, () => undefined)
}

const uploadStateOf = (resource: MediaResource): UploadSourceState => {
  const upload = resource.upload
  if (!upload) return resource.attachment ? { phase: "staged", fraction: 0 } : UPLOAD_PENDING
  const fraction = upload.totalBytes > 0 ? Math.min(1, upload.sentBytes / upload.totalBytes) : undefined
  return { phase: upload.state, fraction }
}

export const createCoreMediaSources = (options: CoreMediaSourcesOptions): CoreMediaSources => {
  const { client } = options
  const urls = options.urls ?? browserBlobUrls
  const clock = options.clock ?? defaultClock
  const graceMs = options.graceMs ?? MEDIA_GRACE_MS
  const idleLimit = options.idleLimit ?? MEDIA_IDLE_LIMIT
  const pixelRatio = options.pixelRatio ?? (() => globalThis.devicePixelRatio ?? 1)
  const fallback = options.fallback ?? cdnMediaSources({ pixelRatio })
  const defer = options.defer ?? queueMicrotask
  const frame = options.frame ?? defaultFrame

  const entries = new Map<string, Entry>()
  const bySource = new WeakMap<MediaSource, Entry>()
  /** Entries with a live subscription, in the map or not. */
  const subscribed = new Set<Entry>()
  /** Released entries in their grace period, oldest first. Never-held entries are here too, untimed against the limit. */
  const idle = new Set<Entry>()
  /** Boxes attached since the last decision. */
  const arriving = new Map<Element, Set<Entry>>()
  const visibilities = new Set<MediaVisibility<object>>()
  let decideQueued = false
  let frameQueued = false
  let sweepTimer: unknown
  let sweepAt = Infinity
  let lastHints = ""
  let disposed = false
  /** A send's row (`chatId:clientKey`) to the attachment entry it showed while sending. */
  const localOfRow = new Map<string, string>()
  /** Sources that show a send's local image until its server copy is ready, by `localKey>serverKey`. */
  const handoffs = new Map<string, Handoff>()

  // -------------------------------------------------------------------------
  // Entries

  const entryFor = (target: MediaTarget): Entry => {
    const existing = entries.get(target.key)
    if (existing) return existing
    const entry: Entry = {
      key: target.key,
      ref: target.ref,
      holders: 0,
      elements: new Map(),
      heldOnce: false,
      active: false,
      priority: "visible",
      current: undefined,
      previous: undefined,
      url: undefined,
      urlBlob: undefined,
      freshUrl: false,
      idleAt: undefined,
      state: signal<MediaSourceState>(PENDING, { equals: sameState }),
      detail: signal<MediaEntryState>(WAITING, { equals: sameDetail }),
      upload: signal<UploadSourceState>(UPLOAD_PENDING, { equals: sameUpload }),
      source: undefined as unknown as MediaSource,
      uploadSource: undefined,
      owner: undefined,
    }
    const part: ElementPart = { attach: (element) => attach(entry, element) }
    ;(entry as { source: MediaSource }).source = { state: entry.state, retry: () => retry(entry), part }
    bySource.set(entry.source, entry)
    entries.set(entry.key, entry)
    // Created by a render: if no box ever attaches, it goes after the grace period.
    startIdle(entry)
    return entry
  }

  const attach = (entry: Entry, element: Element): (() => void) => {
    if (disposed) return () => {}
    retain(entry)
    entry.elements.set(element, (entry.elements.get(element) ?? 0) + 1)
    let boxes = arriving.get(element)
    if (!boxes) {
      boxes = new Set()
      arriving.set(element, boxes)
    }
    boxes.add(entry)
    if (!decideQueued) {
      decideQueued = true
      defer(decide)
    }
    let attached = true
    return () => {
      if (!attached) return
      attached = false
      const count = (entry.elements.get(element) ?? 1) - 1
      if (count > 0) entry.elements.set(element, count)
      else {
        entry.elements.delete(element)
        arriving.get(element)?.delete(entry)
        for (const visibility of visibilities) visibility.unobserve(element, entry)
      }
      release(entry)
    }
  }

  const retain = (entry: Entry) => {
    // A source a view kept after its entry was dropped: bring the entry back.
    if (!entries.has(entry.key) && !disposed) entries.set(entry.key, entry)
    entry.holders += 1
    entry.heldOnce = true
    stopIdle(entry)
  }

  const release = (entry: Entry) => {
    if (entry.holders === 0) return
    entry.holders -= 1
    if (entry.holders === 0 && !disposed) startIdle(entry)
  }

  /** Boxes attached in the last task: inside a timeline, watch them; elsewhere, ask now. */
  const decide = () => {
    decideQueued = false
    if (disposed) return
    const boxes = [...arriving]
    arriving.clear()
    for (const [element, attachedEntries] of boxes) {
      const visibility = [...visibilities].find((candidate) => candidate.covers(element))
      for (const entry of attachedEntries) {
        if (!entry.elements.has(element)) continue
        if (visibility) visibility.observe(element, entry)
        else activate(entry)
      }
    }
  }

  // -------------------------------------------------------------------------
  // Grace period

  const startIdle = (entry: Entry) => {
    entry.idleAt = clock.now()
    idle.delete(entry)
    idle.add(entry)
    if (entry.heldOnce) {
      let waiting = 0
      for (const candidate of idle) if (candidate.heldOnce) waiting += 1
      if (waiting > idleLimit) {
        for (const candidate of idle) {
          if (!candidate.heldOnce || candidate === entry) continue
          drop(candidate)
          break
        }
      }
    }
    scheduleSweep(entry.idleAt + graceMs)
  }

  const stopIdle = (entry: Entry) => {
    entry.idleAt = undefined
    idle.delete(entry)
  }

  const scheduleSweep = (at: number) => {
    if (at >= sweepAt) return
    if (sweepTimer !== undefined) clock.clearTimeout(sweepTimer)
    sweepAt = at
    sweepTimer = clock.setTimeout(sweep, Math.max(0, at - clock.now()))
  }

  const sweep = () => {
    sweepTimer = undefined
    sweepAt = Infinity
    if (disposed) return
    const now = clock.now()
    let next = Infinity
    for (const entry of idle) {
      const at = (entry.idleAt ?? now) + graceMs
      if (at <= now) drop(entry)
      else next = Math.min(next, at)
    }
    if (next < Infinity) scheduleSweep(next)
  }

  const drop = (entry: Entry) => {
    for (const handoff of handoffs.values()) {
      if (handoff.local === entry || handoff.server === entry) forgetHandoff(handoff)
    }
    for (const [row, key] of localOfRow) if (key === entry.key) localOfRow.delete(row)
    stopIdle(entry)
    unsubscribe(entry)
    if (entries.get(entry.key) === entry) entries.delete(entry.key)
    entry.active = false
    entry.priority = "visible"
    batch(() => {
      entry.state.set(PENDING)
      entry.detail.set(WAITING)
      entry.upload.set(UPLOAD_PENDING)
    })
  }

  // -------------------------------------------------------------------------
  // Subscriptions

  const activate = (entry: Entry, priority: "visible" | "opened" = "visible") => {
    if (disposed) return
    if (entry.active && (entry.priority === "opened" || priority === "visible")) return
    if (priority === "opened") entry.priority = "opened"
    entry.active = true
    subscribe(entry)
  }

  const subscribe = (entry: Entry) => {
    const handle = client.subscribe({
      kind: "media",
      media: entry.ref,
      ...(entry.priority === "opened" ? { priority: "opened" as const } : {}),
    })
    if (entry.current) {
      endSubscription(entry.previous)
      entry.previous = entry.current
    }
    let current: Subscription | undefined
    const stop = untracked(() =>
      effect(() => {
        const value = handle.resource.get()
        untracked(() => {
          if (current && entry.current === current) onResource(entry, value)
        })
      }),
    )
    current = { handle, stop }
    entry.current = current
    subscribed.add(entry)
    // The store may already hold an answer (another context's, a restored snapshot).
    onResource(entry, handle.resource.peek())
    if (entry.detail.peek().phase === "waiting") entry.detail.set({ ...WAITING, opened: entry.priority === "opened" })
  }

  const endSubscription = (subscription: Subscription | undefined) => {
    if (!subscription) return
    subscription.stop()
    subscription.handle.unsubscribe()
  }

  const unsubscribe = (entry: Entry) => {
    endSubscription(entry.current)
    endSubscription(entry.previous)
    entry.current = undefined
    entry.previous = undefined
    subscribed.delete(entry)
    revokeUrl(entry)
  }

  const onResource = (entry: Entry, value: ResourceValue | undefined) => {
    if (!value || value.kind !== "media") return
    if (entry.previous) {
      // A retry or an upgrade: keep showing the old answer until the new one says something.
      if (value.state === "absent") return
      endSubscription(entry.previous)
      entry.previous = undefined
    }
    apply(entry, value)
  }

  const apply = (entry: Entry, resource: MediaResource) => {
    batch(() => {
      entry.upload.set(uploadStateOf(resource))
      entry.detail.set({
        phase: resource.state,
        ...(resource.receivedBytes !== undefined ? { receivedBytes: resource.receivedBytes } : {}),
        ...(resource.totalBytes !== undefined ? { totalBytes: resource.totalBytes } : {}),
        ...(resource.failure !== undefined ? { failure: resource.failure } : {}),
        opened: entry.priority === "opened",
      })
      if (resource.state === "ready" && resource.blob) {
        if (entry.url === undefined || entry.urlBlob !== resource.blob || entry.freshUrl) {
          const old = entry.url
          entry.url = urls.create(safeBlob(resource.blob))
          entry.urlBlob = resource.blob
          entry.freshUrl = false
          if (old !== undefined) urls.revoke(old)
        }
        entry.state.set({ status: "ready", url: entry.url })
        return
      }
      revokeUrl(entry)
      if (resource.state === "failed") entry.state.set(FAILED)
      else if (resource.state === "downloading" && resource.totalBytes && resource.receivedBytes !== undefined) {
        entry.state.set({ status: "pending", progress: Math.min(1, resource.receivedBytes / resource.totalBytes) })
      } else entry.state.set(PENDING)
    })
  }

  const revokeUrl = (entry: Entry) => {
    const url = entry.url
    entry.url = undefined
    entry.urlBlob = undefined
    if (url !== undefined) urls.revoke(url)
  }

  const retry = (entry: Entry) => {
    if (disposed) return
    // The element could not decode the bytes: the next answer gets a new URL even for the same blob.
    if (entry.url !== undefined) entry.freshUrl = true
    entry.priority = "opened"
    if (entry.active) subscribe(entry)
    else activate(entry, "opened")
  }

  // -------------------------------------------------------------------------
  // Visibility and hints

  const visibilityChanged = () => {
    if (frameQueued || disposed) return
    frameQueued = true
    frame(flushVisibility)
  }

  const flushVisibility = () => {
    frameQueued = false
    if (disposed) return
    const visible = new Set<Entry>()
    const near = new Set<Entry>()
    for (const visibility of visibilities) {
      for (const target of visibility.visible()) visible.add(target as Entry)
      for (const target of visibility.nearby()) near.add(target as Entry)
    }
    for (const entry of visible) if (entry.holders > 0) activate(entry)
    const refs: MediaRef[] = []
    const ids: string[] = []
    for (const entry of near) {
      if (entry.active || visible.has(entry) || entry.ref.kind !== "message") continue
      const id = refId(entry.ref)
      if (ids.includes(id)) continue
      ids.push(id)
      refs.push(entry.ref)
    }
    const order = ids.map((id, index) => [id, index] as const).sort((a, b) => (a[0] < b[0] ? -1 : 1))
    const signature = order.map(([id]) => id).join("|")
    if (signature === lastHints) return
    lastHints = signature
    ignore(client.intent({ kind: "mediaHints", nearby: order.map(([, index]) => refs[index]!) }))
  }

  // -------------------------------------------------------------------------
  // The interface

  const ownedPhoto = (photo: PhotoInfo, box: Box, owner: MediaOwner, thumbnail: boolean): MediaSource | undefined => {
    const local = attachmentTarget(owner)
    const row = !thumbnail && owner.clientKey !== undefined ? `${owner.chatId}:${owner.clientKey}` : undefined
    // A local video's or document's thumbnail is not the attachment's bytes (those are the file).
    if (local) {
      if (thumbnail) return pendingSource
      if (row !== undefined) localOfRow.set(row, local.key)
      return entryFor(local).source
    }
    const target = photoTarget(photo, box, pixelRatio(), owner, thumbnail)
    if (!target) return undefined
    const server = entryFor(target)
    if (row === undefined) return server.source
    const localKey = localOfRow.get(row)
    const localEntry = localKey !== undefined ? entries.get(localKey) : undefined
    if (!localEntry) {
      localOfRow.delete(row)
      return server.source
    }
    const existing = handoffs.get(`${localEntry.key}>${server.key}`)
    // Mounted: the same source on every render until it lets go.
    if (existing && existing.holders > 0) return existing.source
    if (server.state.peek().status === "ready") {
      if (existing) forgetHandoff(existing)
      localOfRow.delete(row)
      return server.source
    }
    return (existing ?? handoffFor(localEntry, server, row)).source
  }

  const handoffFor = (local: Entry, server: Entry, rowKey: string): Handoff => {
    const key = `${local.key}>${server.key}`
    const held = signal(false)
    /** The local image last shown while mounted: its pixels stay on screen even after its URL went. */
    let lastLocal: MediaSourceState | undefined
    const state = computed<MediaSourceState>(
      () => {
        const fromServer = server.state.get()
        if (fromServer.status === "ready") return fromServer
        const fromLocal = local.state.get()
        if (fromLocal.status === "ready") {
          lastLocal = fromLocal
          return fromLocal
        }
        return held.get() && lastLocal ? lastLocal : fromServer
      },
      { equals: sameState },
    )
    const handoff: Handoff = {
      key,
      rowKey,
      local,
      server,
      holders: 0,
      source: {
        state,
        retry: () => retry(server),
        part: {
          attach: (element) => {
            if (disposed) return () => {}
            const releaseLocal = attach(local, element)
            const releaseServer = attach(server, element)
            // A remount after a detach in the same task: known again.
            if (!handoffs.has(key) && server.state.peek().status !== "ready") {
              handoffs.set(key, handoff)
              localOfRow.set(rowKey, local.key)
            }
            handoff.holders += 1
            held.set(true)
            let attached = true
            return () => {
              if (!attached) return
              attached = false
              releaseServer()
              releaseLocal()
              handoff.holders -= 1
              if (handoff.holders === 0) {
                held.set(false)
                lastLocal = undefined
                // From now on the row asks for the server copy alone.
                forgetHandoff(handoff)
              }
            }
          },
        },
      },
    }
    bySource.set(handoff.source, server)
    handoffs.set(key, handoff)
    return handoff
  }

  const forgetHandoff = (handoff: Handoff) => {
    if (handoffs.get(handoff.key) === handoff) handoffs.delete(handoff.key)
    if (handoff.holders === 0 && localOfRow.get(handoff.rowKey) === handoff.local.key) localOfRow.delete(handoff.rowKey)
  }

  const ownedFile = (file: VideoInfo | VoiceInfo, owner: MediaOwner): MediaSource | undefined => {
    const target = attachmentTarget(owner) ?? fileTarget(file, owner)
    return target ? entryFor(target).source : undefined
  }

  const cancelUpload = (entry: Entry) => {
    const owner = entry.owner
    if (!owner?.clientKey) return
    if (options.onCancelUpload) options.onCancelUpload(owner)
    else ignore(client.intent({ kind: "deleteMessages", chatId: owner.chatId, messageIds: [], clientKeys: [owner.clientKey] }))
  }

  const resend = (entry: Entry) => {
    const owner = entry.owner
    if (!owner?.clientKey) return
    if (options.onResend) options.onResend(owner)
    else ignore(client.intent({ kind: "retrySend", chatId: owner.chatId, clientKey: owner.clientKey }))
  }

  return {
    photo: (photo, box, owner, thumbnail) =>
      (owner && !disposed ? ownedPhoto(photo, box, owner, thumbnail ?? false) : undefined) ?? fallback.photo(photo, box),
    video: (video, owner) => (owner && !disposed ? ownedFile(video, owner) : undefined) ?? fallback.video(video),
    voice: (voice, owner) => (owner && !disposed ? ownedFile(voice, owner) : undefined) ?? fallback.voice(voice),
    upload: (owner) => {
      if (owner.attachmentId === undefined || disposed) return undefined
      const entry = entryFor({ key: attachmentKey(owner.attachmentId), ref: { kind: "attachment", attachmentId: owner.attachmentId } })
      entry.owner = owner
      entry.uploadSource ??= {
        state: entry.upload,
        ...(entry.source.part ? { part: entry.source.part } : {}),
        cancel: () => cancelUpload(entry),
        resend: () => resend(entry),
      }
      return entry.uploadSource
    },
    source: (ref) => {
      const key = ref.kind === "attachment" ? attachmentKey(ref.attachmentId) : `ref:${refId(ref)}`
      return entryFor({ key, ref }).source
    },
    detail: (source) => bySource.get(source)?.detail,
    hold: (source) => {
      const entry = bySource.get(source)
      if (!entry || disposed) return () => {}
      retain(entry)
      activate(entry)
      let held = true
      return () => {
        if (!held) return
        held = false
        release(entry)
      }
    },
    open: (source) => {
      const entry = bySource.get(source)
      if (entry && !(entry.active && entry.priority === "opened")) {
        if (entry.active) {
          entry.priority = "opened"
          subscribe(entry)
        } else activate(entry, "opened")
      }
    },
    createVisibility: () => {
      const visibility = new MediaVisibility<object>({
        onChange: visibilityChanged,
        ...(options.createObserver ? { createObserver: options.createObserver } : {}),
      })
      visibilities.add(visibility)
      const dispose = visibility.dispose.bind(visibility)
      visibility.dispose = () => {
        visibilities.delete(visibility)
        dispose()
        visibilityChanged()
      }
      return visibility
    },
    stats: () => {
      let held = 0
      let withUrl = 0
      for (const entry of subscribed) if (entry.url !== undefined) withUrl += 1
      for (const entry of entries.values()) if (entry.holders > 0) held += 1
      return { entries: entries.size, held, subscribed: subscribed.size, urls: withUrl, idle: idle.size }
    },
    dispose: () => {
      if (disposed) return
      disposed = true
      if (sweepTimer !== undefined) clock.clearTimeout(sweepTimer)
      sweepTimer = undefined
      for (const entry of subscribed) unsubscribe(entry)
      for (const entry of entries.values()) drop(entry)
      entries.clear()
      handoffs.clear()
      localOfRow.clear()
      idle.clear()
      arriving.clear()
      for (const visibility of visibilities) visibility.dispose()
      visibilities.clear()
    },
  }
}
