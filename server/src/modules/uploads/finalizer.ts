import { createHash } from "node:crypto"
import { mkdtemp, open, rmdir, unlink, type FileHandle } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { UploadComplete } from "@inline-chat/protocol/core"
import { getR2 } from "@in/server/libs/r2"
import { FileModel } from "@in/server/db/models/files"
import {
  inlineUploadFileUniqueId,
  inlineUploadPublicationPath,
  type InlineUploadPublication,
  type InlineUploadPartRecord,
  type InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import { encrypt, encryptBinary } from "@in/server/modules/encryption/encryption"
import { prepareFileObjectRecord, uploadFileObject } from "@in/server/modules/files/uploadAFile"
import {
  getDocumentMetadataAndValidate,
  getPhotoMetadataAndValidate,
  getVideoMetadataAndValidate,
  getVoiceMetadataAndValidate,
} from "@in/server/modules/files/metadata"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"
import { generateStrippedThumbnail } from "@in/server/modules/files/strippedThumbnail"
import { FileTypes } from "@in/server/modules/files/types"
import { FileByteLengthError } from "@in/server/modules/files/readFileBytes"
import { encodeDocument } from "@in/server/realtime/encoders/encodeDocument"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { encodeVideo } from "@in/server/realtime/encoders/encodeVideo"
import { encodeVoice } from "@in/server/realtime/encoders/encodeVoice"
import { Log } from "@in/server/utils/log"
import type { UploadPartStore } from "./partStore"

const log = new Log("modules/uploads/finalizer")
const PART_READ_CONCURRENCY = 4

// Keep a rolling, ordered window instead of waiting for an entire batch's
// slowest read before scheduling more work. All failures are observed and
// outstanding storage reads remain owned until they settle.
async function* readParts(
  store: UploadPartStore,
  parts: InlineUploadPartRecord[],
  signal?: AbortSignal,
) {
  type ReadResult = { bytes: Uint8Array; error?: never } | { error: unknown; bytes?: never }
  const pending: Promise<ReadResult>[] = []
  let next = 0
  const fill = () => {
    while (pending.length < PART_READ_CONCURRENCY && next < parts.length) {
      throwIfAborted(signal)
      const part = parts[next++]!
      pending.push(store.read(part.objectKey, part.byteCount, signal).then(
        (bytes) => ({ bytes }), (error: unknown) => ({ error }),
      ))
    }
  }
  try {
    fill()
    for (const part of parts) {
      throwIfAborted(signal)
      const result = await pending.shift()!
      throwIfAborted(signal)
      if ("error" in result) {
        if (result.error instanceof FileByteLengthError) throw new UploadIntegrityError()
        throw result.error
      }
      yield { part, bytes: result.bytes }
      fill()
    }
  } finally {
    await Promise.all(pending)
  }
}

export interface MediaUploadFinalizer {
  preparePublication(input: {
    upload: InlineUploadRecord
    parts: InlineUploadPartRecord[]
    thumbnailPhotoId?: number
    assertOwnership: () => Promise<void>
    signal?: AbortSignal
  }): Promise<InlineUploadPublication>
  prepareStoredPublication(input: {
    upload: InlineUploadRecord
    stream: ReadableStream<Uint8Array>
    thumbnailPhotoId?: number
    assertOwnership: () => Promise<void>
    signal?: AbortSignal
  }): Promise<InlineUploadPublication>
  discardPublication(upload: InlineUploadRecord): Promise<void>
  project(
    kind: InlineUploadRecord["kind"],
    fileUniqueId: string,
    mediaId: number,
  ): Promise<UploadComplete>
}

const sameBytes = (left: Uint8Array, right: Uint8Array): boolean =>
  Buffer.from(left).equals(Buffer.from(right))

const readWithSignal = async <T>(
  reader: ReadableStreamDefaultReader<T>,
  signal?: AbortSignal,
) => {
  throwIfAborted(signal)
  if (!signal) return reader.read()
  let rejectAborted!: (reason?: unknown) => void
  let didAbort = false
  const aborted = new Promise<never>((_, reject) => { rejectAborted = reject })
  const onAbort = () => {
    if (didAbort) return
    didAbort = true
    const reason = signal.reason ?? new DOMException("The operation was aborted", "AbortError")
    rejectAborted(reason)
    void reader.cancel(reason).catch(() => {})
  }
  signal.addEventListener("abort", onAbort, { once: true })
  if (signal.aborted) onAbort()
  try {
    return await Promise.race([reader.read(), aborted])
  } finally {
    signal.removeEventListener("abort", onAbort)
  }
}

export class UploadMediaFinalizer implements MediaUploadFinalizer {
  constructor(
    private readonly partStore: UploadPartStore,
    private readonly removePublication: (key: string) => Promise<void> = async (key) => {
      const r2 = getR2()
      if (!r2) throw new Error("R2 is not initialized")
      await r2.file(key).delete()
    },
  ) {}

  async preparePublication(input: {
    upload: InlineUploadRecord
    parts: InlineUploadPartRecord[]
    thumbnailPhotoId?: number
    assertOwnership: () => Promise<void>
    signal?: AbortSignal
  }): Promise<InlineUploadPublication> {
    throwIfAborted(input.signal)
    const startedAt = Date.now()
    const directory = await mkdtemp(join(tmpdir(), "inline-native-upload-"))
    const path = join(directory, "body")
    let handle: FileHandle | undefined
    const digest = createHash("sha256")
    let byteCount = 0n
    let assemblyMs = 0
    let syncMs = 0
    let mediaMs = 0
    let outcome = "failed"
    const assemblyStartedAt = Date.now()
    try {
      handle = await open(path, "wx")
      await input.assertOwnership()
      for await (const { part, bytes } of readParts(this.partStore, input.parts, input.signal)) {
        const partDigest = createHash("sha256").update(bytes).digest()
        if (bytes.length !== part.byteCount || !sameBytes(partDigest, part.sha256)) {
          throw new UploadIntegrityError()
        }
        let written = 0
        while (written < bytes.length) {
          throwIfAborted(input.signal)
          const result = await handle.write(bytes, written, bytes.length - written)
          if (result.bytesWritten <= 0) throw new Error("Upload assembly write made no progress")
          written += result.bytesWritten
        }
        digest.update(bytes)
        byteCount += BigInt(bytes.length)
      }
      throwIfAborted(input.signal)
      assemblyMs = Date.now() - assemblyStartedAt
      const syncStartedAt = Date.now()
      await handle.sync()
      if (BigInt((await handle.stat()).size) !== input.upload.byteCount) throw new UploadIntegrityError()
      await handle.close()
      syncMs = Date.now() - syncStartedAt
      if (byteCount !== input.upload.byteCount ||
          !sameBytes(digest.digest(), input.upload.sha256)) {
        throw new UploadIntegrityError()
      }

      const file = new File([Bun.file(path)], input.upload.fileName, { type: input.upload.mimeType })
      await input.assertOwnership()
      const mediaStartedAt = Date.now()
      const publication = await this.#preparePublication(file, input.upload, input.thumbnailPhotoId, input.signal)
      mediaMs = Date.now() - mediaStartedAt
      // The object write is outside PostgreSQL. Rechecking after it prevents a
      // stale lease holder from entering the canonical media transaction.
      await input.assertOwnership()
      outcome = "prepared"
      return publication
    } finally {
      if (assemblyMs === 0) assemblyMs = Date.now() - assemblyStartedAt
      const cleanupStartedAt = Date.now()
      await handle?.close().catch(() => {})
      await unlink(path).catch(() => {})
      await rmdir(directory).catch(() => {})
      log.debug("UPLOAD_TRACE phase=finalizer_done", {
        outcome,
        kind: input.upload.kind,
        partCount: input.parts.length,
        byteCount: byteCount.toString(),
        assemblyMs,
        syncMs,
        mediaMs,
        cleanupMs: Date.now() - cleanupStartedAt,
        elapsedMs: Date.now() - startedAt,
      })
    }
  }

  async prepareStoredPublication(input: {
    upload: InlineUploadRecord
    stream: ReadableStream<Uint8Array>
    thumbnailPhotoId?: number
    assertOwnership: () => Promise<void>
    signal?: AbortSignal
  }): Promise<InlineUploadPublication> {
    throwIfAborted(input.signal)
    const directory = await mkdtemp(join(tmpdir(), "inline-native-upload-stored-"))
    const path = join(directory, "body")
    let handle: FileHandle | undefined
    const reader = input.stream.getReader()
    const digest = createHash("sha256")
    let byteCount = 0n
    try {
      handle = await open(path, "wx")
      await input.assertOwnership()
      while (true) {
        throwIfAborted(input.signal)
        const result = await readWithSignal(reader, input.signal)
        if (result.done) break
        const bytes = result.value
        digest.update(bytes)
        byteCount += BigInt(bytes.byteLength)
        if (byteCount > input.upload.byteCount) throw new UploadIntegrityError()
        let written = 0
        while (written < bytes.byteLength) {
          const result = await handle.write(bytes, written, bytes.byteLength - written)
          if (result.bytesWritten <= 0) throw new Error("Stored upload write made no progress")
          written += result.bytesWritten
        }
      }
      await handle.sync()
      await handle.close()
      handle = undefined
      if (byteCount !== input.upload.byteCount ||
          !sameBytes(digest.digest(), input.upload.sha256)) throw new UploadIntegrityError()
      const file = new File([Bun.file(path)], input.upload.fileName, { type: input.upload.mimeType })
      const publication = await this.#preparePublication(
        file,
        input.upload,
        input.thumbnailPhotoId,
        input.signal,
        true,
      )
      await input.assertOwnership()
      return publication
    } finally {
      await reader.cancel().catch(() => {})
      reader.releaseLock()
      await handle?.close().catch(() => {})
      await unlink(path).catch(() => {})
      await rmdir(directory).catch(() => {})
    }
  }

  async project(kind: InlineUploadRecord["kind"], fileUniqueId: string, mediaId: number): Promise<UploadComplete> {
    switch (kind) {
      case "photo": {
        const photo = await FileModel.getPhotoById(BigInt(mediaId))
        if (!photo) throw new Error("Completed upload photo is missing")
        return { fileUniqueId, media: { oneofKind: "photo", photo: encodePhoto({ photo }) } }
      }
      case "video": {
        const video = await FileModel.getVideoById(BigInt(mediaId))
        if (!video) throw new Error("Completed upload video is missing")
        return { fileUniqueId, media: { oneofKind: "video", video: encodeVideo({ video }) } }
      }
      case "document": {
        const document = await FileModel.getDocumentById(BigInt(mediaId))
        if (!document) throw new Error("Completed upload document is missing")
        return { fileUniqueId, media: { oneofKind: "document", document: encodeDocument({ document }) } }
      }
      case "voice": {
        const voice = await FileModel.getVoiceById(BigInt(mediaId))
        if (!voice) throw new Error("Completed upload voice is missing")
        const encoded = encodeVoice({ voice })
        if (!encoded) throw new Error("Completed upload voice has invalid metadata")
        return { fileUniqueId, media: { oneofKind: "voice", voice: encoded } }
      }
      default:
        throw new Error("Completed upload kind is invalid")
    }
  }

  async discardPublication(upload: InlineUploadRecord): Promise<void> {
    const fileUniqueId = upload.resultFileUniqueId
    if (!fileUniqueId) return
    await this.removePublication(`${FILES_PATH_PREFIX}/${inlineUploadPublicationPath(fileUniqueId)}`)
  }

  async #preparePublication(
    file: File,
    upload: InlineUploadRecord,
    thumbnailPhotoId?: number,
    signal?: AbortSignal,
    alreadyStored = false,
  ): Promise<InlineUploadPublication> {
    switch (upload.kind) {
      case "photo": {
        const metadata = await getPhotoMetadataAndValidate(file)
        if (metadata.mimeType !== "image/jpeg" && metadata.mimeType !== "image/png") {
          throw new UploadInvalidMediaError()
        }
        const stripped = await generateStrippedThumbnail(file).catch((error) => {
          log.warn("Failed to generate stripped thumbnail for native upload", {
            error,
            userId: upload.userId,
          })
          return null
        })
        const encryptedStripped = stripped ? encryptBinary(stripped.bytes) : null
        return {
          file: await this.#prepareFileObject(file, FileTypes.PHOTO, metadata, upload, signal, alreadyStored),
          media: {
            kind: "photo",
            format: metadata.mimeType === "image/jpeg" ? "jpeg" : "png",
            width: metadata.width,
            height: metadata.height,
            stripped: encryptedStripped?.encrypted ?? null,
            strippedIv: encryptedStripped?.iv ?? null,
            strippedTag: encryptedStripped?.authTag ?? null,
          },
        }
      }
      case "video": {
        const metadata = await getVideoMetadataAndValidate(
          file,
          upload.videoWidth ?? 1280,
          upload.videoHeight ?? 720,
          upload.duration ?? 0,
        )
        return {
          file: await this.#prepareFileObject(file, FileTypes.VIDEO, metadata, upload, signal, alreadyStored),
          media: {
            kind: "video",
            width: metadata.width,
            height: metadata.height,
            duration: metadata.duration,
            photoId: thumbnailPhotoId ? BigInt(thumbnailPhotoId) : undefined,
            isAnimated: upload.isAnimated ?? false,
            hasAudio: upload.hasAudio ?? undefined,
          },
        }
      }
      case "document": {
        const metadata = await getDocumentMetadataAndValidate(file)
        const encryptedFileName = encrypt(metadata.fileName)
        return {
          file: await this.#prepareFileObject(file, FileTypes.DOCUMENT, metadata, upload, signal, alreadyStored),
          media: {
            kind: "document",
            fileName: encryptedFileName.encrypted,
            fileNameIv: encryptedFileName.iv,
            fileNameTag: encryptedFileName.authTag,
            photoId: thumbnailPhotoId ? BigInt(thumbnailPhotoId) : undefined,
          },
        }
      }
      case "voice": {
        const metadata = await getVoiceMetadataAndValidate(
          file,
          upload.duration ?? 0,
          upload.waveform ?? new Uint8Array(),
        )
        return {
          file: await this.#prepareFileObject(file, FileTypes.VOICE, metadata, upload, signal, alreadyStored),
          media: {
            kind: "voice",
            duration: metadata.duration,
            waveform: Buffer.from(metadata.waveform),
          },
        }
      }
      default:
        throw new Error("Upload kind is invalid")
    }
  }

  async #prepareFileObject(
    file: File,
    fileType: FileTypes,
    metadata: {
      width?: number
      height?: number
      extension: string
      mimeType: string
      fileName: string
    },
    upload: InlineUploadRecord,
    signal?: AbortSignal,
    alreadyStored = false,
  ): Promise<InlineUploadPublication["file"]> {
    // Publication is deterministic and fenced before the database commit.
    // The provider request is canceled when worker ownership is lost.
    throwIfAborted(signal)
    const fileUniqueId = upload.resultFileUniqueId ?? inlineUploadFileUniqueId(upload)
    const path = inlineUploadPublicationPath(fileUniqueId)
    const identity = { fileUniqueId, path }
    const prepared = alreadyStored
      ? prepareFileObjectRecord(file.size, fileType, metadata, { userId: upload.userId }, identity)
      : await uploadFileObject(file, fileType, metadata, { userId: upload.userId }, identity, signal)
    return {
      record: prepared.dbFile,
      path,
      fileName: metadata.fileName,
    }
  }
}

const throwIfAborted = (signal: AbortSignal | undefined): void => {
  if (signal?.aborted) throw signal.reason ?? new DOMException("The operation was aborted", "AbortError")
}

export class UploadIntegrityError extends Error {
  constructor() {
    super("Uploaded parts do not match the committed file")
    this.name = "UploadIntegrityError"
  }
}

export class UploadInvalidMediaError extends Error {
  constructor() {
    super("Uploaded media format is not supported")
    this.name = "UploadInvalidMediaError"
  }
}
