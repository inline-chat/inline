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

const normalizedFileName = (fileName: string | null | undefined): string | undefined => {
  const normalized = fileName?.trim().replace(/\s+/g, " ")
  return normalized ? normalized : undefined
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
