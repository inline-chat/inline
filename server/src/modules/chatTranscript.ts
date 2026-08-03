import type { DbFullDocument, DbFullPhoto, DbFullVideo, DbFullVoice } from "@in/server/db/models/files"
import type { DbFullMessage, ProcessedLinkEmbed } from "@in/server/db/models/messages"
import { getSignedMediaPhotoUrl, getSignedUrl } from "@in/server/modules/files/path"
import { toMd } from "@in/server/modules/translation2/entities"

export const CHAT_TRANSCRIPT_DEFAULT_LIMIT = 500
export const CHAT_TRANSCRIPT_MAX_LIMIT = 500
export const CHAT_TRANSCRIPT_MAX_OUTPUT_BYTES = 1024 * 1024
export const CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS = 60 * 60 * 24 * 7

export type ChatTranscriptStopReason = "complete" | "messageLimit" | "outputLimit"

export type ChatTranscriptMedia = {
  kind: "photo" | "video" | "document" | "voice"
  label: string
  url: string
  expiresAt: number
}

export type ChatTranscriptMessage = {
  id: number
  author: string
  markdownText?: string
  replyToMessageId?: number
  forwarded: boolean
  media: ChatTranscriptMedia[]
  fallback?: string
}

export type ChatTranscriptPage = {
  markdown: string
  messageCount: number
  fromMessageId?: number
  toMessageId?: number
  hasMore: boolean
  stopReason: ChatTranscriptStopReason
  expiresAt?: number
}

type RenderInput = {
  title: string
  link: string
  parent?: ChatTranscriptMessage
  parentChat?: { title: string; link: string }
  messagesNewestFirst: ChatTranscriptMessage[]
  hasOlderMessages: boolean
  maxOutputBytes?: number
}

export function renderHumanReadableChatTranscript(input: RenderInput): ChatTranscriptPage {
  const header = renderHeader(input)
  const renderedNewestFirst = input.messagesNewestFirst.map((message) => ({
    message,
    markdown: renderMessage(message, input.messagesNewestFirst),
  }))
  const maxOutputBytes = input.maxOutputBytes ?? CHAT_TRANSCRIPT_MAX_OUTPUT_BYTES
  const selected: typeof renderedNewestFirst = []
  let outputBytes = Buffer.byteLength(`${header}\n\n`, "utf8")
  let outputLimited = false

  for (const rendered of renderedNewestFirst) {
    const additionalBytes = Buffer.byteLength(`${rendered.markdown}\n\n`, "utf8")
    if (selected.length > 0 && outputBytes + additionalBytes > maxOutputBytes) {
      outputLimited = true
      break
    }

    selected.push(rendered)
    outputBytes += additionalBytes
  }

  const chronological = selected.toReversed()
  const body = chronological.length > 0
    ? chronological.map((item) => item.markdown).join("\n\n")
    : "_No messages._"
  const representedMessages = selected.map((item) => item.message)
  const allRepresentedMessages = input.parent ? [input.parent, ...representedMessages] : representedMessages
  const expiresAt = minimumExpiration(allRepresentedMessages)
  const hasMore = outputLimited || input.hasOlderMessages

  return {
    markdown: `${header}\n\n${body}`,
    messageCount: selected.length,
    fromMessageId: chronological[0]?.message.id,
    toMessageId: chronological.at(-1)?.message.id,
    hasMore,
    stopReason: outputLimited ? "outputLimit" : input.hasOlderMessages ? "messageLimit" : "complete",
    expiresAt,
  }
}

export function normalizeChatTranscriptMessage(
  message: DbFullMessage,
  options: { includeMedia: boolean; nowSeconds: number },
): ChatTranscriptMessage {
  const markdownText = message.text?.trim()
    ? toMd(message.text, message.entities).trim()
    : undefined

  return {
    id: message.messageId,
    author: displayName(message.from),
    markdownText,
    replyToMessageId: message.replyToMsgId ?? undefined,
    forwarded: message.fwdFromMessageId != null,
    media: options.includeMedia ? collectMedia(message, options.nowSeconds) : [],
    fallback: message.mediaType === "nudge" ? "👋 Nudge" : undefined,
  }
}

function renderHeader(input: RenderInput): string {
  const lines = [
    `# ${escapeMarkdownText(input.title)}`,
    "",
    `[Open in Inline](<${input.link}>)`,
  ]

  if (input.parent) {
    lines.push("", "## Parent message")
    if (input.parentChat) {
      lines.push("", `From [${escapeMarkdownText(input.parentChat.title)}](<${input.parentChat.link}>)`)
    }
    lines.push("", renderMessage(input.parent, [input.parent]))
  }

  lines.push("", "## Conversation")
  return lines.join("\n")
}

function renderMessage(message: ChatTranscriptMessage, context: ChatTranscriptMessage[]): string {
  const lines = [`**${escapeMarkdownText(message.author)}**`]

  if (message.forwarded) {
    lines.push("", "> Forwarded message")
  }

  const repliedTo = message.replyToMessageId == null
    ? undefined
    : context.find((candidate) => candidate.id === message.replyToMessageId)
  if (repliedTo) {
    const excerpt = plainExcerpt(repliedTo.markdownText ?? repliedTo.fallback ?? "Message")
    lines.push("", `> Replying to **${escapeMarkdownText(repliedTo.author)}**: ${excerpt}`)
  }

  if (message.markdownText) {
    lines.push("", message.markdownText)
  }

  for (const media of message.media) {
    lines.push("", renderMedia(media))
  }

  if (!message.markdownText && message.media.length === 0) {
    lines.push("", message.fallback ?? "_Unsupported message_")
  }

  return lines.join("\n")
}

function renderMedia(media: ChatTranscriptMedia): string {
  const label = escapeMarkdownText(media.label)
  if (media.kind === "photo") {
    return `![${label}](<${media.url}>)`
  }
  return `[${label}](<${media.url}>)`
}

function collectMedia(message: DbFullMessage, nowSeconds: number): ChatTranscriptMedia[] {
  const media: ChatTranscriptMedia[] = []

  appendPhoto(media, message.photo, "Photo", nowSeconds)
  appendVideo(media, message.video, "Video", nowSeconds)
  appendDocument(media, message.document, nowSeconds)
  appendVoice(media, message.voice, nowSeconds)

  for (const attachment of message.messageAttachments ?? []) {
    appendLinkPreviewMedia(media, attachment.linkEmbed, nowSeconds)
  }

  return media
}

function appendLinkPreviewMedia(
  output: ChatTranscriptMedia[],
  preview: ProcessedLinkEmbed | null | undefined,
  nowSeconds: number,
): void {
  if (!preview) return

  switch (preview.mediaKind) {
    case "photo":
      appendPhoto(output, preview.photo, preview.title ?? "Link preview image", nowSeconds)
      break
    case "video":
      appendVideo(output, preview.video, preview.title ?? "Link preview video", nowSeconds)
      break
    case "document":
      appendDocument(output, preview.document, nowSeconds, preview.title ?? undefined)
      break
  }
}

function appendPhoto(
  output: ChatTranscriptMedia[],
  photo: DbFullPhoto | null | undefined,
  label: string,
  nowSeconds: number,
): void {
  const files = photo?.photoSizes
    ?.map((size) => size.file)
    .sort((a, b) => (b.fileSize ?? 0) - (a.fileSize ?? 0)) ?? []
  const signed = files
    .map((file) => getSignedMediaPhotoUrl(file, CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS))
    .find((url): url is string => url != null)

  if (!signed) return
  output.push({ kind: "photo", label, url: signed, expiresAt: nowSeconds + CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS })
}

function appendVideo(
  output: ChatTranscriptMedia[],
  video: DbFullVideo | null | undefined,
  label: string,
  nowSeconds: number,
): void {
  const url = video?.file.path ? getSignedUrl(video.file.path, CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS) : null
  if (!url) return
  output.push({ kind: "video", label, url, expiresAt: nowSeconds + CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS })
}

function appendDocument(
  output: ChatTranscriptMedia[],
  document: DbFullDocument | null | undefined,
  nowSeconds: number,
  label?: string,
): void {
  const url = document?.file.path ? getSignedUrl(document.file.path, CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS) : null
  if (!url) return
  output.push({
    kind: "document",
    label: label ?? document?.fileName ?? "Document",
    url,
    expiresAt: nowSeconds + CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS,
  })
}

function appendVoice(
  output: ChatTranscriptMedia[],
  voice: DbFullVoice | null | undefined,
  nowSeconds: number,
): void {
  const url = voice?.file.path ? getSignedUrl(voice.file.path, CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS) : null
  if (!url) return
  output.push({ kind: "voice", label: "Voice message", url, expiresAt: nowSeconds + CHAT_TRANSCRIPT_MEDIA_URL_TTL_SECONDS })
}

function displayName(user: DbFullMessage["from"]): string {
  const fullName = [user.firstName, user.lastName].filter(Boolean).join(" ").trim()
  return fullName || user.username || "Inline member"
}

function minimumExpiration(messages: ChatTranscriptMessage[]): number | undefined {
  const expirations = messages.flatMap((message) => message.media.map((media) => media.expiresAt))
  return expirations.length > 0 ? Math.min(...expirations) : undefined
}

function plainExcerpt(markdown: string): string {
  const compact = markdown.replace(/\s+/gu, " ").trim()
  return escapeMarkdownText(compact.length > 120 ? `${compact.slice(0, 117)}…` : compact)
}

function escapeMarkdownText(value: string): string {
  return value
    .replace(/\s+/gu, " ")
    .trim()
    .replace(/([\\`*_{}[\]<>])/gu, "\\$1")
}
