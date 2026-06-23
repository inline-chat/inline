import type { RichMediaRef, RichMessage } from "@inline-chat/protocol/core"
import {
  FileModel,
  type DbFullDocument,
  type DbFullPhoto,
  type DbFullVideo,
  type DbFullVoice,
} from "@in/server/db/models/files"
import { RichTextValidationError, richMediaDependencies } from "@in/server/modules/message/richText"

type InternalMediaKind = "photoId" | "videoId" | "documentId" | "voiceId"

export type InternalRichMediaValidationOptions = {
  readonly ownerUserId?: number
}

export async function validateInternalRichMediaRefs(
  richText: RichMessage | null | undefined,
  options: InternalRichMediaValidationOptions = {},
): Promise<void> {
  if (!richText) {
    return
  }

  const pending = new Map<string, Promise<void>>()
  for (const dep of richMediaDependencies(richText)) {
    const ref = internalRef(dep.ref)
    if (!ref) {
      continue
    }

    const key = `${ref.kind}:${ref.id}`
    let validation = pending.get(key)
    if (!validation) {
      validation = validateInternalMedia(ref.kind, ref.id, options)
      pending.set(key, validation)
    }
    await validation
  }
}

function internalRef(ref: RichMediaRef): { kind: InternalMediaKind; id: number } | undefined {
  switch (ref.media.oneofKind) {
    case "photoId":
      return checkedRef("photoId", ref.media.photoId)
    case "videoId":
      return checkedRef("videoId", ref.media.videoId)
    case "documentId":
      return checkedRef("documentId", ref.media.documentId)
    case "voiceId":
      return checkedRef("voiceId", ref.media.voiceId)
    default:
      return undefined
  }
}

function checkedRef(kind: InternalMediaKind, id: bigint): { kind: InternalMediaKind; id: number } {
  const numberId = Number(id)
  if (!Number.isSafeInteger(numberId) || numberId <= 0) {
    throw new RichTextValidationError(`Invalid rich media ${kind}`)
  }
  return { kind, id: numberId }
}

async function validateInternalMedia(
  kind: InternalMediaKind,
  id: number,
  options: InternalRichMediaValidationOptions,
): Promise<void> {
  let media: DbFullPhoto | DbFullVideo | DbFullDocument | DbFullVoice | undefined
  try {
    switch (kind) {
      case "photoId":
        media = await FileModel.getPhotoById(BigInt(id))
        break
      case "videoId":
        media = await FileModel.getVideoById(BigInt(id))
        break
      case "documentId":
        media = await FileModel.getDocumentById(BigInt(id))
        break
      case "voiceId":
        media = await FileModel.getVoiceById(BigInt(id))
        break
    }
  } catch {
    throw new RichTextValidationError(`Invalid rich media ${kind}`)
  }

  if (!media) {
    throw new RichTextValidationError(`Invalid rich media ${kind}`)
  }

  if (options.ownerUserId !== undefined && !isOwnedBy(media, options.ownerUserId)) {
    throw new RichTextValidationError(`Invalid rich media ${kind}`)
  }
}

function isOwnedBy(media: DbFullPhoto | DbFullVideo | DbFullDocument | DbFullVoice, userId: number): boolean {
  if ("photoSizes" in media) {
    const sizes = media.photoSizes ?? []
    return sizes.length > 0 && sizes.every((size) => size.file.userId === userId)
  }

  return media.file.userId === userId
}
