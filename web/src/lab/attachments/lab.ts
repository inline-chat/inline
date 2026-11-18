/**
 * Lab only: the attachments lab's model. The real media layer
 * (`createCoreMediaSources`), the real composer model with attachments
 * (`createComposerAttachments`, `withAttachments`), the real content
 * environment and store client, over `LabCore`. Object URLs from all three
 * (media, attachment thumbnails, blurred previews) go through counting APIs,
 * so the lab can show that every one is revoked.
 */

import type { MessageRow, MessageRowId } from "@inline/core-protocol"
import type { MessageID, PhotoID } from "@inline/ids"
import { browserScheduler, createStoreClient, manualTime, signal } from "@inline/reactive"
import { type ComposerAttachments, createComposerAttachments, withAttachments } from "../../features/composer/attachments"
import { DropTarget } from "../../features/composer/drop-target"
import { createComposerModel, type ComposerModel } from "../../features/composer/model"
import { type ContentEnv, createContentEnv } from "../../features/content/env"
import { PreviewUrls } from "../../features/content/preview-urls"
import { countingBlobUrls, type CountingBlobUrls } from "../../features/media/object-urls"
import { createCoreMediaSources, type CoreMediaSources, MEDIA_GRACE_MS } from "../../features/media/sources"
import type { MediaVisibility } from "../../features/media/visibility"
import { type Picture, pictureBlob, pictureStripped } from "../content/pictures"
import { LAB_CHAT, LAB_ME, LAB_PEER, LabCore } from "./lab-core"

export type HeightChange = { readonly rowId: MessageRowId; readonly from: number; readonly to: number }

const pictures: readonly (Picture & { failFirst?: boolean })[] = [
  { width: 1600, height: 1067, hue: 200, label: "Harbor" },
  { width: 900, height: 1200, hue: 20, label: "Portrait" },
  { width: 1200, height: 1200, hue: 120, label: "Square", failFirst: true },
  { width: 2000, height: 600, hue: 280, label: "Panorama" },
  { width: 800, height: 600, hue: 50, label: "Sketch" },
  { width: 1280, height: 960, hue: 330, label: "Garden" },
  { width: 1000, height: 1400, hue: 160, label: "Tower" },
  { width: 1400, height: 900, hue: 240, label: "Night" },
]

let generated = 0

/** A generated JPEG as a `File`, as paste or the picker would hand one over. */
export const generatedImage = async (index = generated): Promise<File> => {
  generated += 1
  const blob = await pictureBlob({ width: 1200 + (index % 3) * 200, height: 900, hue: (index * 47) % 360, label: `Image ${index + 1}` })
  return new File([blob], `generated-${index + 1}.jpg`, { type: blob.type })
}

/** A small generated file of some type (a PDF-like document, a text file). */
export const generatedFile = (name: string, type: string, bytes: number): File =>
  new File([new Uint8Array(Math.max(1, bytes)).fill(65)], name, { type })

/** Real time drives the manual clock, and the lab can skip ahead (the grace period). */
const labClock = () => {
  const time = manualTime()
  let last = performance.now()
  setInterval(() => {
    const now = performance.now()
    time.advance(now - last)
    last = now
  }, 50)
  return time
}

export class AttachmentsLab {
  readonly core = new LabCore()
  readonly clock = labClock()
  readonly client = createStoreClient({ endpoint: this.core, scheduler: browserScheduler() })
  /** Media URLs (the sources) and attachment thumbnails. */
  readonly urls: CountingBlobUrls = countingBlobUrls()
  /** Blurred previews from row bytes. */
  readonly previewUrls: CountingBlobUrls = countingBlobUrls()
  readonly sources: CoreMediaSources
  readonly visibility: MediaVisibility<object>
  readonly env: ContentEnv
  readonly attachments: ComposerAttachments
  readonly composer: ComposerModel
  readonly drop: DropTarget
  /** Bumped whenever a count the panel shows may have changed. */
  readonly tick = signal(0)
  readonly heightChanges = signal<readonly HeightChange[]>([])
  readonly selected = signal<string | null>(null)
  readonly #heights = new Map<MessageRowId, number>()

  constructor() {
    this.sources = createCoreMediaSources({ client: this.client, urls: this.urls, clock: this.clock })
    this.visibility = this.sources.createVisibility()
    const previews = new PreviewUrls({
      api: {
        create: (bytes) => this.previewUrls.create(new Blob([bytes as Uint8Array<ArrayBuffer>], { type: "image/jpeg" })),
        revoke: (url) => this.previewUrls.revoke(url),
      },
    })
    this.env = createContentEnv({ sources: this.sources, previews, me: LAB_ME, layout: { availableWidth: 360 } })
    this.attachments = createComposerAttachments({
      client: this.client,
      chatId: LAB_CHAT,
      userId: LAB_ME,
      urls: this.urls,
      clock: this.clock,
    })
    this.composer = createComposerModel(
      withAttachments(
        {
          safeUrl: (url) => (/^https?:\/\//.test(url) ? url : null),
          send: async (request) => {
            const result = await this.client.intent({
              kind: "sendText",
              chatId: LAB_CHAT,
              clientKey: String(Date.now()),
              text: request.text,
              date: Math.floor(Date.now() / 1000),
            })
            return result.status === "accepted" || result.status === "confirmed"
              ? { status: "accepted" }
              : { status: "rejected", reason: result.reason ?? "unavailable" }
          },
        },
        this.attachments,
      ),
    )
    this.drop = new DropTarget({ onFiles: (files) => this.attachments.add(files) })
    const bump = () => this.tick.set(this.tick.peek() + 1)
    this.urls.subscribe(bump)
    this.previewUrls.subscribe(bump)
    setInterval(bump, 250)
  }

  /** Incoming photos (one fails its first download) and one document, each `queued` until seen. */
  async seed(): Promise<void> {
    let id = 100
    for (const [index, picture] of pictures.entries()) {
      id += 1
      const stripped = pictureStripped(picture)
      const row: MessageRow = {
        kind: "message",
        id: `${LAB_CHAT}:${id}`,
        chatId: LAB_CHAT,
        messageId: String(id) as MessageID,
        fromId: LAB_PEER,
        out: false,
        date: 1_700_000_000 + id,
        text: index === 1 ? "A tall one" : "",
        state: "sent",
        media: {
          kind: "photo",
          photo: {
            id: String(id) as PhotoID,
            fileUniqueId: `lab-photo-${id}`,
            sizes: [
              { type: "b", width: Math.round(picture.width / 5), height: Math.round(picture.height / 5), size: 9_000, fileUniqueId: `lab-photo-${id}-b` },
              { type: "f", width: picture.width, height: picture.height, size: 120_000, fileUniqueId: `lab-photo-${id}-f` },
            ],
            ...(stripped ? { stripped } : {}),
          },
        },
      }
      this.core.addIncoming(
        row,
        () => pictureBlob(picture, Math.max(picture.width, picture.height) / 2),
        picture.failFirst ? { failFirst: true } : {},
      )
    }
  }

  /** The timeline's own measurement: a row whose height changes after it first laid out is a failure. */
  readonly measureRow = (rowId: MessageRowId) => ({
    attach: (element: Element) => {
      const observer = new ResizeObserver(() => {
        const height = Math.round(element.getBoundingClientRect().height * 10) / 10
        if (height === 0) return
        const first = this.#heights.get(rowId)
        if (first === undefined) this.#heights.set(rowId, height)
        else if (first !== height) {
          this.heightChanges.set([...this.heightChanges.peek(), { rowId, from: first, to: height }])
          this.#heights.set(rowId, height)
        }
      })
      observer.observe(element)
      return () => observer.disconnect()
    },
  })

  /** Remove every row and every attachment. After the grace period every URL is revoked. */
  removeAll(): void {
    this.core.clearRows()
    this.attachments.discardAll()
    this.#heights.clear()
  }

  /** Skip the media layer's grace period. */
  skipGrace(): void {
    this.clock.advance(MEDIA_GRACE_MS + 1)
  }

  liveUrls(): number {
    return this.urls.live() + this.previewUrls.live()
  }
}
