export type MessageNotificationMediaType = "photo" | "video" | "document" | "voice" | "nudge" | null | undefined

type MessageNotificationBodyInput = {
  messageText?: string
  mediaType: MessageNotificationMediaType
  isSticker?: boolean | null
  documentFileName?: string | null
}

const mediaPrefix = (mediaType: MessageNotificationMediaType): string => {
  switch (mediaType) {
    case "photo":
      return "🖼️ "
    case "video":
      return "🎥 "
    case "document":
      return "📄 "
    case "voice":
      return "🎤 "
    default:
      return ""
  }
}

export const maxDocumentFileNamePreviewBytes = 240

const truncateUtf8 = (value: string, maxBytes: number): string => {
  if (Buffer.byteLength(value, "utf8") <= maxBytes) return value

  const ellipsis = "…"
  const contentBudget = maxBytes - Buffer.byteLength(ellipsis, "utf8")
  let result = ""
  let byteLength = 0

  for (const character of value) {
    const characterByteLength = Buffer.byteLength(character, "utf8")
    if (byteLength + characterByteLength > contentBudget) break
    result += character
    byteLength += characterByteLength
  }

  return result.trimEnd() + ellipsis
}

const normalizedFileName = (fileName: string | null | undefined): string | undefined => {
  const normalized = fileName?.trim().replace(/\s+/g, " ")
  return normalized ? truncateUtf8(normalized, maxDocumentFileNamePreviewBytes) : undefined
}

export const messageNotificationBody = ({
  messageText,
  mediaType,
  isSticker,
  documentFileName,
}: MessageNotificationBodyInput): string => {
  if (messageText) {
    return mediaPrefix(mediaType) + messageText.substring(0, 240)
  }
  if (isSticker) {
    return "🖼️ Sticker"
  }

  switch (mediaType) {
    case "photo":
      return "🖼️ Photo"
    case "video":
      return "🎥 Video"
    case "document":
      return `📄 ${normalizedFileName(documentFileName) ?? "Document"}`
    case "voice":
      return "🎤 Voice message"
    default:
      return "New message"
  }
}
