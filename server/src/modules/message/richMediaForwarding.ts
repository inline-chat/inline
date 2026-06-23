import { type RichBlock, type RichMediaRef, type RichMessage } from "@inline-chat/protocol/core"
import { FileModel } from "@in/server/db/models/files"
import { getSignedMediaPhotoUrl, getSignedUrl } from "@in/server/modules/files/path"

type ClonedRichMediaIdentity = {
  media: RichMediaRef["media"]
  cdnUrl?: string
  fileUniqueId?: string
  mimeType?: string
}

export const cloneRichTextMediaForForward = async (
  richText: RichMessage | null | undefined,
  currentUserId: number,
): Promise<RichMessage | undefined> => {
  if (!richText) {
    return undefined
  }

  const cache = new Map<string, Promise<ClonedRichMediaIdentity>>()
  return {
    ...richText,
    blocks: await cloneBlocks(richText.blocks ?? [], currentUserId, cache),
  }
}

const cloneBlocks = async (
  blocks: RichBlock[],
  currentUserId: number,
  cache: Map<string, Promise<ClonedRichMediaIdentity>>,
): Promise<RichBlock[]> => Promise.all(blocks.map((block) => cloneBlock(block, currentUserId, cache)))

const cloneBlock = async (
  block: RichBlock,
  currentUserId: number,
  cache: Map<string, Promise<ClonedRichMediaIdentity>>,
): Promise<RichBlock> => {
  switch (block.block.oneofKind) {
    case "photo":
      return {
        ...block,
        block: {
          oneofKind: "photo",
          photo: {
            ...block.block.photo,
            media: await cloneRef(block.block.photo.media, currentUserId, cache),
          },
        },
      }
    case "video":
      return {
        ...block,
        block: {
          oneofKind: "video",
          video: {
            ...block.block.video,
            media: await cloneRef(block.block.video.media, currentUserId, cache),
          },
        },
      }
    case "document":
      return {
        ...block,
        block: {
          oneofKind: "document",
          document: {
            ...block.block.document,
            media: await cloneRef(block.block.document.media, currentUserId, cache),
          },
        },
      }
    case "audio":
      return {
        ...block,
        block: {
          oneofKind: "audio",
          audio: {
            ...block.block.audio,
            media: await cloneRef(block.block.audio.media, currentUserId, cache),
          },
        },
      }
    case "embed":
      return {
        ...block,
        block: {
          oneofKind: "embed",
          embed: {
            ...block.block.embed,
            poster: await cloneRef(block.block.embed.poster, currentUserId, cache),
          },
        },
      }
    case "embedPost":
      return {
        ...block,
        block: {
          oneofKind: "embedPost",
          embedPost: {
            ...block.block.embedPost,
            authorPhoto: await cloneRef(block.block.embedPost.authorPhoto, currentUserId, cache),
            blocks: await cloneBlocks(block.block.embedPost.blocks ?? [], currentUserId, cache),
          },
        },
      }
    case "linkPreview":
      return {
        ...block,
        block: {
          oneofKind: "linkPreview",
          linkPreview: {
            ...block.block.linkPreview,
            media: await cloneRef(block.block.linkPreview.media, currentUserId, cache),
          },
        },
      }
    case "collage":
      return {
        ...block,
        block: {
          oneofKind: "collage",
          collage: {
            ...block.block.collage,
            items: await cloneBlocks(block.block.collage.items ?? [], currentUserId, cache),
          },
        },
      }
    case "list":
      return {
        ...block,
        block: {
          oneofKind: "list",
          list: {
            ...block.block.list,
            items: await Promise.all(
              (block.block.list.items ?? []).map(async (item) => ({
                ...item,
                blocks: await cloneBlocks(item.blocks ?? [], currentUserId, cache),
              })),
            ),
          },
        },
      }
    case "listItem":
      return {
        ...block,
        block: {
          oneofKind: "listItem",
          listItem: {
            ...block.block.listItem,
            blocks: await cloneBlocks(block.block.listItem.blocks ?? [], currentUserId, cache),
          },
        },
      }
    case "quote":
      return {
        ...block,
        block: {
          oneofKind: "quote",
          quote: {
            ...block.block.quote,
            blocks: await cloneBlocks(block.block.quote.blocks ?? [], currentUserId, cache),
          },
        },
      }
    case "details":
      return {
        ...block,
        block: {
          oneofKind: "details",
          details: {
            ...block.block.details,
            blocks: await cloneBlocks(block.block.details.blocks ?? [], currentUserId, cache),
          },
        },
      }
    case "thinking":
      return {
        ...block,
        block: {
          oneofKind: "thinking",
          thinking: {
            ...block.block.thinking,
            blocks: await cloneBlocks(block.block.thinking.blocks ?? [], currentUserId, cache),
          },
        },
      }
    default:
      return block
  }
}

const cloneRef = async (
  ref: RichMediaRef | undefined,
  currentUserId: number,
  cache: Map<string, Promise<ClonedRichMediaIdentity>>,
): Promise<RichMediaRef | undefined> => {
  if (!ref) {
    return undefined
  }

  const cloned = await cloneIdentity(ref, currentUserId, cache)
  if (!cloned) {
    return { ...ref }
  }

  return {
    ...ref,
    media: cloned.media,
    cdnUrl: cloned.cdnUrl,
    fileUniqueId: cloned.fileUniqueId,
    mimeType: ref.mimeType ?? cloned.mimeType,
  }
}

const cloneIdentity = async (
  ref: RichMediaRef,
  currentUserId: number,
  cache: Map<string, Promise<ClonedRichMediaIdentity>>,
): Promise<ClonedRichMediaIdentity | undefined> => {
  const kind = ref.media.oneofKind
  if (!kind || kind === "publicUrl") {
    return undefined
  }

  const sourceId = sourceIdForRef(ref)
  if (sourceId === undefined) {
    return undefined
  }

  const cacheKey = `${kind}:${sourceId}`
  const cached = cache.get(cacheKey)
  if (cached) {
    return cached
  }

  const cloned = cloneIdentityByKind(kind, sourceId, currentUserId)
  cache.set(cacheKey, cloned)
  return cloned
}

const sourceIdForRef = (ref: RichMediaRef): number | undefined => {
  switch (ref.media.oneofKind) {
    case "photoId":
      return Number(ref.media.photoId)
    case "videoId":
      return Number(ref.media.videoId)
    case "documentId":
      return Number(ref.media.documentId)
    case "voiceId":
      return Number(ref.media.voiceId)
    default:
      return undefined
  }
}

const cloneIdentityByKind = async (
  kind: NonNullable<RichMediaRef["media"]["oneofKind"]>,
  sourceId: number,
  currentUserId: number,
): Promise<ClonedRichMediaIdentity> => {
  switch (kind) {
    case "photoId": {
      const photoId = await FileModel.clonePhotoById(sourceId, currentUserId)
      const photo = await FileModel.getPhotoById(BigInt(photoId)).catch(() => undefined)
      const file = photo?.photoSizes?.find((size) => size.file)?.file
      return {
        media: { oneofKind: "photoId", photoId: BigInt(photoId) },
        cdnUrl: file ? (getSignedMediaPhotoUrl(file) ?? undefined) : undefined,
        fileUniqueId: file?.fileUniqueId,
        mimeType: file?.mimeType ?? undefined,
      }
    }
    case "videoId": {
      const videoId = await FileModel.cloneVideoById(sourceId, currentUserId)
      const video = await FileModel.getVideoById(BigInt(videoId)).catch(() => undefined)
      return {
        media: { oneofKind: "videoId", videoId: BigInt(videoId) },
        cdnUrl: video?.file.path ? (getSignedUrl(video.file.path) ?? undefined) : undefined,
        fileUniqueId: video?.file.fileUniqueId,
        mimeType: video?.file.mimeType ?? undefined,
      }
    }
    case "documentId": {
      const documentId = await FileModel.cloneDocumentById(sourceId, currentUserId)
      const document = await FileModel.getDocumentById(BigInt(documentId)).catch(() => undefined)
      return {
        media: { oneofKind: "documentId", documentId: BigInt(documentId) },
        cdnUrl: document?.file.path ? (getSignedUrl(document.file.path) ?? undefined) : undefined,
        fileUniqueId: document?.file.fileUniqueId,
        mimeType: document?.file.mimeType ?? undefined,
      }
    }
    case "voiceId": {
      const voiceId = await FileModel.cloneVoiceById(sourceId, currentUserId)
      const voice = await FileModel.getVoiceById(BigInt(voiceId)).catch(() => undefined)
      return {
        media: { oneofKind: "voiceId", voiceId: BigInt(voiceId) },
        cdnUrl: voice?.file.path ? (getSignedUrl(voice.file.path) ?? undefined) : undefined,
        fileUniqueId: voice?.file.fileUniqueId,
        mimeType: voice?.file.mimeType ?? undefined,
      }
    }
    default:
      return { media: { oneofKind: undefined } }
  }
}
