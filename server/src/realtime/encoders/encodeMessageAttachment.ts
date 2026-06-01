import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodePeerFromInputPeer } from "./encodePeer"
import {
  InputPeer,
  MessageAttachment,
  Update,
  UrlPreview_MediaType,
  type UrlPreviewLayout,
  type UrlPreviewMedia,
} from "@inline-chat/protocol/core"
import type { ProcessedMessageAttachment } from "@in/server/db/models/messages"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { encodeVideo } from "@in/server/realtime/encoders/encodeVideo"
import { encodeDocument } from "@in/server/realtime/encoders/encodeDocument"

export const encodeMessageAttachmentUpdate = ({
  messageId,
  chatId,
  encodingForUserId,
  encodingForPeer,
  attachment,
  seq,
  date,
}: {
  messageId: bigint
  chatId: bigint
  encodingForUserId: number
  encodingForPeer: { inputPeer: InputPeer }
  attachment: MessageAttachment
  seq?: number
  date?: Date
}): Update => {
  let update: Update = {
    seq,
    date: date ? encodeDateStrict(date) : undefined,
    update: {
      oneofKind: "messageAttachment",
      messageAttachment: {
        messageId,
        chatId,
        peerId: encodePeerFromInputPeer({
          inputPeer: encodingForPeer.inputPeer,
          currentUserId: encodingForUserId,
        }),
        attachment,
      },
    },
  }

  return update
}

export const encodeMessageAttachment = (attachment: ProcessedMessageAttachment): MessageAttachment | null => {
  if (attachment.externalTask) {
    const statusMap: Record<string, number> = {
      backlog: 1,
      todo: 2,
      in_progress: 3,
      done: 4,
      cancelled: 5,
    }

    return {
      id: BigInt(attachment.id ?? 0),
      attachment: {
        oneofKind: "externalTask",
        externalTask: {
          id: BigInt(attachment.externalTask.id),
          taskId: attachment.externalTask.taskId ?? "",
          application: attachment.externalTask.application ?? "",
          title: attachment.externalTask.title ?? "",
          status: statusMap[attachment.externalTask.status ?? ""] ?? 0,
          assignedUserId: BigInt(attachment.externalTask.assignedUserId ?? 0),
          url: attachment.externalTask.url ?? "",
          number: attachment.externalTask.number ?? "",
          date: encodeDateStrict(attachment.externalTask.date),
        },
      },
    }
  }

  if (attachment.linkEmbed) {
    return {
      id: BigInt(attachment.id ?? 0),
      attachment: {
        oneofKind: "urlPreview",
        urlPreview: {
          id: BigInt(attachment.linkEmbed.id),
          url: attachment.linkEmbed.url ?? undefined,
          siteName: attachment.linkEmbed.siteName ?? undefined,
          title: attachment.linkEmbed.title ?? undefined,
          description: attachment.linkEmbed.description ?? undefined,
          photo: attachment.linkEmbed.photo ? encodePhoto({ photo: attachment.linkEmbed.photo }) : undefined,
          duration: attachment.linkEmbed.duration == null ? undefined : BigInt(attachment.linkEmbed.duration),
          mediaType: encodeUrlPreviewMediaType(
            attachment.linkEmbed.mediaType ?? mediaTypeFromMediaKind(attachment.linkEmbed.mediaKind),
          ),
          displayUrl: displayUrl(attachment.linkEmbed.url),
          provider: attachment.linkEmbed.provider ?? undefined,
          author: attachment.linkEmbed.author ?? undefined,
          media: encodeUrlPreviewMedia(attachment.linkEmbed),
          layout: encodeUrlPreviewLayout(attachment.linkEmbed),
        },
      },
    }
  }

  return null
}

function encodeUrlPreviewMediaType(mediaType: string | null | undefined): UrlPreview_MediaType | undefined {
  switch (mediaType) {
    case "article":
      return UrlPreview_MediaType.ARTICLE
    case "image":
      return UrlPreview_MediaType.IMAGE
    case "video":
      return UrlPreview_MediaType.VIDEO
    case "document":
      return UrlPreview_MediaType.DOCUMENT
    case "embed":
      return UrlPreview_MediaType.EMBED
    default:
      return undefined
  }
}

function mediaTypeFromMediaKind(mediaKind: string | null | undefined): string | null {
  switch (mediaKind) {
    case "photo":
      return "image"
    case "video":
    case "external_video":
      return "video"
    case "document":
      return "document"
    case "embed":
      return "video"
    default:
      return null
  }
}

function encodeUrlPreviewMedia(
  preview: NonNullable<ProcessedMessageAttachment["linkEmbed"]>,
): UrlPreviewMedia | undefined {
  switch (preview.mediaKind) {
    case "photo":
      return preview.photo
        ? {
            media: {
              oneofKind: "photo",
              photo: encodePhoto({ photo: preview.photo }),
            },
          }
        : undefined
    case "video":
      return preview.video
        ? {
            media: {
              oneofKind: "video",
              video: encodeVideo({ video: preview.video }),
            },
          }
        : undefined
    case "document":
      return preview.document
        ? {
            media: {
              oneofKind: "document",
              document: encodeDocument({ document: preview.document }),
            },
          }
        : undefined
    case "external_video":
      return preview.externalUrl
        ? {
            media: {
              oneofKind: "externalVideo",
              externalVideo: {
                url: preview.externalUrl,
                mimeType: preview.externalMimeType ?? undefined,
                w: preview.externalWidth ?? undefined,
                h: preview.externalHeight ?? undefined,
                duration: preview.externalDuration ?? undefined,
              },
            },
          }
        : undefined
    case "embed":
      return preview.embedUrl
        ? {
            media: {
              oneofKind: "embed",
              embed: {
                url: preview.embedUrl,
                type: preview.embedType ?? undefined,
                w: preview.embedWidth ?? undefined,
                h: preview.embedHeight ?? undefined,
                duration: preview.embedDuration ?? undefined,
              },
            },
          }
        : undefined
    default:
      return undefined
  }
}

function encodeUrlPreviewLayout(
  preview: NonNullable<ProcessedMessageAttachment["linkEmbed"]>,
): UrlPreviewLayout | undefined {
  if (preview.hasLargeMedia == null && preview.showLargeMedia == null) {
    return undefined
  }

  return {
    hasLargeMedia: preview.hasLargeMedia ?? false,
    showLargeMedia: preview.showLargeMedia ?? false,
  }
}

function displayUrl(url: string | null | undefined): string | undefined {
  if (!url) {
    return undefined
  }

  try {
    const parsed = new URL(url)
    return parsed.hostname.replace(/^www\./i, "")
  } catch {
    return undefined
  }
}
