import {
  Photo_Format,
  RpcError_Code,
  UploadKind,
  UploadStatus,
  type CreateUploadInput,
  type CreateUploadResult,
  type FinishUploadResult,
  type GetFilePartInput,
  type GetFilePartResult,
  type GetUploadStateResult,
  type MessageMedia,
  type UploadComplete,
} from "@inline-chat/protocol/core"
import { bytesEqual, sha256, toHex } from "../media/bytes"
import { demoNoise, demoPng, demoText, demoWav, demoWaveform, imageDimensions } from "./demo-bytes"
import { demoThumbnail } from "./demo-content"

/**
 * The demo server's files: transfers as the server's upload state machine
 * runs them (`server/src/modules/uploads/operations.ts`, after the media
 * package's `TransferServer`, but synchronous, so the server model answers
 * in one call), and `GET_FILE_PART` for every file a demo message names.
 *
 * - Seeded files are made on demand from their file ID (`demoFileIds`), and
 *   the last few are kept; nothing is made up front.
 * - Uploaded files are kept in memory for the life of the world (a reload
 *   forgets their bytes; the client already holds what it sent).
 * - Faults on a control: latency is applied by the world to transfer
 *   results; `processingRounds` makes a finish answer `processing` first;
 *   `failNext` makes the next finishes fail (retryable); `inlineData` off
 *   makes a single-part file go through `SAVE_UPLOAD_PART`, so even a small
 *   photo shows progress.
 */

const PART_SIZE = 512 * 1024
const MAX_PARTS = 1_000
const IDLE_TTL_SECONDS = 24 * 60 * 60

export type DemoTransferSettings = {
  processingRounds: number
  failNext: number
  inlineData: boolean
}

type Upload = {
  uploadId: Uint8Array
  clientUploadId: Uint8Array
  input: CreateUploadInput
  byteCount: number
  partCount: number
  parts: Map<number, Uint8Array>
  status: "uploading" | "processing" | "complete" | "failed" | "canceled"
  expiresAt: number
  processingRounds: number
  complete?: UploadComplete
  failure?: { code: number; retryable: boolean }
}

export class DemoTransferError extends Error {
  constructor(
    readonly code: RpcError_Code,
    message: string,
  ) {
    super(message)
    this.name = "DemoTransferError"
  }
}

const bad = (message: string) => new DemoTransferError(RpcError_Code.BAD_REQUEST, message)

const GENERATED_KEEP = 8

export class DemoTransfers {
  readonly settings: DemoTransferSettings = { processingRounds: 0, failNext: 0, inlineData: false }
  /** Files finalized in this world, by file ID. */
  readonly uploaded = new Map<string, { bytes: Uint8Array; mimeType: string; media: MessageMedia }>()
  /** Media of finalized uploads, by the media ID a send names. */
  private readonly mediaById = new Map<string, MessageMedia>()
  private readonly uploads = new Map<string, Upload>()
  private readonly generated = new Map<string, Uint8Array>()
  private nextUpload = 1
  private nextMediaId: bigint
  /** Parts served by `GET_FILE_PART`, for tests and status. */
  partsServed = 0
  completed = 0

  constructor(
    private readonly now: () => number,
    options: { mediaIdBase?: bigint } = {},
  ) {
    this.nextMediaId = options.mediaIdBase ?? 7_000_000_000n
  }

  // ---- Uploads -----------------------------------------------------------------

  create(input: CreateUploadInput): CreateUploadResult {
    const byteCount = Number(input.byteCount)
    const partCount = Math.ceil(byteCount / PART_SIZE)
    if (
      input.clientUploadId.length !== 16 ||
      input.sha256.length !== 32 ||
      byteCount <= 0 ||
      partCount > MAX_PARTS ||
      !input.fileName.trim() ||
      input.kind === UploadKind.UNSPECIFIED
    ) {
      throw bad("upload")
    }
    if (input.kind === UploadKind.PHOTO && input.mimeType !== "image/jpeg" && input.mimeType !== "image/png") {
      throw bad("photos are JPEG or PNG")
    }
    let upload = Array.from(this.uploads.values()).find((candidate) =>
      bytesEqual(candidate.clientUploadId, input.clientUploadId),
    )
    if (
      upload &&
      (upload.input.fileName !== input.fileName ||
        upload.input.byteCount !== input.byteCount ||
        !bytesEqual(upload.input.sha256, input.sha256))
    ) {
      throw bad("metadata conflict")
    }
    if (!upload) {
      const id = this.nextUpload++
      const uploadId = new Uint8Array(16)
      new DataView(uploadId.buffer).setUint32(12, id)
      upload = {
        uploadId,
        clientUploadId: input.clientUploadId.slice(),
        input: { ...input, inlineData: undefined },
        byteCount,
        partCount,
        parts: new Map(),
        status: "uploading",
        expiresAt: this.seconds() + IDLE_TTL_SECONDS,
        processingRounds: this.settings.processingRounds,
      }
      this.uploads.set(toHex(uploadId), upload)
    }
    const result: CreateUploadResult = {
      uploadId: upload.uploadId.slice(),
      partSize: PART_SIZE,
      partCount: upload.partCount,
      expiresAt: BigInt(upload.expiresAt),
      acceptedParts: this.accepted(upload),
    }
    if (input.inlineData === undefined || !this.settings.inlineData || upload.partCount !== 1) return result
    if (!upload.parts.has(0)) this.savePart(upload.uploadId, 0, input.inlineData)
    const finished = this.finish(upload.uploadId)
    return finished.state.oneofKind === "complete"
      ? { ...result, acceptedParts: [0], complete: finished.state.complete }
      : { ...result, acceptedParts: [0] }
  }

  savePart(uploadId: Uint8Array, partIndex: number, data: Uint8Array): { alreadyPresent: boolean } {
    const upload = this.upload(uploadId)
    if (upload.status === "processing" || upload.status === "complete") {
      if (upload.parts.has(partIndex)) return { alreadyPresent: true }
      throw bad("upload is finishing")
    }
    if (upload.status !== "uploading" || this.expired(upload)) throw bad("upload is not accepting parts")
    const expected = Math.min(PART_SIZE, upload.byteCount - partIndex * PART_SIZE)
    if (!Number.isInteger(partIndex) || partIndex < 0 || partIndex >= upload.partCount || data.length !== expected) {
      throw bad("part")
    }
    const existing = upload.parts.get(partIndex)
    if (existing) {
      if (!bytesEqual(existing, data)) throw bad("part conflict")
      return { alreadyPresent: true }
    }
    upload.parts.set(partIndex, data.slice())
    upload.expiresAt = this.seconds() + IDLE_TTL_SECONDS
    return { alreadyPresent: false }
  }

  state(uploadId: Uint8Array): GetUploadStateResult {
    const upload = this.upload(uploadId)
    const acceptedParts = this.accepted(upload)
    if (upload.status === "uploading" && this.expired(upload)) return { status: UploadStatus.EXPIRED, acceptedParts }
    switch (upload.status) {
      case "uploading":
        return { status: UploadStatus.UPLOADING, acceptedParts }
      case "processing":
        return { status: UploadStatus.PROCESSING, acceptedParts }
      case "canceled":
        return { status: UploadStatus.CANCELED, acceptedParts }
      case "failed":
        return { status: UploadStatus.FAILED, acceptedParts, ...(upload.failure ? { failure: upload.failure } : {}) }
      case "complete":
        return { status: UploadStatus.COMPLETE, acceptedParts, ...(upload.complete ? { complete: upload.complete } : {}) }
    }
  }

  finish(uploadId: Uint8Array): FinishUploadResult {
    const upload = this.upload(uploadId)
    if (upload.status === "complete") return { state: { oneofKind: "complete", complete: upload.complete! } }
    if (upload.status === "failed") return { state: { oneofKind: "failed", failed: upload.failure! } }
    if (upload.status === "canceled" || (upload.status === "uploading" && this.expired(upload))) throw bad("rejected")
    if (upload.status === "uploading") {
      const missing: number[] = []
      for (let index = 0; index < upload.partCount; index += 1) if (!upload.parts.has(index)) missing.push(index)
      if (missing.length > 0) return { state: { oneofKind: "missing", missing: { partIndices: missing } } }
      upload.status = "processing"
    }
    if (upload.processingRounds > 0) {
      upload.processingRounds -= 1
      return { state: { oneofKind: "processing", processing: { retryAfterSeconds: 1 } } }
    }
    if (this.settings.failNext > 0) {
      this.settings.failNext -= 1
      upload.status = "failed"
      upload.failure = { code: 3, retryable: true }
      return { state: { oneofKind: "failed", failed: upload.failure } }
    }
    const body = new Uint8Array(upload.byteCount)
    for (const [index, part] of upload.parts) body.set(part, index * PART_SIZE)
    if (!bytesEqual(sha256(body), upload.input.sha256)) {
      upload.status = "failed"
      upload.failure = { code: 1, retryable: false }
      return { state: { oneofKind: "failed", failed: upload.failure } }
    }
    const fileUniqueId = `du_${toHex(upload.uploadId).slice(24)}_${toHex(upload.input.sha256).slice(0, 12)}`
    const media = this.mediaFor(upload.input, body, fileUniqueId)
    this.uploaded.set(fileUniqueId, { bytes: body, mimeType: upload.input.mimeType, media })
    upload.parts.clear()
    upload.status = "complete"
    upload.complete = { fileUniqueId, media: completeMedia(media) }
    this.completed += 1
    return { state: { oneofKind: "complete", complete: upload.complete } }
  }

  cancel(uploadId: Uint8Array): { canceled: boolean; alreadyTerminal: boolean } {
    const upload = this.upload(uploadId)
    if (upload.status === "uploading" || upload.status === "processing") {
      upload.status = "canceled"
      upload.parts.clear()
      return { canceled: true, alreadyTerminal: false }
    }
    return { canceled: false, alreadyTerminal: true }
  }

  /** The media a send names (`InputMedia` photo, video, document or voice ID). */
  media(kind: "photo" | "video" | "document" | "voice", id: bigint): MessageMedia | undefined {
    return this.mediaById.get(`${kind}:${id}`)
  }

  private mediaFor(input: CreateUploadInput, body: Uint8Array, fileUniqueId: string): MessageMedia {
    const id = this.nextMediaId++
    const date = BigInt(this.seconds())
    const size = body.length
    let media: MessageMedia
    switch (input.kind) {
      case UploadKind.PHOTO: {
        const dimensions = imageDimensions(body) ?? { width: 1, height: 1 }
        media = {
          media: {
            oneofKind: "photo",
            photo: {
              photo: {
                id,
                date,
                format: input.mimeType === "image/png" ? Photo_Format.PNG : Photo_Format.JPEG,
                fileUniqueId,
                sizes: [{ type: "f", w: dimensions.width, h: dimensions.height, size, fileUniqueId }],
              },
            },
          },
        }
        break
      }
      case UploadKind.VIDEO: {
        const metadata = input.metadata.oneofKind === "video" ? input.metadata.video : undefined
        const uploadedThumbnail =
          input.thumbnailFileUniqueId != null
            ? this.uploaded.get(input.thumbnailFileUniqueId)?.media.media
            : undefined
        // No poster uploaded: the server's would come from the video; the demo draws one.
        const poster =
          uploadedThumbnail?.oneofKind === "photo" && uploadedThumbnail.photo.photo
            ? uploadedThumbnail.photo.photo
            : demoThumbnail(this.nextMediaId++, date, Number(id % 0xffff_ffffn), metadata?.width ?? 16, metadata?.height ?? 9)
        media = {
          media: {
            oneofKind: "video",
            video: {
              video: {
                id,
                date,
                w: metadata?.width ?? 0,
                h: metadata?.height ?? 0,
                duration: metadata?.duration ?? 0,
                size,
                fileUniqueId,
                photo: poster,
                ...(metadata?.isAnimated ? { isAnimated: true } : {}),
                ...(metadata?.hasAudio != null ? { hasAudio: metadata.hasAudio } : {}),
              },
            },
          },
        }
        break
      }
      case UploadKind.VOICE: {
        const metadata = input.metadata.oneofKind === "voice" ? input.metadata.voice : undefined
        media = {
          media: {
            oneofKind: "voice",
            voice: {
              voice: {
                id,
                date,
                duration: metadata?.duration ?? 0,
                size,
                mimeType: input.mimeType,
                // The server computes a waveform when the client sends none.
                waveform: metadata?.waveform && metadata.waveform.length > 0 ? metadata.waveform : demoWaveform(Number(id % 0xffff_ffffn)),
                fileUniqueId,
              },
            },
          },
        }
        break
      }
      default:
        media = {
          media: {
            oneofKind: "document",
            document: {
              document: { id, date, fileName: input.fileName, mimeType: input.mimeType, size, fileUniqueId },
            },
          },
        }
    }
    const kind = media.media.oneofKind
    if (kind) this.mediaById.set(`${kind}:${id}`, media)
    return media
  }

  // ---- Files -------------------------------------------------------------------

  getPart(input: GetFilePartInput): GetFilePartResult {
    const bytes = this.file(input.fileUniqueId)
    if (!bytes) throw new DemoTransferError(RpcError_Code.BAD_REQUEST, "unknown file")
    const total = bytes.length
    const offset = Number(input.offset)
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > total || input.limit < 1 || input.limit > PART_SIZE) {
      throw bad("range")
    }
    const data = bytes.slice(offset, Math.min(total, offset + input.limit))
    this.partsServed += 1
    return { offset: input.offset, totalSize: BigInt(total), data, sha256: sha256(data) }
  }

  /** The bytes of a file a demo message names, or undefined. */
  file(fileUniqueId: string): Uint8Array | undefined {
    const uploaded = this.uploaded.get(fileUniqueId)
    if (uploaded) return uploaded.bytes
    const cached = this.generated.get(fileUniqueId)
    if (cached) {
      this.generated.delete(fileUniqueId)
      this.generated.set(fileUniqueId, cached)
      return cached
    }
    const made = generateFile(fileUniqueId)
    if (!made) return undefined
    this.generated.set(fileUniqueId, made)
    while (this.generated.size > GENERATED_KEEP) this.generated.delete(this.generated.keys().next().value!)
    return made
  }

  private upload(uploadId: Uint8Array): Upload {
    const upload = this.uploads.get(toHex(uploadId))
    if (!upload) throw bad("unknown upload")
    return upload
  }

  private accepted(upload: Upload) {
    return Array.from(upload.parts.keys()).sort((left, right) => left - right)
  }

  private expired(upload: Upload) {
    return upload.expiresAt <= this.seconds()
  }

  private seconds() {
    return Math.floor(this.now() / 1_000)
  }
}

/** `UploadComplete` names the media itself; a message wraps it (`MessagePhoto`, …). */
const completeMedia = (media: MessageMedia): UploadComplete["media"] => {
  const value = media.media
  switch (value.oneofKind) {
    case "photo":
      return value.photo.photo ? { oneofKind: "photo", photo: value.photo.photo } : { oneofKind: undefined }
    case "video":
      return value.video.video ? { oneofKind: "video", video: value.video.video } : { oneofKind: undefined }
    case "document":
      return value.document.document ? { oneofKind: "document", document: value.document.document } : { oneofKind: undefined }
    case "voice":
      return value.voice.voice ? { oneofKind: "voice", voice: value.voice.voice } : { oneofKind: undefined }
    default:
      return { oneofKind: undefined }
  }
}

/** Make a seeded file from its ID (`demoFileIds`), or undefined for any other ID. */
export const generateFile = (fileUniqueId: string): Uint8Array | undefined => {
  let match = /^dp_(\d+)_(\d+)x(\d+)$/.exec(fileUniqueId)
  if (match) return demoPng(Number(match[1]), Number(match[2]), Number(match[3]))
  match = /^dv_(\d+)_(\d+)$/.exec(fileUniqueId)
  if (match) return demoNoise(Number(match[1]), 0, Number(match[2]))
  match = /^dd_(\d+)_(\d+)_([ct])$/.exec(fileUniqueId)
  if (match) return demoText(Number(match[1]), Number(match[2]), match[3] === "c")
  match = /^da_(\d+)_(\d+)$/.exec(fileUniqueId)
  if (match) return demoWav(Number(match[1]), Number(match[2]))
  return undefined
}
