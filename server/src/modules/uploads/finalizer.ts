import { createHash } from "node:crypto"
import { mkdtemp, open, rmdir, unlink } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { UploadComplete } from "@inline-chat/protocol/core"
import { FileModel } from "@in/server/db/models/files"
import type {
  InlineUploadPartRecord,
  InlineUploadRecord,
} from "@in/server/db/models/inlineUploads"
import { uploadDocument } from "@in/server/modules/files/uploadDocument"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { uploadVideo } from "@in/server/modules/files/uploadVideo"
import { uploadVoice } from "@in/server/modules/files/uploadVoice"
import { encodeDocument } from "@in/server/realtime/encoders/encodeDocument"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { encodeVideo } from "@in/server/realtime/encoders/encodeVideo"
import { encodeVoice } from "@in/server/realtime/encoders/encodeVoice"
import type { UploadPartStore } from "./partStore"

export type FinalizedUpload = {
  fileUniqueId: string
  mediaId: number
  complete: UploadComplete
}

export interface MediaUploadFinalizer {
  finalize(input: {
    upload: InlineUploadRecord
    parts: InlineUploadPartRecord[]
    thumbnailPhotoId?: number
  }): Promise<FinalizedUpload>
  project(
    kind: InlineUploadRecord["kind"],
    fileUniqueId: string,
    mediaId: number,
  ): Promise<UploadComplete>
}

const sameBytes = (left: Uint8Array, right: Uint8Array): boolean =>
  Buffer.from(left).equals(Buffer.from(right))

const mediaIdFor = (input: {
  photoId?: number
  videoId?: number
  documentId?: number
  voiceId?: number
}): number | undefined => input.photoId ?? input.videoId ?? input.documentId ?? input.voiceId

export class UploadMediaFinalizer implements MediaUploadFinalizer {
  constructor(private readonly partStore: UploadPartStore) {}

  async finalize(input: {
    upload: InlineUploadRecord
    parts: InlineUploadPartRecord[]
    thumbnailPhotoId?: number
  }): Promise<FinalizedUpload> {
    const directory = await mkdtemp(join(tmpdir(), "inline-native-upload-"))
    const path = join(directory, "body")
    const handle = await open(path, "wx")
    const digest = createHash("sha256")
    let byteCount = 0n
    try {
      for (const part of input.parts) {
        const bytes = await this.partStore.read(part.objectKey)
        const partDigest = createHash("sha256").update(bytes).digest()
        if (bytes.length !== part.byteCount || !sameBytes(partDigest, part.sha256)) {
          throw new UploadIntegrityError()
        }
        await handle.write(bytes)
        digest.update(bytes)
        byteCount += BigInt(bytes.length)
      }
      await handle.sync()
      await handle.close()
      if (byteCount !== input.upload.byteCount ||
          !sameBytes(digest.digest(), input.upload.sha256)) {
        throw new UploadIntegrityError()
      }

      const file = new File([Bun.file(path)], input.upload.fileName, { type: input.upload.mimeType })
      const result = await this.#uploadMedia(file, input.upload, input.thumbnailPhotoId)
      const mediaId = mediaIdFor(result)
      if (!mediaId) throw new Error("Media upload completed without a media identifier")
      return {
        fileUniqueId: result.fileUniqueId,
        mediaId,
        complete: await this.project(input.upload.kind, result.fileUniqueId, mediaId),
      }
    } finally {
      await handle.close().catch(() => {})
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

  async #uploadMedia(file: File, upload: InlineUploadRecord, thumbnailPhotoId?: number) {
    switch (upload.kind) {
      case "photo":
        return uploadPhoto(file, { userId: upload.userId })
      case "video":
        return uploadVideo(file, {
          width: upload.videoWidth ?? 1280,
          height: upload.videoHeight ?? 720,
          duration: upload.duration ?? 0,
          photoId: thumbnailPhotoId ? BigInt(thumbnailPhotoId) : undefined,
          isAnimated: upload.isAnimated ?? false,
          hasAudio: upload.hasAudio ?? undefined,
        }, { userId: upload.userId })
      case "document":
        return uploadDocument(file, thumbnailPhotoId ? BigInt(thumbnailPhotoId) : undefined, {
          userId: upload.userId,
        })
      case "voice":
        return uploadVoice(file, {
          duration: upload.duration ?? 0,
          waveform: upload.waveform ?? new Uint8Array(),
        }, { userId: upload.userId })
      default:
        throw new Error("Upload kind is invalid")
    }
  }
}

export class UploadIntegrityError extends Error {
  constructor() {
    super("Uploaded parts do not match the committed file")
    this.name = "UploadIntegrityError"
  }
}
