/**
 * Attachments and media sends (`attachFile`, `discardAttachment`,
 * `sendMedia`, `retrySend` and cancel by `deleteMessages`).
 *
 * Storage, with no schema change:
 * - An attachment's bytes and upload job: the media core (`uploads/<id>.body`
 *   and its job row), keyed by the attachment ID. Its info (kind, name,
 *   dimensions, preview) beside them: `attachments/<id>.json` under the
 *   account's media root, so `MediaCore.erase` removes it with the rest.
 * - A send: a host record (`durable.ts`, kind `mediaSend`) committed in the
 *   same transaction as the optimistic message row (invariant 2). It names
 *   the attachment, the random ID and the temporary message ID.
 *
 * The send: wait for the upload's completion (the media core persists it
 * before telling anyone, and keeps it until released), then `SEND_MESSAGE`
 * with the server's media ID and the record's random ID. The server's result
 * and the record's deletion commit together; only then is the upload
 * released. A restart at any step resumes from the record: the upload
 * resumes or is already complete, and a send that may have reached the
 * server is sent again under the same random ID, which the server
 * deduplicates. Exactly one message.
 *
 * Sends of one chat go out in the order they were accepted.
 */
import type { InputMedia, UploadComplete } from "@inline-chat/protocol/core"
import {
  ATTACHMENT_PREVIEW_MAX_BYTES,
  isAttachmentId,
  isClientKey,
  rowKey,
  sentMessageRowId,
  type AttachmentInfo,
  type Intent,
  type IntentResult,
  type MessageUpload,
  type RowKey,
  type TxId,
} from "@inline/core-protocol"
import { messageId as makeMessageId, type ChatID, type MessageID, type UserID } from "@inline/ids"
import type { Log } from "@inline/log"
import type { AuthStore } from "../auth"
import type { Db } from "../database"
import { DbObjectKind, messageKey, MessageSendingStatus, type Message, type PendingTransaction } from "../database/models"
import { DbQueryPlanType } from "../database/types"
import { decodeRecord, encodeRecord } from "../media/bytes"
import type { ByteStore } from "../media/store/byte-store"
import type { ImagePreparer } from "../media/image/prepare-image"
import type { MediaCore } from "../media"
import { entitiesToProtocol, isValidEntityList } from "../queries/rows"
import type { RealtimeClient } from "../realtime/realtime"
import { TransactionFailure } from "../realtime/transactions"
import { generateTempId } from "../realtime/transactions/helpers"
import {
  sendMediaMessage,
  type SendMediaMessageContext,
} from "../realtime/transactions/send-media-message"
import { deleteHostRecord, hostRecordPayload, hostRecords, hostSend, newHostRecordId, writeHostRecord } from "./durable"
import { consumeDraft } from "./drafts"
import { hasErrorNamed } from "./errors"
import type { IntentReport, MediaSendIntents } from "./intents"
import type { MessageIdentity } from "./message-identity"
import { uploadKindFor } from "./media"
import { inputPeerForChat } from "./peers"

/** An attachment no send names is discarded this long after a restart finds it. */
export const UNSENT_ATTACHMENT_TTL_MS = 60 * 60 * 1000

const PHOTO_TYPES = new Set(["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"])

type StoredAttachment = { id: string; info: AttachmentInfo; createdAt: number }

type SendContext = Omit<SendMediaMessageContext, "media"> & {
  clientKey: string
  attachmentId: string
  info: AttachmentInfo
}

type SendState = { stage: "uploading" | "failed"; failure?: string }

type SendRecord = { id: string; tx?: string; context: SendContext; state: SendState }

export type AttachmentCoordinatorOptions = {
  db: Db
  auth: AuthStore
  realtime: RealtimeClient
  identity: MessageIdentity
  media: MediaCore
  store: ByteStore
  userId: UserID
  imagePreparer?: ImagePreparer
  now: () => number
  /** An attachment's info or upload state changed (resources and rows). */
  onChange: (attachmentId: string, messageKeys: readonly string[]) => void
  track: <T>(task: Promise<T>) => Promise<T>
  serialize: <T>(chain: string, task: () => Promise<T>) => Promise<T>
  log: Log
}

const result = (tx: TxId, status: IntentResult["status"], extra: Partial<IntentResult> = {}): IntentResult => ({
  tx,
  status,
  ...extra,
})

const rejection = (tx: TxId, error: unknown): IntentResult =>
  hasErrorNamed(error, "QuotaExceededError")
    ? result(tx, "rejected", { reason: "storageFull" })
    : result(tx, "rejected", { reason: "invalid" })

/** The `InputMedia` an upload's completion names. */
export const inputMediaFor = (complete: UploadComplete): InputMedia | undefined => {
  const media = complete.media
  switch (media.oneofKind) {
    case "photo":
      return { media: { oneofKind: "photo", photo: { photoId: media.photo.id } } }
    case "video":
      return { media: { oneofKind: "video", video: { videoId: media.video.id } } }
    case "document":
      return { media: { oneofKind: "document", document: { documentId: media.document.id } } }
    case "voice":
      return { media: { oneofKind: "voice", voice: { voiceId: media.voice.id } } }
    default:
      return undefined
  }
}

export class AttachmentCoordinator implements MediaSendIntents {
  private readonly attachments = new Map<string, StoredAttachment>()
  /** Sends by record ID, as committed. */
  private readonly sends = new Map<string, SendRecord>()
  /** The UI's transaction ID of each send, by random ID (`MessageRow.tx`). */
  private readonly txs = new Map<string, TxId>()
  /** `MessageRow.upload` by random ID; stable objects so rows memoize. */
  private readonly uploads = new Map<string, MessageUpload>()
  /** Running sends: record ID to its outcome. */
  private readonly running = new Map<string, Promise<"sent" | "failed" | "stopped">>()
  private stopped = false

  constructor(private readonly options: AttachmentCoordinatorOptions) {
    options.media.subscribe((event) => {
      if (event.type === "upload-state" || event.type === "upload-progress") {
        this.options.onChange(event.jobId, this.messageKeysFor(event.jobId))
      }
    })
  }

  private get root() {
    return `${this.options.media.root}attachments/`
  }

  // -------------------------------------------------------------------------
  // Start and stop

  /** After the replica and the media core are open: load, clean up, resume sends. */
  async resume() {
    const { store, media, now } = this.options
    for (const item of await store.list(this.root)) {
      const bytes = await store.read(item.path)
      if (!bytes) continue
      try {
        const stored = decodeRecord<StoredAttachment>(new TextDecoder().decode(bytes))
        if (isAttachmentId(stored.id)) this.attachments.set(stored.id, stored)
      } catch {
        await store.remove(item.path).catch(() => undefined)
      }
    }
    for (const record of hostRecords(this.options.db)) this.remember(record)
    const named = new Set(Array.from(this.sends.values(), (send) => send.context.attachmentId))
    for (const job of media.uploads.list()) {
      if (named.has(job.id)) continue
      // Sent before the restart (its record is gone) or never sent.
      if (job.state === "complete" || now() - job.createdAt > UNSENT_ATTACHMENT_TTL_MS || !this.attachments.has(job.id)) {
        await this.forget(job.id)
      }
    }
    for (const [id] of this.attachments) {
      if (!named.has(id) && !media.uploads.get(id)) await this.forget(id)
    }
    for (const send of this.sends.values()) {
      if (send.state.stage === "uploading") this.drive(send.id)
    }
  }

  stop() {
    this.stopped = true
  }

  // -------------------------------------------------------------------------
  // Queries

  attachment(attachmentId: string) {
    const stored = this.attachments.get(attachmentId)
    if (!stored) return undefined
    const job = this.options.media.uploads.get(attachmentId)
    return {
      info: stored.info,
      ...(job ? { job } : {}),
      source: async () => (job && job.state !== "canceled" ? await this.options.store.blob(job.sourcePath) : undefined),
    }
  }

  /** The UI's transaction ID of a media send still in flight, by client key (`MessageRow.tx`). */
  txFor(clientKey: string): TxId | undefined {
    return this.txs.get(clientKey)
  }

  localUpload(message: Message): MessageUpload | undefined {
    if (message.randomId == null || message.status === MessageSendingStatus.Sent) return undefined
    return this.uploads.get(message.randomId.toString())
  }

  // -------------------------------------------------------------------------
  // Intents

  async run(
    tx: TxId,
    intent: Extract<Intent, { kind: "attachFile" | "discardAttachment" | "sendMedia" }>,
    report: IntentReport,
    now: number,
  ): Promise<void> {
    switch (intent.kind) {
      case "attachFile":
        return await this.attach(tx, intent, report, now)
      case "discardAttachment":
        if (!isAttachmentId(intent.attachmentId)) {
          report(result(tx, "rejected", { reason: "invalid" }))
          return
        }
        if (Array.from(this.sends.values()).some((send) => send.context.attachmentId === intent.attachmentId)) {
          // A send owns it now; cancel the message instead.
          report(result(tx, "rejected", { reason: "invalid" }))
          return
        }
        await this.forget(intent.attachmentId)
        report(result(tx, "confirmed"))
        return
      case "sendMedia":
        return await this.send(tx, intent, report, now)
    }
  }

  private async attach(tx: TxId, intent: Extract<Intent, { kind: "attachFile" }>, report: IntentReport, now: number) {
    const file = intent.file as unknown
    const dimension = (value: unknown) =>
      value === undefined || (typeof value === "number" && Number.isFinite(value) && value > 0 && value <= 100_000)
    if (
      !isAttachmentId(intent.attachmentId) ||
      !(file instanceof Blob) ||
      file.size === 0 ||
      typeof intent.fileName !== "string" ||
      intent.fileName.length === 0 ||
      intent.fileName.length > 255 ||
      typeof intent.mimeType !== "string" ||
      intent.mimeType.length > 255 ||
      (intent.as !== undefined && !["photo", "video", "document", "voice"].includes(intent.as)) ||
      !dimension(intent.width) ||
      !dimension(intent.height) ||
      !dimension(intent.duration) ||
      (intent.preview !== undefined && !(intent.preview instanceof Uint8Array))
    ) {
      report(result(tx, "rejected", { reason: "invalid" }))
      return
    }
    if (this.attachments.has(intent.attachmentId)) {
      report(result(tx, "confirmed"))
      return
    }
    const mimeType = intent.mimeType || "application/octet-stream"
    let kind: AttachmentInfo["kind"] =
      intent.as ?? (PHOTO_TYPES.has(mimeType) ? "photo" : mimeType.startsWith("video/") ? "video" : "document")
    let source: Blob = file
    let uploadType = mimeType
    let width = intent.width
    let height = intent.height
    let preview: Uint8Array | undefined
    if (kind === "photo") {
      const prepared = await this.options.imagePreparer?.prepareImage(file, "photo").catch(() => undefined)
      if (prepared?.kind === "image") {
        source = prepared.blob
        uploadType = prepared.mimeType
        width = prepared.width
        height = prepared.height
        preview = prepared.tinyPreview
      } else if (prepared?.kind === "document" || (!this.options.imagePreparer && mimeType !== "image/jpeg" && mimeType !== "image/png")) {
        // The server takes JPEG and PNG photos only.
        kind = "document"
      }
    }
    // The UI's poster frame (a video's) when the core made none; an oversized one is ignored.
    if (!preview && intent.preview && intent.preview.length > 0 && intent.preview.length <= ATTACHMENT_PREVIEW_MAX_BYTES) {
      preview = intent.preview.slice()
    }
    const info: AttachmentInfo = {
      kind,
      fileName: intent.fileName,
      mimeType: uploadType,
      size: source.size,
      ...(width ? { width: Math.round(width) } : {}),
      ...(height ? { height: Math.round(height) } : {}),
      ...(intent.duration ? { duration: Math.round(intent.duration) } : {}),
      ...(preview ? { preview } : {}),
    }
    const stored: StoredAttachment = { id: intent.attachmentId, info, createdAt: now }
    try {
      await this.options.store.write(`${this.root}${stored.id}.json`, new TextEncoder().encode(encodeRecord(stored)))
      this.attachments.set(stored.id, stored)
      await this.options.media.startUpload({
        id: stored.id,
        source,
        fileName: info.fileName,
        mimeType: info.mimeType,
        kind: uploadKindFor(kind),
        // The server stores a video's size and length from these, so the
        // sent message keeps the size its sending row had.
        ...(kind === "video" && info.width && info.height
          ? {
              metadata: {
                kind: "video" as const,
                value: { width: info.width, height: info.height, duration: info.duration ?? 0, isAnimated: false },
              },
            }
          : kind === "voice" && info.duration
            ? { metadata: { kind: "voice" as const, value: { duration: info.duration, waveform: new Uint8Array() } } }
            : {}),
      })
    } catch (error) {
      this.attachments.delete(stored.id)
      await this.options.store.remove(`${this.root}${stored.id}.json`).catch(() => undefined)
      this.options.log.warn("attachment.stage.failed", { error })
      report(rejection(tx, error))
      return
    }
    this.options.onChange(stored.id, [])
    report(result(tx, "confirmed"))
  }

  private async send(tx: TxId, intent: Extract<Intent, { kind: "sendMedia" }>, report: IntentReport, now: number) {
    const { db, auth, userId } = this.options
    if (
      !isClientKey(intent.clientKey) ||
      !isAttachmentId(intent.attachmentId) ||
      (intent.text != null && (typeof intent.text !== "string" || intent.text.length > 4096)) ||
      (intent.entities != null && !isValidEntityList(intent.entities)) ||
      (intent.date != null && (!Number.isSafeInteger(intent.date) || intent.date < 0)) ||
      (intent.draftRevision != null && !Number.isSafeInteger(intent.draftRevision))
    ) {
      report(result(tx, "rejected", { reason: "invalid" }))
      return
    }
    const rows: RowKey[] = [rowKey("message", sentMessageRowId(intent.chatId, intent.clientKey))]
    const existing = this.recordFor(intent.chatId, intent.clientKey)
    if (existing) {
      // A retried command: follow the send that is already committed.
      report(result(tx, "accepted", { rows }))
      report(await this.outcome(tx, existing.id, rows))
      return
    }
    const stored = this.attachments.get(intent.attachmentId)
    if (!stored || Array.from(this.sends.values()).some((send) => send.context.attachmentId === intent.attachmentId)) {
      report(result(tx, "rejected", { reason: "invalid" }))
      return
    }
    const entities = entitiesToProtocol(intent.entities)
    const context: SendContext = {
      chatId: intent.chatId,
      peerId: inputPeerForChat(db, intent.chatId),
      clientKey: intent.clientKey,
      randomId: BigInt(intent.clientKey),
      temporaryMessageId: generateTempId(),
      temporarySendDate: intent.date ?? Math.floor(now / 1000),
      attachmentId: intent.attachmentId,
      info: stored.info,
      ...(intent.text ? { text: intent.text } : {}),
      ...(entities ? { entities } : {}),
      ...(intent.replyToMessageId ? { replyToMsgId: intent.replyToMessageId } : {}),
    }
    const record: SendRecord = { id: newHostRecordId("mediaSend", now), tx, context, state: { stage: "uploading" } }
    this.uploads.set(context.randomId.toString(), { attachmentId: context.attachmentId, attachment: context.info })
    this.txs.set(context.randomId.toString(), tx)
    try {
      await db.commit(() => {
        writeHostRecord(db, record.id, { kind: "mediaSend", tx, context, state: record.state }, now)
        this.insertOptimistic(db, context, auth.getState().currentUserId ?? userId)
        // The composer's draft goes with the send, in the same commit.
        if (intent.draftRevision != null) consumeDraft(db, intent.chatId, intent.draftRevision)
      })
    } catch (error) {
      this.uploads.delete(context.randomId.toString())
      this.txs.delete(context.randomId.toString())
      report(rejection(tx, error))
      return
    }
    this.sends.set(record.id, record)
    void this.options.track(
      db.promoteResidentMessageWindowToLatest(context.chatId).catch((error: unknown) => {
        this.options.log.warn("media.send.window.failed", { error })
      }),
    )
    if (intent.draftRevision != null) rows.push(rowKey("draft", intent.chatId))
    report(result(tx, "accepted", { rows }))
    this.drive(record.id)
    report(await this.outcome(tx, record.id, rows))
  }

  retry(tx: TxId, chatId: ChatID, clientKey: string, report: IntentReport): Promise<void> | undefined {
    const record = this.recordFor(chatId, clientKey)
    return record ? this.retryRecord(tx, record, report) : undefined
  }

  private async retryRecord(tx: TxId, record: SendRecord, report: IntentReport): Promise<void> {
    const { chatId, clientKey } = record.context
    const rows: RowKey[] = [rowKey("message", sentMessageRowId(chatId, clientKey))]
    if (record.state.stage === "failed") {
      const job = this.options.media.uploads.get(record.context.attachmentId)
      if (!job || job.state === "canceled") {
        report(result(tx, "rejected", { reason: "invalid" }))
        return
      }
      await this.options.media.retryUpload(record.context.attachmentId)
      try {
        await this.setStage(record, { stage: "uploading" }, MessageSendingStatus.Sending)
      } catch (error) {
        report(rejection(tx, error))
        return
      }
      this.drive(record.id)
    }
    report(result(tx, "accepted", { rows }))
    report(await this.outcome(tx, record.id, rows))
  }

  cancel(chatId: ChatID, clientKey: string): Promise<"cancelled" | MessageID | "unknown"> | undefined {
    const record = this.recordFor(chatId, clientKey)
    if (!record) return undefined
    return this.cancelRecord(record)
  }

  // -------------------------------------------------------------------------

  private async cancelRecord(record: SendRecord): Promise<"cancelled" | MessageID | "unknown"> {
    const running = this.running.get(record.id)
    const job = this.options.media.uploads.get(record.context.attachmentId)
    if (running && job?.state === "complete") {
      // The message may be on the wire: let it land, then delete it there.
      const outcome = await running
      const landed = this.options.identity.serverKeyFor(record.context.clientKey)
      if (outcome === "sent" && landed) return makeMessageId(landed.slice(landed.indexOf(":") + 1))
      if (outcome !== "failed") return "unknown"
    }
    await this.options.media.cancelUpload(record.context.attachmentId).catch(() => undefined)
    const { db } = this.options
    await db.commit(() => {
      deleteHostRecord(db, record.id)
      this.removeOptimistic(db, record.context)
    })
    this.sends.delete(record.id)
    this.uploads.delete(record.context.randomId.toString())
    this.txs.delete(record.context.randomId.toString())
    await this.forget(record.context.attachmentId)
    return "cancelled"
  }

  private recordFor(chatId: ChatID, clientKey: string): SendRecord | undefined {
    for (const send of this.sends.values()) {
      if (send.context.chatId === chatId && send.context.clientKey === clientKey) return send
    }
    return undefined
  }

  private remember(record: PendingTransaction) {
    const payload = hostRecordPayload(record)
    if (payload?.kind !== "mediaSend") return
    const context = payload.context as SendContext
    const send: SendRecord = {
      id: record.id,
      ...(payload.tx ? { tx: payload.tx } : {}),
      context,
      state: (payload.state as SendState | undefined) ?? { stage: "uploading" },
    }
    this.sends.set(send.id, send)
    this.uploads.set(context.randomId.toString(), { attachmentId: context.attachmentId, attachment: context.info })
    if (payload.tx) this.txs.set(context.randomId.toString(), payload.tx)
  }

  private messageKeysFor(attachmentId: string): string[] {
    for (const send of this.sends.values()) {
      if (send.context.attachmentId === attachmentId) {
        return [messageKey(send.context.chatId, send.context.temporaryMessageId)]
      }
    }
    return []
  }

  /** The intent's result once its send ends (or the core stops: none). */
  private async outcome(tx: TxId, recordId: string, rows: RowKey[]): Promise<IntentResult> {
    const running = this.running.get(recordId)
    if (!running) {
      const record = this.sends.get(recordId)
      return record?.state.stage === "failed"
        ? result(tx, "rejected", { reason: "server", rows })
        : result(tx, "confirmed", { rows })
    }
    const outcome = await running
    if (outcome === "sent") return result(tx, "confirmed", { rows })
    if (outcome === "failed") return result(tx, "rejected", { reason: "server", rows })
    return result(tx, "uncertain", { rows })
  }

  /** Upload, then send, once; in acceptance order per chat. */
  private drive(recordId: string) {
    if (this.running.has(recordId)) return
    const record = this.sends.get(recordId)
    if (!record) return
    const task = this.options.serialize(`media-send:${record.context.chatId}`, () => this.deliver(record))
    const settled = task.catch((error: unknown): "stopped" => {
      this.options.log.warn("media.send.failed", { error })
      return "stopped"
    })
    this.running.set(recordId, settled)
    void this.options.track(settled.finally(() => this.running.delete(recordId)))
  }

  private async deliver(record: SendRecord): Promise<"sent" | "failed" | "stopped"> {
    const { media, realtime } = this.options
    if (this.stopped || !this.sends.has(record.id)) return "stopped"
    let complete: UploadComplete
    try {
      complete = await media.uploadCompletion(record.context.attachmentId)
    } catch (error) {
      const code = (error as { code?: string } | undefined)?.code
      if (this.stopped || code === "closed") return "stopped"
      if (code === "canceled") return "stopped"
      await this.setStage(record, { stage: "failed", failure: code ?? "upload" }, MessageSendingStatus.Failed).catch(
        () => undefined,
      )
      return "failed"
    }
    const input = inputMediaFor(complete)
    if (!input) {
      await this.setStage(record, { stage: "failed", failure: "media" }, MessageSendingStatus.Failed).catch(() => undefined)
      return "failed"
    }
    if (this.stopped) return "stopped"
    const { clientKey, attachmentId, info: _info, ...context } = record.context
    const transaction = sendMediaMessage({ ...context, media: input })
    try {
      await realtime.execute(
        hostSend(transaction, record.id, {
          afterApply: (rpcResult) => {
            if (rpcResult?.oneofKind !== "sendMessage") return
            for (const update of rpcResult.sendMessage.updates) {
              if (
                update.update.oneofKind === "updateMessageId" &&
                update.update.updateMessageId.randomId === record.context.randomId
              ) {
                this.options.identity.register(
                  messageKey(record.context.chatId, makeMessageId(update.update.updateMessageId.messageId)),
                  clientKey,
                )
              }
            }
          },
        }),
      )
    } catch (error) {
      const kind = error instanceof TransactionFailure ? error.kind : "ambiguous-result"
      if (kind === "rpc-error" || kind === "invalid") {
        // The record is gone with the failure; keep it failed for a retry.
        await this.setStage(record, { stage: "failed", failure: "server" }, MessageSendingStatus.Failed).catch(
          () => undefined,
        )
        return "failed"
      }
      return "stopped"
    }
    // Sent: the record went with the result. Keep the bytes as the server's file, then let the upload go.
    this.sends.delete(record.id)
    this.uploads.delete(record.context.randomId.toString())
    this.txs.delete(record.context.randomId.toString())
    await this.keepSentBytes(attachmentId, complete).catch(() => undefined)
    await this.forget(attachmentId)
    return "sent"
  }

  /** The bytes just sent, cached under the server's file, so the sent row shows without a download. */
  private async keepSentBytes(attachmentId: string, complete: UploadComplete) {
    const job = this.options.media.uploads.get(attachmentId)
    const blob = job ? await this.options.store.blob(job.sourcePath) : undefined
    if (!blob) return
    const media = complete.media
    if (media.oneofKind === "photo") {
      const sizes = media.photo.sizes.filter((size) => size.type !== "s")
      const largest = sizes.reduce<(typeof sizes)[number] | undefined>(
        (best, size) => (!best || size.w * size.h > best.w * best.h ? size : best),
        undefined,
      )
      const fileUniqueId = largest?.fileUniqueId || media.photo.fileUniqueId
      if (largest && fileUniqueId) await this.options.media.cache.put({ fileUniqueId, variant: largest.type }, blob)
      return
    }
    if (complete.fileUniqueId) await this.options.media.cache.put({ fileUniqueId: complete.fileUniqueId, variant: "file" }, blob)
  }

  private async setStage(record: SendRecord, state: SendState, status: MessageSendingStatus) {
    const { db } = this.options
    await db.commit(() => {
      writeHostRecord(
        db,
        record.id,
        { kind: "mediaSend", ...(record.tx ? { tx: record.tx } : {}), context: record.context, state },
        db.get(db.ref(DbObjectKind.PendingTransaction, record.id))?.createdAt ?? this.options.now(),
      )
      const ref = db.ref(DbObjectKind.Message, messageKey(record.context.chatId, record.context.temporaryMessageId))
      const message = db.get(ref)
      if (message) db.update({ ...message, status })
    })
    record.state = state
    this.sends.set(record.id, record)
  }

  private insertOptimistic(db: Db, context: SendContext, fromId: UserID) {
    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(context.chatId, context.temporaryMessageId),
      messageId: context.temporaryMessageId,
      randomId: context.randomId,
      fromId,
      chatId: context.chatId,
      ...(context.text ? { message: context.text } : {}),
      out: true,
      date: context.temporarySendDate,
      ...(context.replyToMsgId ? { replyToMsgId: context.replyToMsgId } : {}),
      ...(context.entities ? { entities: context.entities } : {}),
      status: MessageSendingStatus.Sending,
    })
    const chat = db.get(db.ref(DbObjectKind.Chat, context.chatId))
    if (chat) db.update({ ...chat, lastMsgId: context.temporaryMessageId, date: context.temporarySendDate })
  }

  private removeOptimistic(db: Db, context: SendContext) {
    db.delete(db.ref(DbObjectKind.Message, messageKey(context.chatId, context.temporaryMessageId)))
    const chat = db.get(db.ref(DbObjectKind.Chat, context.chatId))
    if (chat?.lastMsgId !== context.temporaryMessageId) return
    const previous = db
      .queryCollection<DbObjectKind.Message, Message, DbQueryPlanType.Objects>(
        DbQueryPlanType.Objects,
        DbObjectKind.Message,
        (message) => message.chatId === context.chatId && message.messageId !== context.temporaryMessageId,
      )
      .sort((left, right) => (left.date ?? 0) - (right.date ?? 0))
      .at(-1)
    db.update({ ...chat, lastMsgId: previous?.messageId, date: previous?.date })
  }

  /** Forget an attachment: its upload (cancelled if unfinished), its bytes and its info. */
  private async forget(attachmentId: string) {
    this.attachments.delete(attachmentId)
    await this.options.media.releaseUpload(attachmentId).catch(() => undefined)
    await this.options.store.remove(`${this.root}${attachmentId}.json`).catch(() => undefined)
    this.options.onChange(attachmentId, [])
  }
}
