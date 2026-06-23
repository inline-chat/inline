import type { AgentFileRef } from "@inline-chat/agent-core"
import type { DbFullMessage } from "@in/server/db/models/messages"
import { getSignedMediaPhotoUrl, getSignedUrl } from "@in/server/modules/files/path"

const SIGNED_URL_TTL_SECONDS = 10 * 60
const MAX_TEXT_ATTACHMENT_BYTES = 64_000

export function buildAttachmentPromptParts(message: DbFullMessage): AgentFileRef[] {
  const refs: AgentFileRef[] = []

  if (message.photo) {
    const largest = [...(message.photo.photoSizes ?? [])].sort((a, b) => (b.width ?? 0) - (a.width ?? 0))[0]
    const url = largest?.file ? getSignedMediaPhotoUrl(largest.file, SIGNED_URL_TTL_SECONDS) : null
    refs.push({
      fileId: message.photo.id,
      kind: "image",
      name: "photo",
      mimeType: largest?.file.mimeType ?? "image/jpeg",
      sizeBytes: largest?.file.fileSize ?? undefined,
      signedUrl: url ?? undefined,
    })
  }

  if (message.document) {
    refs.push({
      fileId: message.document.id,
      kind: "document",
      name: message.document.fileName ?? "document",
      mimeType: message.document.file.mimeType ?? undefined,
      sizeBytes: message.document.file.fileSize ?? undefined,
      signedUrl: signedUrlForPath(message.document.file.path),
    })
  }

  if (message.video) {
    refs.push({
      fileId: message.video.id,
      kind: "video",
      name: "video",
      mimeType: message.video.file.mimeType ?? undefined,
      sizeBytes: message.video.file.fileSize ?? undefined,
      signedUrl: signedUrlForPath(message.video.file.path),
    })
  }

  if (message.voice) {
    refs.push({
      fileId: message.voice.id,
      kind: "audio",
      name: "voice message",
      mimeType: message.voice.file.mimeType ?? undefined,
      sizeBytes: message.voice.file.fileSize ?? undefined,
      signedUrl: signedUrlForPath(message.voice.file.path),
    })
  }

  return refs
}

export function attachmentContextText(message: DbFullMessage): string {
  const refs = buildAttachmentPromptParts(message)
  if (refs.length === 0) {
    return ""
  }

  return refs
    .map((ref) => {
      const name = ref.name ? ` "${ref.name}"` : ""
      const mime = ref.mimeType ? ` (${ref.mimeType})` : ""
      if (ref.kind === "audio" && message.text) {
        return `[voice transcript${name}${mime}]: ${message.text}`
      }
      if (ref.kind === "document" && isInlineTextFile(ref.mimeType, ref.sizeBytes)) {
        return `[document${name}${mime}]: provider can fetch the signed URL if supported.`
      }
      if (ref.signedUrl) {
        return `[${ref.kind}${name}${mime}]: signed URL attached for provider fetch.`
      }
      return `[${ref.kind}${name}${mime}]: attachment exists but no provider-readable URL is available.`
    })
    .join("\n")
}

function signedUrlForPath(path: string | null | undefined): string | undefined {
  if (!path) {
    return undefined
  }
  return getSignedUrl(path, SIGNED_URL_TTL_SECONDS) ?? undefined
}

function isInlineTextFile(mime: string | null | undefined, sizeBytes: number | null | undefined): boolean {
  if ((sizeBytes ?? 0) > MAX_TEXT_ATTACHMENT_BYTES) {
    return false
  }
  return !!mime && (mime.startsWith("text/") || mime === "application/json" || mime.endsWith("+json"))
}
