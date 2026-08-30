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

// Keep this explicit and aligned with MessageNotificationPreview.swift. JavaScript's
// `\s` and Foundation's whitespace sets do not agree on every Unicode scalar.
// oxlint-disable-next-line no-control-regex -- contract includes tab, vertical tab, and form feed
const inlineWhitespace = /[\u0009\u000B\u000C\u0020\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000\uFEFF]+/gu
const trailingPreviewWhitespace =
  // oxlint-disable-next-line no-control-regex -- truncate with the same explicit whitespace contract
  /[\u0009\u000A\u000B\u000C\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+$/gu

const truncatePreview = (value: string, maxBytes: number): string => {
  const ellipsis = "…"
  if (maxBytes < Buffer.byteLength(ellipsis, "utf8")) return ""
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
      return result.replace(trailingPreviewWhitespace, "") + ellipsis
    }
    result += character
    byteLength += characterByteLength
    count += 1
  }

  return result
}

const normalizedText = (text: string | null | undefined): string => {
  return normalizedBodyText(text)
    .split("\n")
    .filter((line) => line !== "")
    .join(" ")
}

const normalizedBodyText = (text: string | null | undefined): string => {
  const lines = (text ?? "")
    .replace(/\r\n|\r|\u0085|\u2028|\u2029/gu, "\n")
    .split("\n")
    .map((line) => line.replace(inlineWhitespace, " ").replace(/^ | $/gu, ""))

  const firstContent = lines.findIndex((line) => line !== "")
  if (firstContent === -1) return ""
  let lastContent = lines.length - 1
  while (lines[lastContent] === "") lastContent -= 1

  const normalizedLines: string[] = []
  for (const line of lines.slice(firstContent, lastContent + 1)) {
    if (line === "" && normalizedLines.at(-1) === "") continue
    normalizedLines.push(line)
  }
  return normalizedLines.join("\n")
}

export const notificationText = (text: string | null | undefined, maxBytes = maxMessagePreviewBytes): string =>
  truncatePreview(normalizedText(text), maxBytes)

export const notificationBodyText = (
  text: string | null | undefined,
  maxBytes = maxMessagePreviewBytes,
): string => truncatePreview(normalizedBodyText(text), maxBytes)

export const messageNotificationBody = ({
  messageText,
  mediaType,
  isSticker,
  documentFileName,
  isAnimated,
  voiceDuration,
}: MessageNotificationBodyInput): string => {
  const text = normalizedBodyText(messageText)
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
