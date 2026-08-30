import {
  UrlPreview_MediaType,
  type ResolveUrlPreviewInput,
  type ResolveUrlPreviewResult,
  type UrlPreviewMedia,
} from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel } from "@in/server/db/models/files"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import {
  resolveUrlPreview,
  type ResolvedUrlPreview,
} from "@in/server/modules/urlPreview/processUrlPreview"
import { resolveUrlPreviewSubstitution } from "@in/server/modules/urlPreview/substitution"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

const resolveLimiter = new InMemoryRateLimiter({ capacity: 10_000 })

export async function resolveUrlPreviewHandler(
  input: ResolveUrlPreviewInput,
  context: HandlerContext,
): Promise<ResolveUrlPreviewResult> {
  if (!input.url.trim() || (!input.peerId && context.isBot)) {
    throw RealtimeRpcError.UrlPreviewUnavailable()
  }

  const rate = resolveLimiter.consume({
    key: `resolve-url-preview:${context.userId}`,
    nowMs: Date.now(),
    rule: { max: 30, windowMs: 60_000 },
  })
  if (!rate.allowed) {
    throw RealtimeRpcError.RateLimit()
  }

  const chat = input.peerId
    ? await ChatModel.getChatFromInputPeer(input.peerId, { currentUserId: context.userId })
    : undefined
  if (chat) await AccessGuards.ensureChatAccess(chat, context.userId)

  const resolved = await resolveUrlPreview({
    url: input.url,
    ...(chat ? { chatId: chat.id, spaceId: chat.spaceId } : {}),
    currentUserId: context.userId,
  })
  if (!resolved?.metadata.title?.trim()) {
    throw RealtimeRpcError.UrlPreviewUnavailable()
  }
  const substitution = resolveUrlPreviewSubstitution(resolved.metadata)

  const [photo, authorPhoto] = await Promise.all([
    resolved.photoId ? FileModel.getPhotoById(BigInt(resolved.photoId)).catch(() => undefined) : undefined,
    resolved.authorPhotoId
      ? FileModel.getPhotoById(BigInt(resolved.authorPhotoId)).catch(() => undefined)
      : undefined,
  ])

  return {
    urlPreview: {
      id: 0n,
      url: resolved.metadata.url,
      displayUrl: displayUrl(resolved.metadata.url),
      siteName: resolved.metadata.siteName,
      title: substitution.canSubstitute ? substitution.title : resolved.metadata.title,
      description: resolved.metadata.description,
      photo: photo ? encodePhoto({ photo }) : undefined,
      duration: resolved.metadata.duration == null ? undefined : BigInt(resolved.metadata.duration),
      mediaType: encodeMediaType(resolved.metadata.mediaType),
      provider: resolved.metadata.provider,
      author: resolved.metadata.author,
      media: encodeMedia(resolved, photo ? encodePhoto({ photo }) : undefined),
      layout: resolved.metadata.layout,
      authorPhoto: authorPhoto ? encodePhoto({ photo: authorPhoto }) : undefined,
      iconEmoji: resolved.metadata.iconEmoji,
    },
    canSubstitute: substitution.canSubstitute,
  }
}

function encodeMediaType(value: ResolvedUrlPreview["metadata"]["mediaType"]): UrlPreview_MediaType | undefined {
  switch (value) {
    case "article": return UrlPreview_MediaType.ARTICLE
    case "image": return UrlPreview_MediaType.IMAGE
    case "video": return UrlPreview_MediaType.VIDEO
    case "document": return UrlPreview_MediaType.DOCUMENT
    case "embed": return UrlPreview_MediaType.EMBED
    default: return undefined
  }
}

function encodeMedia(
  resolved: ResolvedUrlPreview,
  photo: ReturnType<typeof encodePhoto> | undefined,
): UrlPreviewMedia | undefined {
  const media = resolved.metadata.media
  switch (media?.kind) {
    case "photo":
      return photo ? { media: { oneofKind: "photo", photo } } : undefined
    case "external_video":
      return {
        media: {
          oneofKind: "externalVideo",
          externalVideo: {
            url: media.url,
            mimeType: media.mimeType,
            w: media.width,
            h: media.height,
            duration: media.duration,
          },
        },
      }
    case "embed":
      return {
        media: {
          oneofKind: "embed",
          embed: {
            url: media.url,
            type: media.embedType,
            w: media.width,
            h: media.height,
            duration: media.duration,
          },
        },
      }
    default:
      return undefined
  }
}

function displayUrl(url: string): string | undefined {
  try {
    return new URL(url).hostname.replace(/^www\./i, "")
  } catch {
    return undefined
  }
}
