/**
 * Attachments in the composer: files pasted, dropped or picked, shown in a
 * strip above the editor until they are sent. Framework-free.
 *
 * - **Durable at once.** Each file is handed to the core with `attachFile`
 *   the moment it is added: the core stages its bytes and starts the upload,
 *   so nothing waits for Send and nothing lives only in memory
 *   (timeline-and-composer.md, "Durability"). Removing one posts
 *   `discardAttachment`.
 * - **Progress** comes from the attachment's own `media` subscription
 *   (`{ kind: "attachment" }`): its info, then its upload.
 * - **Send** posts one `sendMedia` per attachment, the Mac way
 *   (`GlassComposeAppKit.send`, `mediaSendIntents`): the text, entities and
 *   reply go on the first; each with its optimistic row
 *   (`optimisticMediaRow`), so the rows have their final size at once. The
 *   composer clears only after the core accepted the first (which carries
 *   the text); attachments the core refused stay in the strip.
 * - **Limits.** The server takes at most 500 MB a file (`MAX_FILE_SIZE`; the
 *   Mac's `MediaUploadLimits` for video and documents; photos are compressed
 *   by the core before the 40 MB photo limit applies). Empty files are
 *   refused. The Mac has no count limit; the web caps the strip at 20 files,
 *   so one drop of a folder's worth does not start hundreds of uploads.
 * - **Thumbnails** of raster images are object URLs of the file itself,
 *   revoked when the attachment leaves the strip or the model is disposed.
 *   Never for SVG or other types (`isPreviewableImage`).
 */

import { formatFileSize } from "@inline/chat-ui"
import type { SendOutcome, SendRequest } from "@inline/composer"
import {
  ATTACHMENT_PREVIEW_MAX_BYTES,
  type AttachmentId,
  type AttachmentInfo,
  type Entity,
  type Intent,
  type IntentResult,
  mediaSendIntents,
  type MessageRow,
  newAttachmentId,
  newClientKey,
  optimisticMediaRow,
  type QueryDescriptor,
  type ResourceValue,
  type TxId,
} from "@inline/core-protocol"
import type { ChatID, UserID } from "@inline/ids"
import {
  batch,
  type Clock,
  computed,
  type Dispose,
  effect,
  type OptimisticRow,
  type ReadSignal,
  signal,
  untracked,
} from "@inline/reactive"
import { type BlobUrlApi, browserBlobUrls, isPreviewableImage } from "../media/object-urls"
import {
  ATTACHMENT_PROBE_TIMEOUT_MS,
  type AttachmentProbe,
  type AttachmentProber,
  browserAttachmentProber,
  type ProbeKind,
  sendsAsFile,
  serialProber,
} from "./attachment-probe"
import type { ComposerModelOptions } from "./model"
import { attachmentStripChunk } from "./strip-chunk"
import { sendErrorText } from "./text"

/** The server's per-file limit (`server/src/config.ts` `MAX_FILE_SIZE`; Mac `MediaUploadLimits` for video and documents). */
export const MAX_ATTACHMENT_BYTES = 500_000_000
/** Web only: files the strip holds at once. */
export const MAX_ATTACHMENTS = 20
/** How long Send waits for the core to describe an attachment it staged. */
export const ATTACHMENT_INFO_TIMEOUT_MS = 15_000

export type AttachmentLimits = { readonly maxBytes: number; readonly maxCount: number }

export type AttachmentStatus =
  /** Handed to the core; its bytes are being staged (photos are measured and compressed first). */
  | { readonly phase: "staging" }
  | { readonly phase: "uploading"; readonly fraction: number }
  | { readonly phase: "uploaded" }
  | { readonly phase: "failed"; readonly message: string }

export type PendingAttachment = {
  readonly id: AttachmentId
  readonly fileName: string
  readonly mimeType: string
  readonly size: number
  /** "2.4 MB" (`chat-ui` `formatFileSize`). */
  readonly sizeText: string
  /** How the strip draws it: a picture, a video, or a file row. */
  readonly kind: "image" | "video" | "file"
  /** A raster image's own bytes as an object URL; undefined for everything else. */
  readonly thumbnailUrl: string | undefined
  readonly status: ReadSignal<AttachmentStatus>
}

/** The part of the store client attachments use (`StoreClient` fits). */
export type AttachmentsClient = {
  subscribe(query: QueryDescriptor): { readonly resource: ReadSignal<ResourceValue | undefined>; unsubscribe(): void }
  /** The store client's `intent`: its handle carries the transaction ID (`tx`) the optimistic row is stamped with. */
  intent(intent: Intent, optimistic?: readonly OptimisticRow[]): PromiseLike<IntentResult> & { readonly tx: TxId }
  /** The optimistic rows go in right after the intent, under its `tx`, as `ChatModel.send` installs a text row. */
  readonly store: { addOverlay(tx: TxId, rows: readonly OptimisticRow[]): void }
}

export type ComposerAttachmentsOptions = {
  readonly client: AttachmentsClient
  readonly chatId: ChatID
  /** The viewer: the optimistic rows' sender. */
  readonly userId: UserID
  readonly urls?: BlobUrlApi
  /** `now()` in milliseconds (message dates), and the timer for the info wait. */
  readonly clock?: Pick<Clock, "now" | "setTimeout" | "clearTimeout">
  readonly limits?: Partial<AttachmentLimits>
  readonly newAttachmentId?: () => AttachmentId
  readonly newClientKey?: () => string
  /**
   * Where the optimistic rows go: name the chat window so each row appears at
   * its end (`appendTo`), as the chat model does for text. Default: the rows
   * alone (the core's patch places them a frame later).
   */
  readonly placeRows?: (row: MessageRow) => OptimisticRow
  readonly infoTimeoutMs?: number
  readonly locale?: string
  /**
   * Measures photos and videos and makes their tiny preview before
   * `attachFile` (`attachment-probe.ts`). Default: the browser's, one file at
   * a time for the session (`createAttachmentDrafts` shares one). `false`:
   * hand files over at once with no hints.
   */
  readonly prober?: AttachmentProber | false
  /** How long `attachFile` waits for a probe. Default `ATTACHMENT_PROBE_TIMEOUT_MS`. */
  readonly probeTimeoutMs?: number
  /** Loads the strip's view on the first file. Default `attachmentStripChunk.load` (in a page); `false` in tests. */
  readonly loadView?: (() => void) | false
}

/** What the chat pane reports while sent attachments upload (`createComposeReporter().beginActivity`). */
export type UploadActivity = "uploadingPhoto" | "uploadingVideo" | "uploadingDocument"

export type ComposerAttachments = {
  readonly chatId: ChatID
  /** In the order added. */
  readonly items: ReadSignal<readonly PendingAttachment[]>
  readonly hasAttachments: ReadSignal<boolean>
  /** Why something was refused or not sent, in words; null when there is nothing to say. */
  readonly notice: ReadSignal<string | null>
  /**
   * The strongest upload of a sent attachment still running (video, then
   * photo, then file), or null: what "Mo is sending a photo" says to the
   * others. Attachments only sitting in the strip are not reported. Optional
   * so other implementations (the chat feature's lazy one) can forward it.
   */
  readonly activity?: ReadSignal<UploadActivity | null>
  /** Files pasted, dropped or picked. Refused ones are named in `notice`. */
  add(files: readonly Blob[]): void
  /** The strip's remove control: forget it here and in the core. */
  remove(id: AttachmentId): void
  /** A failed attachment: hand its file to the core again. */
  retry(id: AttachmentId): void
  dismissNotice(): void
  /** Send the attachments with the composer's text as the caption of the first. */
  send(request: SendRequest): Promise<SendOutcome>
  /** The composer's `send`: attachments go through `send`, anything else (text, edits) to `textSend`. */
  wrapSend(textSend: (request: SendRequest) => Promise<SendOutcome> | SendOutcome): (request: SendRequest) => Promise<SendOutcome>
  /** Release what the strip holds here (URLs, subscriptions). The core keeps the attachments. */
  dispose(): void
  /** Discard every attachment in the core too (the user cleared the composer, or left the chat for good). */
  discardAll(): void
}

/** Words for the reasons `send` rejects with that the composer's own `sendErrorText` does not know. */
export const attachmentSendErrorText = (reason: string): string | null => {
  switch (reason) {
    case "attachmentFailed":
      return "An attachment couldn’t be added. Remove it or try again; your message is still here."
    case "attachmentNotReady":
      return "An attachment isn’t ready yet. Try again in a moment; your message is still here."
    default:
      return null
  }
}

const fileNameOf = (file: Blob): string => {
  const name = (file as { name?: unknown }).name
  return typeof name === "string" && name.trim() !== "" ? name : "file"
}

const kindOf = (mimeType: string): PendingAttachment["kind"] =>
  isPreviewableImage(mimeType) ? "image" : mimeType.startsWith("video/") ? "video" : "file"

const quoted = (name: string) => `“${name}”`

const megabytes = (bytes: number) => `${Math.floor(bytes / 1_000_000)} MB`

const attachRejectionText = (reason: string | undefined): string => {
  switch (reason) {
    case "storageFull":
      return "Not enough storage on this device to attach this file."
    case "invalid":
    case "unsupported":
      return "This file can’t be attached."
    case "notSignedIn":
      return "Sign in again to attach files."
    default:
      return "Couldn’t attach this file. Try again."
  }
}

type Item = {
  readonly view: PendingAttachment
  readonly file: Blob
  readonly status: ReturnType<typeof signal<AttachmentStatus>>
  readonly info: ReturnType<typeof signal<AttachmentInfo | undefined>>
  /** The `attachFile` result: staged, refused, or still open. */
  attach: "pending" | "staged" | "failed"
  attachMessage: string | undefined
  attached: Promise<void>
  handle: { unsubscribe(): void } | undefined
  stop: Dispose | undefined
  clientKey: string | undefined
  released: boolean
  /** `attachFile` was posted (a probe may hold it back a moment). */
  posted: boolean
  /** Sent, its upload still running: it reports activity until the upload ends. */
  sending: boolean
  thumbnailRevoked: boolean
}

const sameStatus = (a: AttachmentStatus, b: AttachmentStatus) =>
  a.phase === b.phase &&
  (a.phase !== "uploading" || a.fraction === (b as { fraction: number }).fraction) &&
  (a.phase !== "failed" || a.message === (b as { message: string }).message)

const activityRank: Record<UploadActivity, number> = { uploadingVideo: 3, uploadingPhoto: 2, uploadingDocument: 1 }

/** The `attachFile` fields a probe gives: size, length, preview, and the Mac's photo-or-file rule. */
export const attachHints = (
  hints: AttachmentProbe | undefined,
  kind: ProbeKind | undefined,
): { as?: "document"; width?: number; height?: number; duration?: number; preview?: Uint8Array } => {
  if (!hints || !kind) return {}
  const sized = hints.width !== undefined && hints.height !== undefined && hints.width > 0 && hints.height > 0
  if (kind === "image" && sized && sendsAsFile(hints.width!, hints.height!)) return { as: "document" }
  return {
    ...(sized ? { width: hints.width!, height: hints.height! } : {}),
    ...(kind === "video" && hints.duration !== undefined ? { duration: hints.duration } : {}),
    ...(hints.preview && hints.preview.byteLength <= ATTACHMENT_PREVIEW_MAX_BYTES ? { preview: hints.preview } : {}),
  }
}

let sharedProber: AttachmentProber | undefined
/** The page's one browser prober: one decode at a time across every chat. */
const sharedBrowserProber = (): AttachmentProber => (sharedProber ??= serialProber(browserAttachmentProber))

/**
 * Report `activity` through the chat's compose reporter (`features/typing`
 * `createComposeReporter`): begins on a change to a kind, ends when it
 * clears. Returns the dispose (which ends a running activity).
 *
 *     const stop = followUploadActivity(attachments.activity, reporter)
 */
export const followUploadActivity = (
  activity: ReadSignal<UploadActivity | null>,
  reporter: { beginActivity(kind: UploadActivity): () => void },
): Dispose => {
  let end: (() => void) | undefined
  let current: UploadActivity | null = null
  const stop = effect(() => {
    const next = activity.get()
    untracked(() => {
      if (next === current) return
      end?.()
      end = undefined
      current = next
      if (next) end = reporter.beginActivity(next)
    })
  })
  return () => {
    stop()
    end?.()
    end = undefined
    current = null
  }
}

const accepted = (result: IntentResult | undefined) => result?.status === "accepted" || result?.status === "confirmed"

export const createComposerAttachments = (options: ComposerAttachmentsOptions): ComposerAttachments => {
  const { client, chatId } = options
  const urls = options.urls ?? browserBlobUrls
  const clock = options.clock ?? {
    now: () => Date.now(),
    setTimeout: (fn: () => void, ms: number) => setTimeout(fn, ms),
    clearTimeout: (handle: unknown) => clearTimeout(handle as ReturnType<typeof setTimeout>),
  }
  const limits: AttachmentLimits = {
    maxBytes: options.limits?.maxBytes ?? MAX_ATTACHMENT_BYTES,
    maxCount: options.limits?.maxCount ?? MAX_ATTACHMENTS,
  }
  const makeId = options.newAttachmentId ?? newAttachmentId
  const makeClientKey = options.newClientKey ?? (() => newClientKey())
  const placeRows = options.placeRows ?? ((row: MessageRow) => ({ row }))
  const infoTimeoutMs = options.infoTimeoutMs ?? ATTACHMENT_INFO_TIMEOUT_MS
  const prober = options.prober === undefined ? sharedBrowserProber() : options.prober
  const probeTimeoutMs = options.probeTimeoutMs ?? ATTACHMENT_PROBE_TIMEOUT_MS
  const loadView =
    options.loadView === undefined
      ? typeof document === "undefined"
        ? undefined
        : () => void attachmentStripChunk.load()
      : options.loadView || undefined

  const items = signal<readonly Item[]>([])
  /** Sent attachments whose upload is still running (activity only). */
  const uploading = signal<readonly Item[]>([])
  const views = computed<readonly PendingAttachment[]>(() => items.get().map((item) => item.view))
  const hasAttachments = computed(() => items.get().length > 0)
  const notice = signal<string | null>(null)
  let disposed = false

  // -------------------------------------------------------------------------
  // One attachment

  const updateStatus = (item: Item, resource: ResourceValue | undefined) => {
    if (item.released) return
    const media = resource?.kind === "media" ? resource : undefined
    batch(() => {
      if (media?.attachment) item.info.set(media.attachment)
      if (item.attach === "failed") {
        item.status.set({ phase: "failed", message: item.attachMessage ?? attachRejectionText(undefined) })
        return
      }
      const upload = media?.upload
      if (upload?.state === "failed" || upload?.state === "canceled") {
        item.status.set({ phase: "failed", message: "Couldn’t upload. Try again." })
      } else if (upload?.state === "complete" || upload?.state === "processing") {
        item.status.set({ phase: "uploaded" })
      } else if (upload && upload.totalBytes > 0) {
        item.status.set({ phase: "uploading", fraction: Math.min(1, upload.sentBytes / upload.totalBytes) })
      } else {
        item.status.set({ phase: "staging" })
      }
    })
    if (item.sending) {
      const phase = item.status.peek().phase
      if (phase === "uploaded" || phase === "failed") finishSending(item)
    }
  }

  const finishSending = (item: Item) => {
    if (!item.sending) return
    item.sending = false
    uploading.set(uploading.peek().filter((candidate) => candidate !== item))
    release(item, false)
  }

  /** Measure and preview a photo or video, bounded; `{}` when it cannot. */
  const probe = (file: Blob, kind: ProbeKind): Promise<AttachmentProbe> => {
    if (!prober) return Promise.resolve({})
    return new Promise<AttachmentProbe>((resolve) => {
      let settled = false
      const done = (value: AttachmentProbe) => {
        if (settled) return
        settled = true
        clock.clearTimeout(timer)
        resolve(value)
      }
      const timer = clock.setTimeout(() => done({}), probeTimeoutMs)
      // A task later: the strip shows the attachment before any decoding starts.
      clock.setTimeout(() => {
        if (settled) return
        prober(file, kind).then(done, () => done({}))
      }, 0)
    })
  }

  const start = (file: Blob, id: AttachmentId): Item => {
    const fileName = fileNameOf(file)
    const mimeType = file.type || "application/octet-stream"
    const kind = kindOf(mimeType)
    const status = signal<AttachmentStatus>({ phase: "staging" }, { equals: sameStatus })
    const view: PendingAttachment = {
      id,
      fileName,
      mimeType,
      size: file.size,
      sizeText: formatFileSize(file.size, options.locale),
      kind,
      thumbnailUrl: kind === "image" ? urls.create(file) : undefined,
      status,
    }
    const item: Item = {
      view,
      file,
      status,
      info: signal<AttachmentInfo | undefined>(undefined),
      attach: "pending",
      attachMessage: undefined,
      attached: Promise.resolve(),
      handle: undefined,
      stop: undefined,
      clientKey: undefined,
      released: false,
      posted: false,
      sending: false,
      thumbnailRevoked: false,
    }
    const handle = client.subscribe({ kind: "media", media: { kind: "attachment", attachmentId: id } })
    item.handle = handle
    item.stop = untracked(() =>
      effect(() => {
        const value = handle.resource.get()
        untracked(() => updateStatus(item, value))
      }),
    )
    const probeKind: ProbeKind | undefined =
      kind === "image" ? "image" : kind === "video" ? "video" : undefined
    const post = (hints: AttachmentProbe | undefined) => {
      if (item.released) return Promise.resolve(undefined)
      item.posted = true
      return Promise.resolve(client.intent({ kind: "attachFile", attachmentId: id, file, fileName, mimeType, ...attachHints(hints, probeKind) }))
    }
    // Documents go at once; photos and videos after a short, bounded probe.
    const posted = prober && probeKind ? probe(file, probeKind).then(post) : post(undefined)
    item.attached = posted.then(
      (result) => {
        if (item.released || !result) return
        if (accepted(result)) item.attach = "staged"
        else {
          item.attach = "failed"
          item.attachMessage = attachRejectionText(result.status === "uncertain" ? undefined : result.reason)
        }
        updateStatus(item, handle.resource.peek())
      },
      () => {
        if (item.released) return
        item.attach = "failed"
        item.attachMessage = attachRejectionText(undefined)
        updateStatus(item, handle.resource.peek())
      },
    )
    return item
  }

  /** Stop following it here. With `discard`, the core forgets it too (after its `attachFile` settled). */
  const release = (item: Item, discard: boolean) => {
    if (item.released) return
    item.released = true
    item.stop?.()
    item.handle?.unsubscribe()
    if (item.view.thumbnailUrl !== undefined && !item.thumbnailRevoked) {
      item.thumbnailRevoked = true
      urls.revoke(item.view.thumbnailUrl)
    }
    if (discard) {
      const id = item.view.id
      void item.attached
        .then(() => (item.posted ? client.intent({ kind: "discardAttachment", attachmentId: id }) : undefined))
        .then(undefined, () => undefined)
    }
  }

  // -------------------------------------------------------------------------
  // Commands

  const add = (files: readonly Blob[]) => {
    if (disposed || files.length === 0) return
    // The strip's view loads with the first file (a no-op once it is here).
    loadView?.()
    const tooLarge: string[] = []
    const empty: string[] = []
    let overCount = 0
    const added: Item[] = []
    const current = items.peek().length
    for (const file of files) {
      const name = fileNameOf(file)
      if (file.size === 0) empty.push(name)
      else if (file.size > limits.maxBytes) tooLarge.push(name)
      else if (current + added.length >= limits.maxCount) overCount += 1
      else added.push(start(file, makeId()))
    }
    const notes: string[] = []
    if (tooLarge.length === 1) notes.push(`${quoted(tooLarge[0]!)} is too large. The upload limit is ${megabytes(limits.maxBytes)}.`)
    else if (tooLarge.length > 1) notes.push(`${tooLarge.length} files are too large. The upload limit is ${megabytes(limits.maxBytes)}.`)
    if (empty.length === 1) notes.push(`${quoted(empty[0]!)} is empty.`)
    else if (empty.length > 1) notes.push(`${empty.length} files are empty.`)
    if (overCount > 0) notes.push(`You can attach up to ${limits.maxCount} files at a time.`)
    batch(() => {
      notice.set(notes.length > 0 ? notes.join(" ") : null)
      if (added.length > 0) items.set([...items.peek(), ...added])
    })
  }

  const remove = (id: AttachmentId) => {
    const list = items.peek()
    const item = list.find((candidate) => candidate.view.id === id)
    if (!item) return
    items.set(list.filter((candidate) => candidate !== item))
    release(item, true)
  }

  const retry = (id: AttachmentId) => {
    if (disposed) return
    const list = items.peek()
    const index = list.findIndex((candidate) => candidate.view.id === id)
    const item = list[index]
    if (!item || item.status.peek().phase !== "failed") return
    release(item, true)
    const next = start(item.file, makeId())
    items.set(list.map((candidate, at) => (at === index ? next : candidate)))
  }

  /** The info the core made for a staged attachment (needed for its optimistic row). */
  const infoOf = (item: Item): Promise<AttachmentInfo> =>
    new Promise((resolve, reject) => {
      let settled = false
      let stop: Dispose | undefined
      const timer = clock.setTimeout(() => finish(() => reject(new Error("attachmentNotReady"))), infoTimeoutMs)
      const finish = (fn: () => void) => {
        if (settled) return
        settled = true
        clock.clearTimeout(timer)
        queueMicrotask(() => stop?.())
        fn()
      }
      stop = untracked(() =>
        effect(() => {
          const info = item.info.get()
          const status = item.status.get()
          untracked(() => {
            if (status.phase === "failed" && item.attach === "failed") finish(() => reject(new Error("attachmentFailed")))
            else if (info && item.attach === "staged") finish(() => resolve(info))
          })
        }),
      )
    })

  const send = async (request: SendRequest): Promise<SendOutcome> => {
    const batchItems = [...items.peek()]
    if (batchItems.length === 0) return { status: "rejected", reason: "invalid" }
    if (batchItems.some((item) => item.attach === "failed")) return { status: "rejected", reason: "attachmentFailed" }
    await Promise.all(batchItems.map((item) => item.attached))
    if (disposed) return { status: "rejected", reason: "unavailable" }
    if (batchItems.some((item) => item.attach === "failed")) return { status: "rejected", reason: "attachmentFailed" }
    let infos: AttachmentInfo[]
    try {
      infos = await Promise.all(batchItems.map(infoOf))
    } catch (error) {
      const reason = error instanceof Error && error.message === "attachmentFailed" ? "attachmentFailed" : "attachmentNotReady"
      return { status: "rejected", reason }
    }
    if (disposed) return { status: "rejected", reason: "unavailable" }
    for (const item of batchItems) item.clientKey ??= makeClientKey()
    const date = Math.floor(clock.now() / 1000)
    const intents = mediaSendIntents({
      chatId,
      ...(request.text ? { text: request.text } : {}),
      ...(request.entities.length > 0 ? { entities: request.entities as Entity[] } : {}),
      ...(request.replyTo ? { replyToMessageId: request.replyTo.messageId } : {}),
      date,
      // The first send's commit consumes the draft (the sidebar's "Draft:" goes with it), as for text.
      draftRevision: request.revision,
      attachments: batchItems.map((item) => ({ attachmentId: item.view.id, clientKey: item.clientKey! })),
    })
    // Posted in order, in one task: the core accepts (and sends) them in this order. Each optimistic
    // row carries its intent's `tx`, the same row the core shows while the send is in the outbox
    // (`MessageRow.tx`), so a reload or a leader handoff does not show it twice.
    const pending = intents.map((intent, index) => {
      const handle = client.intent(intent)
      const row = optimisticMediaRow(intent, infos[index]!, options.userId, date, handle.tx)
      client.store.addOverlay(handle.tx, [placeRows(row)])
      return Promise.resolve(handle).then(
        (result) => result,
        () => undefined,
      )
    })
    const results = await Promise.all(pending)
    const sent = batchItems.filter((_, index) => accepted(results[index]))
    const kept = batchItems.length - sent.length
    batch(() => {
      if (sent.length > 0) items.set(items.peek().filter((item) => !sent.includes(item)))
      if (kept > 0 && accepted(results[0])) {
        notice.set(kept === 1 ? "1 attachment couldn’t be sent. It is still here." : `${kept} attachments couldn’t be sent. They are still here.`)
      }
    })
    // Sent attachments still uploading report activity until their upload ends.
    const stillUploading: Item[] = []
    for (const item of sent) {
      const phase = item.status.peek().phase
      if (phase === "staging" || phase === "uploading") {
        item.sending = true
        stillUploading.push(item)
        // Off the strip: its thumbnail goes now; the subscription stays for the activity.
        if (item.view.thumbnailUrl !== undefined && !item.thumbnailRevoked) {
          item.thumbnailRevoked = true
          urls.revoke(item.view.thumbnailUrl)
        }
      } else release(item, false)
    }
    if (stillUploading.length > 0) uploading.set([...uploading.peek(), ...stillUploading])
    const first = results[0]
    if (accepted(first)) return { status: "accepted" }
    return { status: "rejected", reason: first?.status === "uncertain" ? "uncertain" : (first?.reason ?? "unavailable") }
  }

  const activity = computed<UploadActivity | null>(() => {
    let best: UploadActivity | null = null
    for (const item of uploading.get()) {
      const next: UploadActivity =
        item.view.kind === "video" ? "uploadingVideo" : item.view.kind === "image" ? "uploadingPhoto" : "uploadingDocument"
      if (best === null || activityRank[next] > activityRank[best]) best = next
    }
    return best
  })

  return {
    chatId,
    items: views,
    hasAttachments,
    notice,
    activity,
    add,
    remove,
    retry,
    dismissNotice: () => notice.set(null),
    send,
    wrapSend: (textSend) => async (request) =>
      request.kind === "send" && items.peek().length > 0 ? await send(request) : await textSend(request),
    dispose: () => {
      if (disposed) return
      disposed = true
      for (const item of items.peek()) release(item, false)
      for (const item of uploading.peek()) release(item, false)
      uploading.set([])
    },
    discardAll: () => {
      const list = items.peek()
      items.set([])
      for (const item of list) release(item, true)
    },
  }
}

/**
 * Composer model options with attachments wired in: files from paste, drop
 * and the picker go to `attachments`, attachments make the composer
 * sendable, Send goes through `attachments.wrapSend`, and the attachment
 * reasons have words.
 *
 *     createComposerModel(withAttachments({ send, saveDraft, safeUrl, ... }, attachments))
 */
export const withAttachments = (options: ComposerModelOptions, attachments: ComposerAttachments): ComposerModelOptions => {
  const describe = options.errorText ?? sendErrorText
  return {
    ...options,
    send: attachments.wrapSend(options.send),
    onFiles: (files) => {
      attachments.add(files)
      options.onFiles?.(files)
    },
    hasAttachments: attachments.hasAttachments,
    errorText: (reason) => attachmentSendErrorText(reason) ?? describe(reason),
  }
}

// ---------------------------------------------------------------------------
// One per chat, for the session

export type AttachmentDrafts = {
  /** The chat's attachments; the same object for the session, so they survive the composer being recreated. */
  forChat(chatId: ChatID): ComposerAttachments
  /** Release every chat's (sign-out, session end). The core erases its own staging on sign-out. */
  dispose(): void
}

/**
 * Attachments per chat for a signed-in session. The composer model is made
 * per chat and disposed when the pane switches chats; the attachments in its
 * strip are durable obligations, so they live here instead and come back
 * when the chat does.
 */
export const createAttachmentDrafts = (options: Omit<ComposerAttachmentsOptions, "chatId">): AttachmentDrafts => {
  const byChat = new Map<ChatID, ComposerAttachments>()
  let disposed = false
  return {
    forChat: (chatId) => {
      let attachments = byChat.get(chatId)
      if (!attachments) {
        attachments = createComposerAttachments({ ...options, chatId })
        if (!disposed) byChat.set(chatId, attachments)
        else attachments.dispose()
      }
      return attachments
    },
    dispose: () => {
      disposed = true
      for (const attachments of byChat.values()) attachments.dispose()
      byChat.clear()
    },
  }
}
