import type { Message } from "@inline/client"
import type {
  MessageAttachment,
  MessageEntities,
  Photo,
  PhotoSize,
  UrlPreview,
} from "@inline-chat/protocol/core"
import { userId, type UserID } from "@inline/ids"
import { inlineTinyThumbnailDataUrl } from "../inline/media/InlineTinyThumbnail"
import type { InlineMediaDescriptor } from "../inline/media/InlineFirstFrameMedia"

export type ChatMessageMediaPresentation =
  | {
      kind: "photo"
      mediaKey: string
      remoteUrl?: string
      tinyThumbnailUrl?: string
      width: number
      height: number
      label: "Photo"
    }
  | {
      kind: "video"
      mediaKey: string
      remoteUrl?: string
      posterKey?: string
      posterUrl?: string
      tinyThumbnailUrl?: string
      width: number
      height: number
      duration?: number
      animated: boolean
      label: "Video" | "Animation"
    }
  | {
      kind: "document"
      mediaKey: string
      remoteUrl?: string
      fileName: string
      mimeType?: string
      size?: number
      label: string
    }
  | {
      kind: "voice"
      duration?: number
      waveform: number[]
      label: "Voice message"
    }
  | {
      kind: "nudge"
      label: "Nudge"
    }

export type ChatMessagePresentation = {
  text?: string
  entities?: MessageEntities
  media?: ChatMessageMediaPresentation
  attachments?: ChatMessageAttachmentPresentation[]
  service?: string
  fallback?: "Attachment" | "Unsupported message"
}

export type ChatMessageAttachmentPresentation =
  | {
      kind: "urlPreview"
      key: string
      url?: string
      source?: string
      title: string
      subtitle?: string
      thumbnail?: {
        mediaKey: string
        remoteUrl?: string
      }
    }
  | {
      kind: "externalTask"
      key: string
      url?: string
      application?: string
      number?: string
      title: string
      assignedUserId?: UserID
    }
  | {
      kind: "unsupported"
      key: string
      label: "Attachment"
    }

export const messagePresentationMediaDescriptors = (
  presentation: ChatMessagePresentation,
): InlineMediaDescriptor[] => {
  const descriptors: InlineMediaDescriptor[] = []
  const media = presentation.media
  if (media?.kind === "photo" || media?.kind === "video") {
    descriptors.push({ key: media.mediaKey })
    if (media.kind === "video" && media.posterKey) {
      descriptors.push({ key: media.posterKey })
    }
  }
  for (const attachment of presentation.attachments ?? []) {
    if (
      attachment.kind === "urlPreview" &&
      attachment.thumbnail
    ) {
      descriptors.push({ key: attachment.thumbnail.mediaKey })
    }
  }
  return descriptors
}

const photoTypePriority = (type: string) => {
  switch (type) {
    case "f":
      return 4
    case "d":
      return 3
    case "c":
      return 2
    case "b":
      return 1
    default:
      return 0
  }
}

const photoAvailabilityPriority = (size: PhotoSize) =>
  size.cdnUrl ? 1 : 0

/** Mirrors InlineKit's PhotoInfo.bestPhotoSize ordering without leaking the
 * protobuf object (or bigint photo ID) into React props. */
export const bestPhotoSize = (photo?: Photo) => {
  const sizes = photo?.sizes ?? []
  const candidates = sizes.some((size) => size.type !== "s")
    ? sizes.filter((size) => size.type !== "s")
    : sizes
  return candidates.reduce<PhotoSize | undefined>((best, size) => {
    if (!best) return size
    const priority = photoTypePriority(size.type) - photoTypePriority(best.type)
    if (priority !== 0) return priority > 0 ? size : best
    const area = Math.max(size.w * size.h, 0)
    const bestArea = Math.max(best.w * best.h, 0)
    if (area !== bestArea) return area > bestArea ? size : best
    if (size.size !== best.size) return size.size > best.size ? size : best
    return photoAvailabilityPriority(size) > photoAvailabilityPriority(best)
      ? size
      : best
  }, undefined)
}

const validDimension = (value: number | undefined) =>
  Number.isFinite(value) && value! > 0 ? Math.ceil(value!) : undefined

const mediaDimensions = (
  width: number | undefined,
  height: number | undefined,
) => ({
  width: validDimension(width) ?? 40,
  height: validDimension(height) ?? 40,
})

export const messageMediaDisplaySize = (
  sourceWidth: number,
  sourceHeight: number,
  hasCaption: boolean,
) => {
  const width = sourceWidth > 0 ? sourceWidth : 40
  const height = sourceHeight > 0 ? sourceHeight : 40
  const maxSide = 320
  const scale = Math.min(maxSide / width, maxSide / height)
  const cappedScale = hasCaption ? scale : Math.min(1, scale)
  return {
    width: Math.max(40, Math.ceil(width * cappedScale)),
    height: Math.max(40, Math.ceil(height * cappedScale)),
  }
}

const photoPresentation = (photo: Photo | undefined) => {
  const size = bestPhotoSize(photo)
  const tinyThumbnail =
    photo?.sizes.find(
      (candidate) => candidate.type === "s" && candidate.bytes?.length,
    ) ?? photo?.sizes.find((candidate) => candidate.bytes?.length)
  const dimensions = mediaDimensions(size?.w, size?.h)
  return {
    kind: "photo" as const,
    mediaKey: `photo:${photo?.id.toString() ?? "unknown"}:${size?.type ?? "unknown"}`,
    remoteUrl: size?.cdnUrl,
    tinyThumbnailUrl: inlineTinyThumbnailDataUrl(tinyThumbnail?.bytes),
    ...dimensions,
    label: "Photo" as const,
  }
}

const safeHttpUrl = (value?: string) => {
  if (!value) return undefined
  try {
    const url = new URL(value)
    return url.protocol === "https:" || url.protocol === "http:"
      ? url.href
      : undefined
  } catch {
    return undefined
  }
}

const normalizedHost = (value?: string) => {
  const url = safeHttpUrl(value)
  if (!url) return undefined
  try {
    return new URL(url).hostname.replace(/^www\./, "") || undefined
  } catch {
    return undefined
  }
}

const limited = (value: string | undefined, length: number) => {
  const text = value?.trim()
  if (!text) return undefined
  return text.length <= length
    ? text
    : `${text.slice(0, Math.max(0, length - 1)).trimEnd()}…`
}

const durationLabel = (duration: bigint | undefined) => {
  if (!duration || duration <= 0n || duration > BigInt(Number.MAX_SAFE_INTEGER)) {
    return undefined
  }
  const seconds = Number(duration)
  const minutes = Math.floor(seconds / 60)
  return `${minutes}:${String(seconds % 60).padStart(2, "0")}`
}

const previewPhoto = (preview: UrlPreview) => {
  const media = preview.media?.media
  if (media?.oneofKind === "photo") return media.photo
  if (media?.oneofKind === "video") return media.video.photo
  return preview.photo
}

const urlPreviewPresentation = (
  attachment: MessageAttachment,
  preview: UrlPreview,
): ChatMessageAttachmentPresentation => {
  const source =
    limited(preview.provider, 48) ??
    limited(preview.siteName, 48) ??
    normalizedHost(preview.displayUrl) ??
    normalizedHost(preview.url)
  const url = safeHttpUrl(preview.url)
  const title =
    limited(preview.title, 120) ??
    source ??
    limited(preview.displayUrl, 120) ??
    (url ? limited(url, 120) : undefined) ??
    "Link"
  const subtitle = [
    title.toLowerCase() === (source ?? "").toLowerCase()
      ? undefined
      : source,
    durationLabel(preview.duration),
    limited(preview.description, 110),
  ]
    .filter(Boolean)
    .join(" • ") || undefined
  const photo = previewPhoto(preview)
  const size = bestPhotoSize(photo)
  return {
    kind: "urlPreview",
    key: `attachment:${attachment.id.toString()}`,
    url,
    source,
    title,
    subtitle,
    thumbnail: photo
      ? {
          mediaKey: `photo:${photo.id.toString()}:${size?.type ?? "unknown"}`,
          remoteUrl: size?.cdnUrl,
        }
      : undefined,
  }
}

export const makeAttachmentPresentations = (
  attachments: MessageAttachment[],
): ChatMessageAttachmentPresentation[] =>
  attachments.map((attachment) => {
    const payload = attachment.attachment
    if (payload.oneofKind === "urlPreview") {
      return urlPreviewPresentation(attachment, payload.urlPreview)
    }
    if (payload.oneofKind === "externalTask") {
      const task = payload.externalTask
      return {
        kind: "externalTask",
        key: `attachment:${attachment.id.toString()}`,
        url: safeHttpUrl(task.url),
        application: limited(task.application, 48),
        number: limited(task.number, 32),
        title: limited(task.title, 160) ?? "Untitled",
        assignedUserId:
          task.assignedUserId > 0n
            ? userId(task.assignedUserId)
            : undefined,
      }
    }
    return {
      kind: "unsupported",
      key: `attachment:${attachment.id.toString()}`,
      label: "Attachment",
    }
  })

export const makeMessagePresentation = (
  message: Message,
): ChatMessagePresentation => {
  const text = message.message?.trim()
    ? message.message
    : undefined
  const media = message.media?.media
  const attachments = makeAttachmentPresentations(
    message.attachments?.attachments ?? [],
  )
  const textContent = {
    text,
    entities: text ? message.entities : undefined,
  }
  const content =
    attachments.length > 0
      ? { ...textContent, attachments }
      : textContent

  switch (media?.oneofKind) {
    case "photo":
      return { ...content, media: photoPresentation(media.photo.photo) }
    case "video": {
      const video = media.video.video
      const poster = bestPhotoSize(video?.photo)
      const tinyThumbnail =
        video?.photo?.sizes.find(
          (candidate) =>
            candidate.type === "s" && candidate.bytes?.length,
        ) ?? video?.photo?.sizes.find((candidate) => candidate.bytes?.length)
      const dimensions = mediaDimensions(
        validDimension(video?.w) ?? poster?.w,
        validDimension(video?.h) ?? poster?.h,
      )
      const animated = Boolean(video?.isAnimated)
      return {
        ...content,
        media: {
          kind: "video",
          mediaKey: `video:${video?.id.toString() ?? "unknown"}`,
          remoteUrl: video?.cdnUrl,
          posterKey: poster
            ? `photo:${video?.photo?.id.toString() ?? "unknown"}:${poster.type}`
            : undefined,
          posterUrl: poster?.cdnUrl,
          tinyThumbnailUrl: inlineTinyThumbnailDataUrl(
            tinyThumbnail?.bytes,
          ),
          ...dimensions,
          duration: video?.duration || undefined,
          animated,
          label: animated ? "Animation" : "Video",
        },
      }
    }
    case "document": {
      const document = media.document.document
      const fileName = document?.fileName?.trim() || "File"
      return {
        ...content,
        media: {
          kind: "document",
          mediaKey: `document:${document?.id.toString() ?? "unknown"}`,
          remoteUrl: document?.cdnUrl,
          fileName,
          mimeType: document?.mimeType || undefined,
          size: document?.size || undefined,
          label: fileName,
        },
      }
    }
    case "voice": {
      const voice = media.voice.voice
      return {
        ...content,
        media: {
          kind: "voice",
          duration: voice?.duration || undefined,
          waveform: voice ? Array.from(voice.waveform) : [],
          label: "Voice message",
        },
      }
    }
    case "nudge":
      return { ...content, media: { kind: "nudge", label: "Nudge" } }
  }

  switch (message.serviceMessage?.event.oneofKind) {
    case "threadBacklink":
      return {
        service: message.serviceMessage.event.threadBacklink.sourceTitle
          ? `Thread from ${message.serviceMessage.event.threadBacklink.sourceTitle}`
          : "Thread backlink",
      }
    case "pinnedMessage":
      return { service: "Pinned a message" }
  }

  if (text || attachments.length > 0) return content
  return { fallback: "Unsupported message" }
}

export const messageContentLabel = (message: Message) => {
  const presentation = makeMessagePresentation(message)
  const attachment = presentation.attachments?.at(0)
  return (
    presentation.text ??
    presentation.media?.label ??
    presentation.service ??
    (attachment?.kind === "urlPreview" ||
    attachment?.kind === "externalTask"
      ? attachment.title
      : attachment?.label) ??
    presentation.fallback ??
    "Unsupported message"
  )
}
