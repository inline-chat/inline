/**
 * The content lab's model: rows as signals (a change to one message renders
 * one row), the content environment, media sources that make every byte in
 * the page with controllable timing (fast, slow, failing once, never, missing,
 * and a hold for the height check), a streaming driver with per-block render
 * counts, and the height check. Framework-free; views read it with
 * `useSignal`.
 */

import { userAvatarSeed, userShortName } from "@inline/chat-ui"
import type { MessageRow, MessageRowId, PhotoInfo, VideoInfo, VoiceInfo } from "@inline/core-protocol"
import type { PhotoID, UserID } from "@inline/ids"
import { type ReadSignal, type Signal, signal } from "@inline/reactive"
import {
  type ContentEnv,
  type ContentHandlers,
  createContentEnv,
  LoadedMedia,
  type MediaSource,
  type MediaSources,
  type MediaSourceState,
  messageHasContent,
  PreviewUrls,
  type RevealStatus,
} from "../../features/content"
import {
  attachmentFixtures,
  type Behavior,
  blockFixtures,
  chatTitles,
  type Fixture,
  fileId,
  headerFixtures,
  type MediaFactory,
  mediaFixtures,
  photoId,
  serviceFixtures,
  STREAM_TOTAL_WORDS,
  streamRow,
  userById,
  VIEWER_ID,
} from "./fixtures"
import { animationBlob, type Picture, pictureBlob, pictureStripped, voiceBlob } from "./pictures"

export const STREAM_ROW_ID: MessageRowId = "88:stream"

type Registered =
  | { kind: "picture"; picture: Picture; behavior: Behavior }
  | { kind: "animation"; picture: Picture; behavior: Behavior }
  | { kind: "voice"; seconds: number; behavior: Behavior }

export type HeightResult = {
  readonly rowId: string
  readonly title: string
  readonly before: number
  readonly after: number
  readonly equal: boolean
  readonly media: readonly { readonly key: string; readonly before: number; readonly after: number }[]
}

const frames = (count: number) =>
  new Promise<void>((resolve) => {
    let left = count
    const step = () => (--left <= 0 ? resolve() : requestAnimationFrame(step))
    requestAnimationFrame(step)
  })

const delay = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

// ---------------------------------------------------------------------------
// Media sources made in the page

class LabSource implements MediaSource {
  readonly #state = signal<MediaSourceState>({ status: "pending" })
  #attempt = 0
  #started = false
  #running = 0

  constructor(
    private readonly sources: LabSources,
    private readonly entry: Registered,
    private readonly key: string,
  ) {}

  get state(): ReadSignal<MediaSourceState> {
    if (!this.#started) {
      this.#started = true
      queueMicrotask(() => void this.#run())
    }
    return this.#state
  }

  get busy(): boolean {
    return this.#running > 0
  }

  retry(): void {
    this.#attempt += 1
    this.#state.set({ status: "pending" })
    void this.#run()
  }

  async #run(): Promise<void> {
    const behavior = this.entry.behavior
    if (behavior === "missing") {
      this.#state.set({ status: "failed" })
      return
    }
    if (behavior === "never") return
    this.#running += 1
    try {
      const attempt = this.#attempt
      const blob = await this.sources.blob(this.key, this.entry)
      if (behavior === "slow") await delay(this.sources.lab.slowDelay)
      await this.sources.lab.gate()
      if (this.sources.disposed || attempt !== this.#attempt) return
      if (!blob) {
        this.#state.set({ status: "failed" })
        return
      }
      const url = this.sources.url(blob)
      // A failing source hands out a revoked URL once: the element's load fails.
      if (behavior === "fail" && attempt === 0) URL.revokeObjectURL(url)
      this.#state.set({ status: "ready", url })
    } finally {
      this.#running -= 1
    }
  }
}

class LabSources implements MediaSources {
  disposed = false
  readonly #sources = new Map<string, LabSource>()
  readonly #urls: string[] = []

  constructor(
    readonly lab: ContentLab,
    private readonly registry: ReadonlyMap<string, Registered>,
    private readonly blobs: Map<string, Promise<Blob | undefined>>,
  ) {}

  blob(key: string, entry: Registered): Promise<Blob | undefined> {
    let blob = this.blobs.get(key)
    if (!blob) {
      blob =
        entry.kind === "picture"
          ? pictureBlob(entry.picture).catch(() => undefined)
          : entry.kind === "animation"
            ? animationBlob(entry.picture).catch(() => undefined)
            : Promise.resolve(voiceBlob(entry.seconds))
      this.blobs.set(key, blob)
    }
    return blob
  }

  url(blob: Blob): string {
    const url = URL.createObjectURL(blob)
    this.#urls.push(url)
    return url
  }

  get busy(): boolean {
    for (const source of this.#sources.values()) if (source.busy) return true
    return false
  }

  #source(key: string): MediaSource {
    let source = this.#sources.get(key)
    if (!source) {
      const entry = this.registry.get(key) ?? { kind: "picture", picture: { width: 1, height: 1, hue: 0, label: "" }, behavior: "missing" }
      source = new LabSource(this, entry, key)
      this.#sources.set(key, source)
    }
    return source
  }

  photo = (photo: PhotoInfo): MediaSource => this.#source(`photo:${photo.id}`)
  video = (video: VideoInfo): MediaSource => this.#source(`video:${video.id}`)
  voice = (voice: VoiceInfo): MediaSource => this.#source(`voice:${voice.id}`)

  dispose(): void {
    this.disposed = true
    for (const url of this.#urls) URL.revokeObjectURL(url)
  }
}

// ---------------------------------------------------------------------------

export type Section = { readonly id: string; readonly title: string; readonly fixtures: readonly Fixture[] }

export class ContentLab {
  readonly log = signal("Click media, buttons and links: the lab notes what the app would do.")
  readonly env: Signal<ContentEnv>
  readonly generation = signal(0)
  readonly streaming = signal(false)
  readonly heights = signal<readonly HeightResult[] | undefined>(undefined)
  readonly checking = signal(false)
  readonly canApprove = signal(false)
  readonly sections: readonly Section[]
  readonly services: readonly Fixture[]
  readonly blockRenders = new Map<string, number>()
  slowDelay = 1500

  readonly #registry = new Map<string, Registered>()
  readonly #blobs = new Map<string, Promise<Blob | undefined>>()
  readonly #full = new Map<MessageRowId, Signal<MessageRow>>()
  readonly #display = new Map<MessageRowId, Signal<MessageRow>>()
  readonly #titles = new Map<MessageRowId, string>()
  readonly #previews = new PreviewUrls()
  #sources: LabSources
  #held = false
  #waiters: (() => void)[] = []
  #streamTimer: ReturnType<typeof setInterval> | undefined
  #streamWords = 1
  readonly #streamStarted = Math.floor(Date.now() / 1000)
  #countsElement: HTMLElement | null = null
  #countsFrame = 0

  constructor() {
    const factory = this.#factory()
    this.sections = [
      { id: "media", title: "Media", fixtures: mediaFixtures(factory) },
      { id: "blocks", title: "Rich blocks and agent cards", fixtures: blockFixtures(factory) },
      { id: "attachments", title: "Attachments and buttons", fixtures: attachmentFixtures(factory) },
      { id: "headers", title: "Forward, via, reply threads", fixtures: headerFixtures() },
    ]
    for (const section of this.sections) for (const fixture of section.fixtures) this.#add(fixture.row, fixture.title)
    this.services = serviceFixtures()
    for (const fixture of this.services) this.#add(fixture.row, fixture.title)
    this.#add(streamRow(STREAM_ROW_ID, this.#streamWords, this.#streamStarted), "Streaming")
    this.#sources = new LabSources(this, this.#registry, this.#blobs)
    this.env = signal(this.#makeEnv())
  }

  // -- rows

  /** The row the message row view gets: block messages without their text (see README, "Needs from others"). */
  display(rowId: MessageRowId): ReadSignal<MessageRow | undefined> {
    return this.#display.get(rowId) ?? missingRow
  }

  full(rowId: MessageRowId): MessageRow | undefined {
    return this.#full.get(rowId)?.peek()
  }

  title(rowId: MessageRowId): string {
    return this.#titles.get(rowId) ?? rowId
  }

  #add(row: MessageRow, title: string): void {
    this.#full.set(row.id, signal(row))
    this.#display.set(row.id, signal(displayRow(row)))
    this.#titles.set(row.id, title)
  }

  #set(row: MessageRow): void {
    this.#full.get(row.id)?.set(row)
    this.#display.get(row.id)?.set(displayRow(row))
  }

  note(text: string): void {
    this.log.set(text)
  }

  // -- environment

  #handlers(): ContentHandlers {
    return {
      onOpenMedia: (input) => this.note(`Open ${input.kind} ${input.key}${input.index !== undefined ? ` (#${input.index + 1})` : ""} in the viewer`),
      onDownload: (input) => this.note(`Download ${input.media.kind === "document" ? input.media.document.fileName : input.media.kind}`),
      onSubmitForm: async (input) => {
        this.note(`Submitting ${input.formId}: ${JSON.stringify(input.values)}`)
        await delay(800)
        const name = input.values.find((value) => value.fieldId === "name")
        if (name?.value.kind === "text" && name.value.text.trim().toLowerCase() === "fail") {
          this.note("The lab refused the submit (the release name was “fail”)")
          throw new Error("refused")
        }
        this.note(`Form ${input.formId} sent; the form locks and any secret is gone`)
      },
      onAction: async ({ button }) => {
        const behavior = button.behavior
        if (button.confirm) this.note(`Would confirm “${button.confirm.title}” with “${button.confirm.confirmLabel}”`)
        switch (behavior.kind) {
          case "callback":
            this.note(`Callback ${button.actionId}: waiting 1.5 s for the bot`)
            await delay(1500)
            this.note(`Callback ${button.actionId} answered`)
            return
          case "copy":
            this.note(`Copied “${behavior.text}”`)
            return
          case "compose":
            this.note(`Composer gets “${behavior.text}”`)
            return
          case "openLink":
            this.note(`Open ${behavior.peer.kind} ${behavior.peer.kind === "chat" ? behavior.peer.chatId : behavior.peer.userId}`)
            return
          case "openUrl":
            this.note(`Open ${behavior.link.href} after confirming`)
            return
          case "unavailable":
            this.note(behavior.reason)
            return
        }
      },
      onCompose: (text) => this.note(`Composer gets “${text}”`),
      onOpenPeer: (peer) => this.note(`Open ${peer.kind} ${peer.kind === "chat" ? peer.chatId : peer.userId}`),
      onForward: (target) => this.note(`Open the forward source: ${target.kind} ${target.kind === "chat" ? target.chatId : target.userId}`),
      onOpenReplies: (input) => this.note(`Open reply thread ${input.chatId}`),
      onServiceLink: (link) => this.note(`Service link: ${link.kind} ${link.kind === "thread" ? link.chatId : link.userId}`),
      onCopyText: (text) => this.note(`Copied ${text.length} characters`),
      onMention: (target) => this.note(`Mention ${JSON.stringify(target)}`),
      onThreadRef: (target) => this.note(`Thread ${JSON.stringify(target)}`),
      onAppLink: (link) => this.note(`App link ${link.href}`),
      onExternalLink: (link, event) => {
        event.preventDefault()
        this.note(`External link ${link.href} (not followed in the lab)`)
      },
    }
  }

  #makeEnv(): ContentEnv {
    return createContentEnv({
      sources: this.#sources,
      previews: this.#previews,
      loaded: new LoadedMedia(),
      handlers: this.#handlers(),
      me: VIEWER_ID,
      canUse: (grant) => grant !== "approve" || this.canApprove.peek(),
      names: {
        user: (userId: UserID) => {
          const user = userById.get(userId)
          return user ? { name: userShortName(user), seed: userAvatarSeed(user) } : undefined
        },
        forwardTitle: (forward) =>
          forward.fromPeer?.kind === "chat"
            ? chatTitles.get(forward.fromPeer.chatId)
            : forward.fromUserId
              ? (() => {
                  const user = userById.get(forward.fromUserId)
                  return user ? userShortName(user) : undefined
                })()
              : undefined,
        botName: (userId) => {
          const user = userById.get(userId)
          return user ? userShortName(user) : undefined
        },
      },
      debug: {
        onBlockRender: (rowId, key) => this.#countBlock(rowId, key),
      },
    })
  }

  setCanApprove(value: boolean): void {
    this.canApprove.set(value)
    this.env.set(this.#makeEnv())
  }

  /** Fresh sources and an empty "already revealed" set: every image loads again. */
  reload(): void {
    this.#sources.dispose()
    this.#sources = new LabSources(this, this.#registry, this.#blobs)
    this.env.set(this.#makeEnv())
    this.generation.set(this.generation.peek() + 1)
  }

  // -- hold (height check)

  gate(): Promise<void> {
    if (!this.#held) return Promise.resolve()
    return new Promise((resolve) => this.#waiters.push(resolve))
  }

  #release(): void {
    this.#held = false
    const waiters = this.#waiters
    this.#waiters = []
    for (const resolve of waiters) resolve()
  }

  /**
   * Reload with every source held, measure each row and media box, release,
   * wait for the loads to finish, measure again. Heights must be equal.
   */
  async checkHeights(): Promise<readonly HeightResult[]> {
    this.checking.set(true)
    this.heights.set(undefined)
    this.#held = true
    this.reload()
    await frames(3)
    const before = measure()
    this.#release()
    const deadline = performance.now() + this.slowDelay + 6000
    while (performance.now() < deadline) {
      await frames(2)
      if (!this.#sources.busy && allImagesSettled()) break
    }
    await delay(400)
    await frames(2)
    const after = measure()
    const results: HeightResult[] = []
    for (const [rowId, first] of before) {
      const second = after.get(rowId)
      if (!second) continue
      results.push({
        rowId,
        title: this.title(rowId),
        before: first.height,
        after: second.height,
        equal: Math.abs(first.height - second.height) < 0.5,
        media: first.media.map((box) => ({ key: box.key, before: box.height, after: second.media.find((m) => m.key === box.key)?.height ?? -1 })),
      })
    }
    this.heights.set(results)
    this.checking.set(false)
    this.note(
      results.every((result) => result.equal)
        ? `Height check: all ${results.length} rows kept their height`
        : `Height check: ${results.filter((result) => !result.equal).length} rows changed height`,
    )
    return results
  }

  // -- streaming

  startStream(rate = 30): void {
    this.stopStream()
    this.streaming.set(true)
    this.#streamTimer = setInterval(() => {
      if (this.#streamWords >= STREAM_TOTAL_WORDS) {
        this.stopStream()
        return
      }
      this.#streamWords += 1
      this.#set(streamRow(STREAM_ROW_ID, this.#streamWords, this.#streamStarted))
    }, 1000 / rate)
  }

  stopStream(): void {
    if (this.#streamTimer !== undefined) clearInterval(this.#streamTimer)
    this.#streamTimer = undefined
    this.streaming.set(false)
  }

  resetStream(): void {
    this.stopStream()
    this.#streamWords = 1
    this.#set(streamRow(STREAM_ROW_ID, this.#streamWords, this.#streamStarted))
    for (const key of Array.from(this.blockRenders.keys())) if (key.startsWith(`${STREAM_ROW_ID}|`)) this.blockRenders.delete(key)
    this.#scheduleCounts()
  }

  // -- block render counts

  /** Where the streaming row's per-block counts are written (directly, so counting renders nothing). */
  countsTarget = (element: HTMLElement | null): void => {
    this.#countsElement = element
    this.#scheduleCounts()
  }

  #countBlock(rowId: MessageRowId, key: string): void {
    const id = `${rowId}|${key}`
    this.blockRenders.set(id, (this.blockRenders.get(id) ?? 0) + 1)
    if (rowId === STREAM_ROW_ID) this.#scheduleCounts()
  }

  #scheduleCounts(): void {
    if (this.#countsFrame !== 0 || typeof requestAnimationFrame === "undefined") return
    this.#countsFrame = requestAnimationFrame(() => {
      this.#countsFrame = 0
      const element = this.#countsElement
      if (!element) return
      const lines: string[] = []
      for (const [id, count] of this.blockRenders) {
        if (id.startsWith(`${STREAM_ROW_ID}|`)) lines.push(`${id.slice(STREAM_ROW_ID.length + 1).padEnd(16)} ${count}`)
      }
      element.textContent = lines.length > 0 ? lines.join("\n") : "(no renders yet)"
    })
  }

  streamCounts(): Record<string, number> {
    const result: Record<string, number> = {}
    for (const [id, count] of this.blockRenders) if (id.startsWith(`${STREAM_ROW_ID}|`)) result[id.slice(STREAM_ROW_ID.length + 1)] = count
    return result
  }

  // -- media factory for fixtures

  #factory(): MediaFactory {
    const sizesFor = (picture: Picture, id: string) => {
      const scale = (side: number) => Math.min(1, side / Math.max(picture.width, picture.height))
      return (
        [
          ["b", 140],
          ["c", 320],
          ["d", 800],
          ["f", 2560],
        ] as const
      ).map(([type, side]) => ({
        type,
        width: Math.max(1, Math.round(picture.width * scale(side))),
        height: Math.max(1, Math.round(picture.height * scale(side))),
        fileUniqueId: `lab-${id}-${type}`,
      }))
    }
    return {
      photo: (id, picture, behavior, options) => {
        this.#registry.set(`photo:${id}`, { kind: "picture", picture, behavior })
        const stripped = options?.noStripped ? undefined : pictureStripped(picture)
        return {
          id: photoId(id),
          ...(options?.format ? { format: options.format } : { format: "jpeg" as const }),
          sizes: sizesFor(picture, id),
          ...(stripped ? { stripped } : {}),
        }
      },
      video: (id, picture, behavior, info) => {
        this.#registry.set(`video:${id}`, { kind: "animation", picture, behavior })
        const thumbnailId = `${id}-thumb`
        this.#registry.set(`photo:${thumbnailId}`, { kind: "picture", picture, behavior })
        const stripped = pictureStripped(picture)
        return {
          id: fileId(id),
          width: picture.width,
          height: picture.height,
          duration: info.duration,
          size: 4_200_000,
          thumbnail: { id: thumbnailId as PhotoID, sizes: sizesFor(picture, thumbnailId), ...(stripped ? { stripped } : {}) },
          ...(info.animated ? { animated: true as const } : {}),
        }
      },
      voice: (id, seconds, behavior) => {
        this.#registry.set(`voice:${id}`, { kind: "voice", seconds, behavior })
        const waveform = new Uint8Array(96).map((_, index) => Math.round(128 + 110 * Math.sin(index * 0.37) * Math.cos(index * 0.11)))
        return { id: fileId(id), duration: seconds, size: seconds * 16000, mimeType: "audio/wav", waveform }
      },
    }
  }
}

const missingRow: ReadSignal<MessageRow | undefined> = signal(undefined)

/** Rows with blocks reach the row view without their text, so the text is drawn once (by the blocks). */
const displayRow = (row: MessageRow): MessageRow => {
  if (!row.blocks?.length) return row
  const copy: MessageRow = { ...row, text: "" }
  delete copy.entities
  return copy
}

/** Whether the row's content slot has anything (block rows are judged on their full row). */
export const labHasContent = (lab: ContentLab, display: MessageRow): boolean => {
  const full = lab.full(display.id) ?? display
  return messageHasContent(full)
}

type Measured = { height: number; media: { key: string; height: number }[] }

const measure = (): Map<string, Measured> => {
  const result = new Map<string, Measured>()
  for (const row of document.querySelectorAll<HTMLElement>("[data-lab-measure] [data-message-row]")) {
    const id = row.dataset.messageRow
    if (!id) continue
    result.set(id, {
      height: row.getBoundingClientRect().height,
      media: [...row.querySelectorAll<HTMLElement>("[data-media-box]")].map((box) => ({
        key: box.dataset.mediaBox ?? "",
        height: box.getBoundingClientRect().height,
      })),
    })
  }
  return result
}

const allImagesSettled = (): boolean => {
  for (const image of document.querySelectorAll<HTMLImageElement>("[data-lab-measure] [data-media-box] img")) {
    if (!image.complete) return false
  }
  return true
}

export type { RevealStatus }
