export type MessageNotificationMediaType = "photo" | "video" | "document" | "voice" | "nudge" | null | undefined

type MessageNotificationBodyInput = {
  messageText?: string
  mediaType: MessageNotificationMediaType
  isSticker?: boolean | null
  documentFileName?: string | null
  isAnimated?: boolean | null
  voiceDuration?: number | null
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
export const maxMessagePreviewBytes = 960
export const maxNotificationNameBytes = 256
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

const truncatePreview = (value: string, maxBytes: number): string => {
  const ellipsis = "…"
  const contentBudget = maxBytes - Buffer.byteLength(ellipsis, "utf8")
  let result = ""
  let byteLength = 0
  let count = 0

  for (const { segment: character } of graphemes.segment(value)) {
    const characterByteLength = Buffer.byteLength(character, "utf8")
    if (count == 240 || byteLength + characterByteLength > maxBytes) {
      while (Buffer.byteLength(result, "utf8") > contentBudget) {
        const segments = Array.from(graphemes.segment(result))
        result = result.slice(0, segments.at(-1)!.index)
      }
      return result.trimEnd() + ellipsis
    }
    result += character
    byteLength += characterByteLength
    count += 1
  }

  return result
}

const normalizedText = (text: string | null | undefined): string => {
  return text?.trim().replace(/\s+/g, " ") ?? ""
}

export const notificationText = (text: string | null | undefined, maxBytes = maxMessagePreviewBytes): string =>
  truncatePreview(normalizedText(text), maxBytes)

export const messageNotificationBody = ({
  messageText,
  mediaType,
  isSticker,
  documentFileName,
  isAnimated,
  voiceDuration,
}: MessageNotificationBodyInput): string => {
  const text = normalizedText(messageText)
  if (mediaType === "nudge") {
    return text === "🚨" ? "🚨 Urgent nudge" : "👋 Nudge"
  }
  if (text) {
    const prefix = isSticker ? "🖼️ " : mediaType === "video" && isAnimated ? "🎞️ " : mediaPrefix(mediaType)
    return prefix + truncatePreview(text, maxMessagePreviewBytes)
  }
  if (isSticker) {
    return "🖼️ Sticker"
  }

  switch (mediaType) {
    case "photo":
      return "🖼️ Photo"
    case "video":
      return isAnimated ? "🎞️ GIF" : "🎥 Video"
    case "document":
      return `📄 ${truncatePreview(normalizedText(documentFileName), maxDocumentFileNamePreviewBytes) || "Document"}`
    case "voice":
      if (voiceDuration != null && Number.isFinite(voiceDuration) && voiceDuration > 0) {
        const seconds = Math.floor(voiceDuration)
        return `🎤 Voice message (${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")})`
      }
      return "🎤 Voice message"
    default:
      return "New message"
  }
}
