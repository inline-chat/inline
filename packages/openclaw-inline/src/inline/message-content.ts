import { MessageEntity_Type, type Message } from "@inline-chat/realtime-sdk"

export type InlineMessageMediaSummary =
  | {
      kind: "photo" | "video" | "document" | "nudge"
      id: string | null
      url: string | null
      fileName?: string | null
      mimeType?: string | null
      sizeBytes?: number | null
      width?: number | null
      height?: number | null
      durationSeconds?: number | null
    }
  | null

export type InlineMessageAttachmentSummary =
  | {
      kind: "urlPreview"
      id: string | null
      url: string | null
      siteName: string | null
      title: string | null
      description: string | null
      previewImageUrl: string | null
    }
  | {
      kind: "externalTask"
      id: string | null
      url: string | null
      application: string | null
      title: string | null
      taskId: string | null
      number: string | null
    }

export type InlineMessageContent = {
  text: string
  rawText: string
  links: string[]
  attachmentUrls: string[]
  media: InlineMessageMediaSummary
  attachments: InlineMessageAttachmentSummary[]
}

function compactWhitespace(raw: string | undefined): string {
  return (raw ?? "").replace(/\s+/g, " ").trim()
}

function bestPhotoSize(photo: {
  sizes?: Array<{ w?: number; h?: number; size?: number; cdnUrl?: string }>
}): {
  cdnUrl: string | null
  width: number | null
  height: number | null
  sizeBytes: number | null
} {
  let best: { cdnUrl: string | null; width: number | null; height: number | null; sizeBytes: number | null } = {
    cdnUrl: null,
    width: null,
    height: null,
    sizeBytes: null,
  }
  let bestArea = -1

  for (const size of photo.sizes ?? []) {
    const width = typeof size.w === "number" ? size.w : null
    const height = typeof size.h === "number" ? size.h : null
    const area = Math.max(0, width ?? 0) * Math.max(0, height ?? 0)
    if (size.cdnUrl && area >= bestArea) {
      bestArea = area
      best = {
        cdnUrl: size.cdnUrl,
        width,
        height,
        sizeBytes: typeof size.size === "number" ? size.size : null,
      }
    }
  }

  return best
}

function messageMediaSummary(message: Message): InlineMessageMediaSummary {
  const media = message.media?.media
  if (!media) return null

  if (media.oneofKind === "photo") {
    const photo = media.photo.photo
    const bestSize = photo ? bestPhotoSize(photo) : { cdnUrl: null, width: null, height: null, sizeBytes: null }
    return {
      kind: "photo",
      id: photo?.id?.toString() ?? null,
      url: bestSize.cdnUrl,
      sizeBytes: bestSize.sizeBytes,
      width: bestSize.width,
      height: bestSize.height,
    }
  }

  if (media.oneofKind === "video") {
    const video = media.video.video
    return {
      kind: "video",
      id: video?.id?.toString() ?? null,
      url: video?.cdnUrl ?? null,
      sizeBytes: video?.size ?? null,
      width: video?.w ?? null,
      height: video?.h ?? null,
      durationSeconds: video?.duration ?? null,
    }
  }

  if (media.oneofKind === "document") {
    const document = media.document.document
    return {
      kind: "document",
      id: document?.id?.toString() ?? null,
      url: document?.cdnUrl ?? null,
      fileName: document?.fileName ?? null,
      mimeType: document?.mimeType ?? null,
      sizeBytes: document?.size ?? null,
    }
  }

  return {
    kind: "nudge",
    id: null,
    url: null,
  }
}

function messageAttachmentSummaries(message: Message): InlineMessageAttachmentSummary[] {
  const attachments: InlineMessageAttachmentSummary[] = []

  for (const item of message.attachments?.attachments ?? []) {
    if (item.attachment.oneofKind === "urlPreview") {
      const preview = item.attachment.urlPreview
      const previewPhoto = preview.photo ? bestPhotoSize(preview.photo).cdnUrl : null
      attachments.push({
        kind: "urlPreview",
        id: preview.id?.toString() ?? null,
        url: preview.url ?? null,
        siteName: preview.siteName ?? null,
        title: preview.title ?? null,
        description: preview.description ?? null,
        previewImageUrl: previewPhoto,
      })
      continue
    }

    if (item.attachment.oneofKind === "externalTask") {
      const task = item.attachment.externalTask
      attachments.push({
        kind: "externalTask",
        id: task.id?.toString() ?? null,
        url: task.url ?? null,
        application: task.application ?? null,
        title: task.title ?? null,
        taskId: task.taskId ?? null,
        number: task.number ?? null,
      })
    }
  }

  return attachments
}

function extractMessageUrls(message: Message, attachments: InlineMessageAttachmentSummary[]): string[] {
  const urls = new Set<string>()

  for (const entity of message.entities?.entities ?? []) {
    if (entity.type !== MessageEntity_Type.URL && entity.type !== MessageEntity_Type.TEXT_URL) continue

    if (entity.entity.oneofKind === "textUrl") {
      const candidate = entity.entity.textUrl.url?.trim()
      if (candidate) urls.add(candidate)
      continue
    }

    if (typeof message.message !== "string") continue
    const offset = Number(entity.offset)
    const length = Number(entity.length)
    if (!Number.isFinite(offset) || !Number.isFinite(length) || offset < 0 || length <= 0) continue
    const candidate = message.message.slice(offset, offset + length).trim()
    if (candidate) urls.add(candidate)
  }

  for (const attachment of attachments) {
    const candidate = attachment.url?.trim()
    if (candidate) urls.add(candidate)
  }

  return Array.from(urls)
}

function formatMediaSummary(media: Exclude<InlineMessageMediaSummary, null>): string {
  if (media.kind === "nudge") return "[nudge]"
  if (media.kind === "photo") {
    return media.url ? `[photo] ${media.url}` : "[photo]"
  }
  if (media.kind === "video") {
    return media.url ? `[video] ${media.url}` : "[video]"
  }

  const label = media.fileName ? `[document: ${media.fileName}]` : "[document]"
  return media.url ? `${label} ${media.url}` : label
}

function formatAttachmentSummary(attachment: InlineMessageAttachmentSummary): string {
  if (attachment.kind === "urlPreview") {
    const title = compactWhitespace(attachment.title ?? undefined)
    const url = attachment.url?.trim() ?? ""
    if (title && url) return `[link preview: ${title}] ${url}`
    if (url) return `[link preview] ${url}`
    if (title) return `[link preview: ${title}]`
    return "[link preview]"
  }

  const title = compactWhitespace(attachment.title ?? undefined)
  const source = compactWhitespace(attachment.application ?? undefined)
  const url = attachment.url?.trim() ?? ""
  const label = [source, title].filter(Boolean).join(": ")
  if (label && url) return `[task: ${label}] ${url}`
  if (url) return `[task] ${url}`
  if (label) return `[task: ${label}]`
  return "[task]"
}

export function summarizeInlineMessageContent(message: Message): InlineMessageContent {
  const rawText = compactWhitespace(message.message)
  const media = messageMediaSummary(message)
  const attachments = messageAttachmentSummaries(message)
  const links = extractMessageUrls(message, attachments)
  const attachmentUrls = Array.from(
    new Set([
      ...(media?.url ? [media.url] : []),
      ...links,
      ...attachments
        .flatMap((attachment) =>
          attachment.kind === "urlPreview" && attachment.previewImageUrl ? [attachment.previewImageUrl] : [],
        ),
    ]),
  )

  const parts = [rawText]
  if (media) {
    parts.push(formatMediaSummary(media))
  }
  for (const attachment of attachments) {
    parts.push(formatAttachmentSummary(attachment))
  }

  return {
    text: parts.filter(Boolean).join(" | "),
    rawText,
    links,
    attachmentUrls,
    media,
    attachments,
  }
}
