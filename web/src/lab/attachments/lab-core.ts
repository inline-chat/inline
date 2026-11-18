/**
 * Lab only: a scripted core that plays the `media` and attachment resources
 * the real core would, over the real store client. It answers `media`
 * subscriptions from an asset table the lab drives (queued, downloading with
 * progress, ready, failed, absent), stages attachments (`attachFile`),
 * uploads them on a timer that the lab can pause, fail or cancel, and turns
 * `sendMedia` into a timeline row that goes from sending to sent (or
 * failed). Every byte is made in the page.
 */

import {
  type AttachmentInfo,
  type Command,
  type CoreEndpoint,
  type CoreMessageListener,
  type Intent,
  type IntentResult,
  type MediaRef,
  type MediaResource,
  type MessageRow,
  optimisticMediaRow,
  type ResourceChange,
  type SubId,
  type TxId,
  type UploadProgress,
} from "@inline/core-protocol"
import type { ChatID, MessageID, PhotoID, FileID, UserID } from "@inline/ids"
import { batch, signal } from "@inline/reactive"

export const LAB_CHAT = "1" as ChatID
export const LAB_ME = "1" as UserID
export const LAB_PEER = "2" as UserID

type Asset = {
  state: MediaResource["state"]
  received: number
  total: number
  failure?: string
  blob?: Blob
  /** Makes the bytes when the asset becomes ready. */
  make: () => Promise<Blob>
  /** Fail the first download, succeed on retry (an `opened` subscription). */
  failFirst?: boolean
  timer?: ReturnType<typeof setInterval>
}

type Attachment = {
  readonly id: string
  readonly blob: Blob
  info: AttachmentInfo
  upload: UploadProgress
  timer?: ReturnType<typeof setInterval>
  /** The send that names it, once `sendMedia` came. */
  send?: { clientKey: string; rowId: string }
}

export type LabLogEntry = { readonly at: number; readonly text: string }

const assetKey = (ref: MediaRef) => (ref.kind === "attachment" ? `a:${ref.attachmentId}` : `m:${ref.messageId}`)

export class LabCore implements CoreEndpoint {
  readonly rows = signal<readonly MessageRow[]>([])
  readonly hints = signal<readonly MediaRef[]>([])
  readonly log = signal<readonly LabLogEntry[]>([])
  /** What each `attachFile` carried from the composer's probe. */
  readonly attachHints = signal<
    readonly { fileName: string; as: string | null; width: number | null; height: number | null; duration: number | null; previewBytes: number | null }[]
  >([])
  /** Downloads and uploads advance on their own. Off: only the controls move them. */
  readonly auto = signal(true)
  /** Uploads advance (auto mode). */
  readonly uploading = signal(true)
  /** Subscriptions open, by sub. */
  readonly subs = new Map<SubId, { ref: MediaRef; priority: "visible" | "opened" }>()
  readonly assets = new Map<string, Asset>()
  readonly attachments = new Map<string, Attachment>()
  readonly #listeners = new Set<CoreMessageListener>()
  #revision = 0
  #nextMessageId = 1000

  // -------------------------------------------------------------------------
  // CoreEndpoint

  post(command: Command): void {
    switch (command.kind) {
      case "subscribe":
        if (command.query.kind !== "media") return
        this.subs.set(command.sub, { ref: command.query.media, priority: command.query.priority ?? "visible" })
        this.#note(`subscribe ${command.sub} ${assetKey(command.query.media)}${command.query.priority === "opened" ? " (opened)" : ""}`)
        this.#onSubscribe(command.sub)
        return
      case "unsubscribe":
        if (this.subs.delete(command.sub)) this.#note(`unsubscribe ${command.sub}`)
        return
      case "intent":
        this.#intent(command.tx, command.intent)
        return
      default:
        return
    }
  }

  subscribe(listener: CoreMessageListener): () => void {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  close(): void {
    this.#listeners.clear()
    for (const asset of this.assets.values()) clearInterval(asset.timer)
    for (const attachment of this.attachments.values()) clearInterval(attachment.timer)
  }

  // -------------------------------------------------------------------------
  // Seeding and controls

  /** An incoming media message and its asset (starts `queued`). */
  addIncoming(row: MessageRow, make: () => Promise<Blob>, options: { failFirst?: boolean } = {}): void {
    this.assets.set(`m:${row.messageId}`, {
      state: "queued",
      received: 0,
      total: 120_000,
      make,
      ...(options.failFirst ? { failFirst: true } : {}),
    })
    this.rows.set([...this.rows.peek(), row])
  }

  /** Put an asset in a state (the lab's buttons). `progress` is 0 to 1 for `downloading`. */
  async setMedia(messageId: string, state: MediaResource["state"], progress = 0.5): Promise<void> {
    const asset = this.assets.get(`m:${messageId}`)
    if (!asset) return
    clearInterval(asset.timer)
    asset.timer = undefined
    if (state === "ready") asset.blob ??= await asset.make()
    asset.state = state
    asset.received = state === "ready" ? asset.total : state === "downloading" ? Math.round(asset.total * progress) : 0
    asset.failure = state === "failed" ? "network" : undefined
    this.#publishAsset(`m:${messageId}`)
  }

  /** Put an attachment's upload in a state. */
  setUpload(attachmentId: string, state: UploadProgress["state"], fraction = 0.5): void {
    const attachment = this.attachments.get(attachmentId)
    if (!attachment) return
    clearInterval(attachment.timer)
    attachment.timer = undefined
    const total = attachment.upload.totalBytes
    attachment.upload = {
      state,
      sentBytes: state === "complete" ? total : state === "uploading" ? Math.round(total * fraction) : attachment.upload.sentBytes,
      totalBytes: total,
      ...(state === "failed" ? { retryable: true } : {}),
    }
    this.#publishAsset(`a:${attachmentId}`)
    this.#afterUpload(attachment)
  }

  /** Remove every row (the timeline unmounts its rows; their media is released). */
  clearRows(): void {
    for (const asset of this.assets.values()) clearInterval(asset.timer)
    this.rows.set([])
  }

  // -------------------------------------------------------------------------

  #note(text: string) {
    const entries = this.log.peek()
    this.log.set([...entries.slice(-79), { at: Math.round(performance.now()), text }])
  }

  #deliver(parts: { resources?: ResourceChange[]; settled?: IntentResult[] }) {
    const base = this.#revision
    this.#revision += 1
    const patch = {
      base,
      revision: this.#revision,
      rows: [],
      lists: [],
      resources: parts.resources ?? [],
      settled: parts.settled ?? [],
    }
    for (const listener of this.#listeners) listener({ kind: "patch", patch })
  }

  #settle(tx: TxId, status: IntentResult["status"], reason?: IntentResult["reason"]) {
    this.#deliver({ settled: [{ tx, status, ...(reason ? { reason } : {}) }] })
  }

  #resource(ref: MediaRef): MediaResource {
    if (ref.kind === "attachment") {
      const attachment = this.attachments.get(ref.attachmentId)
      if (!attachment) return { kind: "media", state: "absent" }
      return {
        kind: "media",
        state: "ready",
        blob: attachment.blob,
        size: attachment.blob.size,
        mimeType: attachment.info.mimeType,
        attachment: attachment.info,
        upload: attachment.upload,
      }
    }
    const asset = this.assets.get(assetKey(ref))
    if (!asset) return { kind: "media", state: "absent" }
    return {
      kind: "media",
      state: asset.state,
      ...(asset.state === "downloading" || asset.state === "queued" ? { receivedBytes: asset.received, totalBytes: asset.total } : {}),
      ...(asset.state === "ready" && asset.blob ? { blob: asset.blob, size: asset.blob.size, mimeType: asset.blob.type } : {}),
      ...(asset.failure ? { failure: asset.failure } : {}),
    }
  }

  #publishAsset(key: string) {
    const resources: ResourceChange[] = []
    for (const [sub, { ref }] of this.subs) if (assetKey(ref) === key) resources.push({ sub, value: this.#resource(ref) })
    if (resources.length > 0) this.#deliver({ resources })
  }

  #onSubscribe(sub: SubId) {
    const entry = this.subs.get(sub)
    if (!entry) return
    // The real core answers `absent` first, then resolves.
    this.#deliver({ resources: [{ sub, value: this.#resource(entry.ref) }] })
    if (entry.ref.kind !== "message" || !this.auto.peek()) return
    const key = assetKey(entry.ref)
    const asset = this.assets.get(key)
    if (!asset || asset.state === "ready" || asset.timer) return
    if (asset.state === "failed" && entry.priority !== "opened") return
    const failNow = asset.failFirst === true && entry.priority !== "opened"
    asset.state = "downloading"
    asset.received = 0
    this.#publishAsset(key)
    asset.timer = setInterval(() => {
      asset.received = Math.min(asset.total, asset.received + asset.total / 8)
      if (failNow && asset.received >= asset.total / 2) {
        clearInterval(asset.timer)
        asset.timer = undefined
        asset.state = "failed"
        asset.failure = "network"
        this.#publishAsset(key)
        return
      }
      if (asset.received < asset.total) {
        this.#publishAsset(key)
        return
      }
      clearInterval(asset.timer)
      asset.timer = undefined
      void asset.make().then((blob) => {
        asset.blob = blob
        asset.state = "ready"
        asset.failure = undefined
        this.#publishAsset(key)
      })
    }, 150)
  }

  #intent(tx: TxId, intent: Intent) {
    switch (intent.kind) {
      case "attachFile":
        this.attachHints.set([
          ...this.attachHints.peek().slice(-9),
          {
            fileName: intent.fileName,
            as: intent.as ?? null,
            width: intent.width ?? null,
            height: intent.height ?? null,
            duration: intent.duration ?? null,
            previewBytes: intent.preview?.byteLength ?? null,
          },
        ])
        this.#note(
          `attachFile ${intent.fileName} (${intent.file.size} bytes)${intent.as ? ` as ${intent.as}` : ""}${intent.width ? ` ${intent.width}×${intent.height}` : ""}${intent.duration ? ` ${intent.duration}s` : ""}${intent.preview ? ` preview ${intent.preview.byteLength} B` : ""}`,
        )
        void this.#attach(tx, intent)
        return
      case "discardAttachment": {
        const attachment = this.attachments.get(intent.attachmentId)
        clearInterval(attachment?.timer)
        this.attachments.delete(intent.attachmentId)
        this.#note(`discardAttachment ${intent.attachmentId.slice(0, 6)}`)
        this.#settle(tx, "confirmed")
        this.#publishAsset(`a:${intent.attachmentId}`)
        return
      }
      case "sendMedia":
        this.#sendMedia(tx, intent)
        return
      case "retrySend":
        this.#retrySend(tx, intent.clientKey)
        return
      case "deleteMessages":
        this.#cancel(tx, intent.clientKeys ?? [])
        return
      case "mediaHints":
        this.hints.set(intent.nearby)
        this.#note(`mediaHints ${intent.nearby.length}`)
        this.#settle(tx, "confirmed")
        return
      case "sendText": {
        const row: MessageRow = {
          kind: "message",
          id: `${LAB_CHAT}:r${intent.clientKey}`,
          chatId: LAB_CHAT,
          clientKey: intent.clientKey,
          messageId: String(this.#nextMessageId++) as MessageID,
          fromId: LAB_ME,
          out: true,
          date: intent.date ?? Math.floor(Date.now() / 1000),
          text: intent.text,
          state: "sent",
        }
        this.rows.set([...this.rows.peek(), row])
        this.#settle(tx, "accepted")
        return
      }
      default:
        this.#settle(tx, "rejected", "unsupported")
    }
  }

  async #attach(tx: TxId, intent: Extract<Intent, { kind: "attachFile" }>) {
    const isPhoto = ["image/jpeg", "image/png", "image/webp"].includes(intent.mimeType)
    let width: number | undefined
    let height: number | undefined
    if (isPhoto && typeof createImageBitmap === "function") {
      try {
        const bitmap = await createImageBitmap(intent.file)
        width = bitmap.width
        height = bitmap.height
        bitmap.close()
      } catch {
        // Not decodable: sent as a file.
      }
    }
    width ??= intent.width
    height ??= intent.height
    const kind: AttachmentInfo["kind"] =
      intent.as === "document" ? "document" : isPhoto && width && height ? "photo" : intent.mimeType.startsWith("video/") ? "video" : "document"
    const attachment: Attachment = {
      id: intent.attachmentId,
      blob: intent.file,
      info: {
        kind,
        fileName: intent.fileName,
        mimeType: intent.mimeType,
        size: intent.file.size,
        ...(width && height ? { width, height } : {}),
        ...(intent.duration ? { duration: intent.duration } : {}),
        ...(intent.preview ? { preview: intent.preview } : {}),
      },
      upload: { state: "staged", sentBytes: 0, totalBytes: intent.file.size },
    }
    this.attachments.set(attachment.id, attachment)
    this.#settle(tx, "confirmed")
    this.#publishAsset(`a:${attachment.id}`)
    this.#startUpload(attachment)
  }

  #startUpload(attachment: Attachment) {
    clearInterval(attachment.timer)
    attachment.upload = { state: "uploading", sentBytes: 0, totalBytes: attachment.upload.totalBytes }
    this.#publishAsset(`a:${attachment.id}`)
    if (!this.auto.peek()) return
    attachment.timer = setInterval(() => {
      if (!this.uploading.peek()) return
      const total = attachment.upload.totalBytes
      const sent = Math.min(total, attachment.upload.sentBytes + Math.max(1, Math.round(total / 12)))
      attachment.upload = { state: sent >= total ? "complete" : "uploading", sentBytes: sent, totalBytes: total }
      if (sent >= total) {
        clearInterval(attachment.timer)
        attachment.timer = undefined
      }
      this.#publishAsset(`a:${attachment.id}`)
      this.#afterUpload(attachment)
    }, 250)
  }

  /** A send whose upload ended: sent (with a server ID and server media), or failed. */
  #afterUpload(attachment: Attachment) {
    const send = attachment.send
    if (!send) return
    if (attachment.upload.state === "failed") {
      this.#updateRow(send.rowId, (row) => ({ ...row, state: "failed" }))
      return
    }
    if (attachment.upload.state === "canceled") {
      this.rows.set(this.rows.peek().filter((row) => row.id !== send.rowId))
      return
    }
    if (attachment.upload.state !== "complete") return
    const messageId = String(this.#nextMessageId++) as MessageID
    const info = attachment.info
    this.assets.set(`m:${messageId}`, {
      state: "ready",
      received: info.size,
      total: info.size,
      blob: attachment.blob,
      make: () => Promise.resolve(attachment.blob),
    })
    this.#updateRow(send.rowId, (row) => {
      const { upload: _upload, ...rest } = row
      const fileUniqueId = `lab-${attachment.id}`
      const media: MessageRow["media"] =
        info.kind === "photo" && info.width && info.height
          ? {
              kind: "photo",
              photo: {
                id: messageId as unknown as PhotoID,
                fileUniqueId,
                sizes: [{ type: "f", width: info.width, height: info.height, size: info.size, fileUniqueId }],
              },
            }
          : {
              kind: "document",
              document: { id: messageId as unknown as FileID, fileName: info.fileName, mimeType: info.mimeType, size: info.size, fileUniqueId },
            }
      return { ...rest, messageId, state: "sent", media }
    })
    this.attachments.delete(attachment.id)
  }

  #updateRow(rowId: string, update: (row: MessageRow) => MessageRow) {
    this.rows.set(this.rows.peek().map((row) => (row.id === rowId ? update(row) : row)))
  }

  #sendMedia(tx: TxId, intent: Extract<Intent, { kind: "sendMedia" }>) {
    const attachment = this.attachments.get(intent.attachmentId)
    if (!attachment) {
      this.#settle(tx, "rejected", "invalid")
      return
    }
    const row = optimisticMediaRow(intent, attachment.info, LAB_ME, intent.date ?? Math.floor(Date.now() / 1000))
    attachment.send = { clientKey: intent.clientKey, rowId: row.id }
    batch(() => this.rows.set([...this.rows.peek(), row]))
    this.#note(`sendMedia ${attachment.info.fileName}${intent.text ? ` "${intent.text}"` : ""}`)
    this.#settle(tx, "accepted")
    if (attachment.upload.state === "complete" || attachment.upload.state === "failed") this.#afterUpload(attachment)
  }

  #retrySend(tx: TxId, clientKey: string) {
    const attachment = [...this.attachments.values()].find((candidate) => candidate.send?.clientKey === clientKey)
    if (!attachment?.send) {
      this.#settle(tx, "rejected", "invalid")
      return
    }
    this.#note(`retrySend ${clientKey}`)
    this.#updateRow(attachment.send.rowId, (row) => ({ ...row, state: "sending" }))
    this.#settle(tx, "accepted")
    this.#startUpload(attachment)
  }

  #cancel(tx: TxId, clientKeys: readonly string[]) {
    for (const attachment of this.attachments.values()) {
      if (!attachment.send || !clientKeys.includes(attachment.send.clientKey)) continue
      clearInterval(attachment.timer)
      attachment.upload = { ...attachment.upload, state: "canceled" }
      this.#note(`cancel ${attachment.send.clientKey}`)
      this.#publishAsset(`a:${attachment.id}`)
      this.#afterUpload(attachment)
      this.attachments.delete(attachment.id)
    }
    this.#settle(tx, "confirmed")
  }
}
