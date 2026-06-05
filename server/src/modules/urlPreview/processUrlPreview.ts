import {
  extractPreviewRoutes,
  extractPreviewUrls,
  fetchAuthenticatedUrlPreview,
  fetchBinary,
  fetchUrlPreview,
  normalizePreviewUrl,
  type PreviewRoute,
  type UrlPreviewResult,
} from "@inline-chat/url-preview"
import {
  MessageEntity_Type,
  type InputPeer,
  type MessageAttachment,
  type MessageEntities,
  type Update,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { MessageModel, type ProcessedMessageAttachment } from "@in/server/db/models/messages"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import {
  chats,
  messageAttachments,
  messages,
  urlPreview,
  type DbMessage,
  type DbUrlPreviewCache,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import {
  getCachedPreviewPhotoId,
  getFreshPreviewCache,
  touchPreviewCache,
  upsertPreviewCache,
} from "@in/server/modules/urlPreview/cache"
import { resolvePreviewAuth } from "@in/server/modules/urlPreview/auth"
import {
  encodeMessageAttachment,
  encodeMessageAttachmentUpdate,
} from "@in/server/realtime/encoders/encodeMessageAttachment"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { connectionManager } from "@in/server/ws/connections"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import sharp from "sharp"

const log = new Log("modules.urlPreview")

type ProcessUrlPreviewInput = {
  message: DbMessage
  previewUrl?: string
  previewRoute?: PreviewRoute
  chatId: number
  currentUserId: number
  inputPeer: InputPeer
}

type InsertPreviewOutput = {
  attachmentId: number
  update: UpdateSeqAndDate
}

type PreviewMediaKind = NonNullable<UrlPreviewResult["media"]>["kind"] | "video"

type PreviewAttachmentSource = {
  url: Buffer | null
  urlIv: Buffer | null
  urlTag: Buffer | null
  siteName: string | null
  provider: string
  mediaType: UrlPreviewResult["mediaType"] | null
  title: Buffer | null
  titleIv: Buffer | null
  titleTag: Buffer | null
  description: Buffer | null
  descriptionIv: Buffer | null
  descriptionTag: Buffer | null
  author: Buffer | null
  authorIv: Buffer | null
  authorTag: Buffer | null
  mediaKind: PreviewMediaKind | null
  photoId: number | null
  videoId: number | null
  documentId: number | null
  externalUrl: Buffer | null
  externalUrlIv: Buffer | null
  externalUrlTag: Buffer | null
  externalMimeType: string | null
  externalWidth: number | null
  externalHeight: number | null
  externalDuration: number | null
  embedUrl: Buffer | null
  embedUrlIv: Buffer | null
  embedUrlTag: Buffer | null
  embedType: string | null
  embedWidth: number | null
  embedHeight: number | null
  embedDuration: number | null
  hasLargeMedia: boolean | null
  showLargeMedia: boolean | null
  cacheId: number | null
  duration: number | null
}

const maxDescriptionLength = 220
const maxTitleLength = 180
const maxSiteNameLength = 80
const maxPreviewUrls = 3
const maxImageBytes = 5 * 1024 * 1024
const maxImagePixels = 16_000_000
const maxImageWidth = 800
const maxImageHeight = 450
const jpegQuality = 82
const maxConcurrentPreviewJobs = 8
const maxQueuedPreviewJobs = 256
const previewImageTypes = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
  "image/mjpeg",
  "multipart/x-mixed-replace",
]

let activePreviewJobs = 0
const queuedPreviewJobs: Array<() => void> = []

export function getPreviewUrlFromMessage(text: string, entities?: MessageEntities | null): string | null {
  return getPreviewUrlsFromMessage(text, entities)[0] ?? null
}

export function getPreviewUrlsFromMessage(text: string, entities?: MessageEntities | null): string[] {
  return extractPreviewUrls(text, collectEntityUrls(text, entities), { limit: maxPreviewUrls })
}

export function getPreviewRoutesFromMessage(text: string, entities?: MessageEntities | null): PreviewRoute[] {
  return extractPreviewRoutes(text, collectEntityUrls(text, entities), { limit: maxPreviewUrls })
}

export async function processUrlPreviews(
  input: Omit<ProcessUrlPreviewInput, "previewUrl" | "previewRoute"> & {
    previewUrls?: string[]
    previewRoutes?: PreviewRoute[]
  },
): Promise<void> {
  const routes = input.previewRoutes ?? input.previewUrls?.map(generalPreviewRoute) ?? []
  for (const previewRoute of routes.slice(0, maxPreviewUrls)) {
    await processUrlPreview({ ...input, previewRoute })
  }
}

export async function processUrlPreview(input: ProcessUrlPreviewInput): Promise<void> {
  const previewRoute = input.previewRoute ?? (input.previewUrl ? generalPreviewRoute(input.previewUrl) : null)
  if (!previewRoute) {
    return
  }

  const releaseSlot = await acquirePreviewSlot(input)
  if (!releaseSlot) {
    return
  }

  try {
    if (previewRoute.kind === "authenticated") {
      await processAuthenticatedUrlPreview(input, previewRoute)
      return
    }

    const cached = await getFreshPreviewCache(previewRoute.url).catch((error) => {
      log.warn("Failed to read URL preview cache", {
        error,
        url: previewRoute.url,
        messageId: input.message.messageId,
        chatId: input.chatId,
      })
      return null
    })
    if (cached) {
      const inserted = await insertPreviewAttachment(input.message, input.chatId, previewSourceFromCache(cached))
      await touchPreviewCache(cached.id).catch((error) => {
        log.warn("Failed to touch URL preview cache", {
          error,
          cacheId: cached.id,
          messageId: input.message.messageId,
          chatId: input.chatId,
        })
      })
      await pushInsertedPreviewAttachment(input, inserted)
      return
    }

    const metadata = await fetchUrlPreview(previewRoute.url, {
      maxDescriptionLength,
      maxTitleLength,
      maxSiteNameLength,
    })
    if (!metadata) {
      return
    }

    // TODO: Generate and cache poster thumbnails for direct video previews once capture can be safely bounded.
    const photoId = metadata.imageUrl ? await getOrSavePreviewImage(metadata.imageUrl, input.currentUserId) : null
    const cache = await upsertPreviewCache({ metadata, photoId }).catch((error) => {
      log.warn("Failed to write URL preview cache", {
        error,
        url: metadata.url,
        messageId: input.message.messageId,
        chatId: input.chatId,
      })
      return null
    })
    const inserted = await insertPreviewAttachment(
      input.message,
      input.chatId,
      previewSourceFromMetadata(metadata, photoId, cache?.id ?? null),
    )
    await pushInsertedPreviewAttachment(input, inserted)
  } catch (error) {
    log.warn("Failed to process URL preview", {
      error,
      url: previewRouteUrl(previewRoute),
      messageId: input.message.messageId,
      chatId: input.chatId,
    })
  } finally {
    releaseSlot()
  }
}

function generalPreviewRoute(url: string): PreviewRoute {
  return { kind: "general", url }
}

async function processAuthenticatedUrlPreview(
  input: ProcessUrlPreviewInput,
  previewRoute: PreviewRoute & { kind: "authenticated" },
): Promise<void> {
  const auth = await resolvePreviewAuth({
    provider: previewRoute.parsedUrl.provider,
    currentUserId: input.currentUserId,
    chatId: input.chatId,
  })
  if (!auth) {
    return
  }

  const metadata = await fetchAuthenticatedUrlPreview(previewRoute.parsedUrl, auth, {
    maxDescriptionLength,
    maxTitleLength,
    maxSiteNameLength,
  })
  if (!metadata) {
    return
  }

  const photoId = metadata.imageUrl ? await getOrSavePreviewImage(metadata.imageUrl, input.currentUserId) : null
  const inserted = await insertPreviewAttachment(
    input.message,
    input.chatId,
    previewSourceFromMetadata(metadata, photoId, null),
  )
  await pushInsertedPreviewAttachment(input, inserted)
}

function previewRouteUrl(route: PreviewRoute): string {
  return route.kind === "general" ? route.url : route.parsedUrl.normalizedUrl
}

function collectEntityUrls(text: string, entities?: MessageEntities | null): string[] {
  if (!entities?.entities.length) {
    return []
  }

  const urls: string[] = []
  for (const entity of entities.entities) {
    if (entity.type === MessageEntity_Type.TEXT_URL && entity.entity.oneofKind === "textUrl") {
      urls.push(entity.entity.textUrl.url)
      continue
    }

    if (entity.type === MessageEntity_Type.URL) {
      const start = Number(entity.offset)
      const end = start + Number(entity.length)
      if (Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && end > start) {
        urls.push(text.slice(start, end))
      }
    }
  }

  return urls
}

async function insertPreviewAttachment(
  message: DbMessage,
  chatId: number,
  source: PreviewAttachmentSource,
): Promise<InsertPreviewOutput> {
  return await db.transaction(async (tx) => {
    const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)
    if (!chat) {
      throw new Error("Chat not found while inserting URL preview")
    }

    const [preview] = await tx
      .insert(urlPreview)
      .values({
        url: source.url,
        urlIv: source.urlIv,
        urlTag: source.urlTag,
        siteName: source.siteName,
        provider: source.provider,
        mediaType: source.mediaType,
        title: source.title,
        titleIv: source.titleIv,
        titleTag: source.titleTag,
        description: source.description,
        descriptionIv: source.descriptionIv,
        descriptionTag: source.descriptionTag,
        author: source.author,
        authorIv: source.authorIv,
        authorTag: source.authorTag,
        mediaKind: source.mediaKind,
        photoId: source.photoId,
        videoId: source.videoId,
        documentId: source.documentId,
        externalUrl: source.externalUrl,
        externalUrlIv: source.externalUrlIv,
        externalUrlTag: source.externalUrlTag,
        externalMimeType: source.externalMimeType,
        externalWidth: source.externalWidth,
        externalHeight: source.externalHeight,
        externalDuration: source.externalDuration,
        embedUrl: source.embedUrl,
        embedUrlIv: source.embedUrlIv,
        embedUrlTag: source.embedUrlTag,
        embedType: source.embedType,
        embedWidth: source.embedWidth,
        embedHeight: source.embedHeight,
        embedDuration: source.embedDuration,
        hasLargeMedia: source.hasLargeMedia,
        showLargeMedia: source.showLargeMedia,
        ...(source.cacheId !== null ? { cacheId: source.cacheId } : {}),
        duration: source.duration,
        date: new Date(),
      })
      .returning()

    if (!preview) {
      throw new Error("URL preview insert returned no row")
    }

    const [attachment] = await tx
      .insert(messageAttachments)
      .values({
        messageId: message.globalId,
        urlPreviewId: BigInt(preview.id),
        externalTaskId: null,
      })
      .returning()

    if (!attachment) {
      throw new Error("Message attachment insert returned no row")
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "messageAttachment",
        messageAttachment: {
          chatId: BigInt(chatId),
          msgId: BigInt(message.messageId),
          attachmentId: BigInt(attachment.id),
        },
      },
      bucket: UpdateBucket.Chat,
      entity: chat,
    })

    await Promise.all([
      tx
        .update(chats)
        .set({
          updateSeq: update.seq,
          lastUpdateDate: update.date,
        })
        .where(eq(chats.id, chatId)),
      tx
        .update(messages)
        .set({ hasLink: true })
        .where(and(eq(messages.globalId, message.globalId), eq(messages.chatId, chatId))),
    ])

    return { attachmentId: attachment.id, update }
  })
}

function previewSourceFromCache(cache: DbUrlPreviewCache): PreviewAttachmentSource {
  return {
    url: cache.url,
    urlIv: cache.urlIv,
    urlTag: cache.urlTag,
    siteName: cache.siteName,
    provider: cache.provider,
    mediaType: cache.mediaType,
    title: cache.title,
    titleIv: cache.titleIv,
    titleTag: cache.titleTag,
    description: cache.description,
    descriptionIv: cache.descriptionIv,
    descriptionTag: cache.descriptionTag,
    author: cache.author,
    authorIv: cache.authorIv,
    authorTag: cache.authorTag,
    mediaKind: cache.mediaKind,
    photoId: cache.photoId,
    videoId: cache.videoId,
    documentId: cache.documentId,
    externalUrl: cache.externalUrl,
    externalUrlIv: cache.externalUrlIv,
    externalUrlTag: cache.externalUrlTag,
    externalMimeType: cache.externalMimeType,
    externalWidth: cache.externalWidth,
    externalHeight: cache.externalHeight,
    externalDuration: cache.externalDuration,
    embedUrl: cache.embedUrl,
    embedUrlIv: cache.embedUrlIv,
    embedUrlTag: cache.embedUrlTag,
    embedType: cache.embedType,
    embedWidth: cache.embedWidth,
    embedHeight: cache.embedHeight,
    embedDuration: cache.embedDuration,
    hasLargeMedia: cache.hasLargeMedia,
    showLargeMedia: cache.showLargeMedia,
    cacheId: cache.id,
    duration: cache.duration,
  }
}

function previewSourceFromMetadata(
  metadata: UrlPreviewResult,
  photoId: number | null,
  cacheId: number | null,
): PreviewAttachmentSource {
  const urlEncrypted = encryptMessage(metadata.url)
  const titleEncrypted = metadata.title ? encryptMessage(metadata.title) : null
  const descriptionEncrypted = metadata.description ? encryptMessage(metadata.description) : null
  const authorEncrypted = metadata.author ? encryptMessage(metadata.author) : null
  const externalUrl = metadata.media?.kind === "external_video" ? normalizePreviewUrl(metadata.media.url) : null
  const embedUrl = metadata.media?.kind === "embed" ? normalizePreviewUrl(metadata.media.url) : null
  const externalUrlEncrypted = externalUrl ? encryptMessage(externalUrl) : null
  const embedUrlEncrypted = embedUrl ? encryptMessage(embedUrl) : null
  const mediaKind = previewMediaKind(metadata, { photoId, externalUrl, embedUrl })

  return {
    url: urlEncrypted.encrypted,
    urlIv: urlEncrypted.iv,
    urlTag: urlEncrypted.authTag,
    siteName: metadata.siteName ?? null,
    provider: metadata.provider,
    mediaType: metadata.mediaType ?? null,
    title: titleEncrypted?.encrypted ?? null,
    titleIv: titleEncrypted?.iv ?? null,
    titleTag: titleEncrypted?.authTag ?? null,
    description: descriptionEncrypted?.encrypted ?? null,
    descriptionIv: descriptionEncrypted?.iv ?? null,
    descriptionTag: descriptionEncrypted?.authTag ?? null,
    author: authorEncrypted?.encrypted ?? null,
    authorIv: authorEncrypted?.iv ?? null,
    authorTag: authorEncrypted?.authTag ?? null,
    mediaKind,
    photoId,
    videoId: null,
    documentId: null,
    externalUrl: externalUrlEncrypted?.encrypted ?? null,
    externalUrlIv: externalUrlEncrypted?.iv ?? null,
    externalUrlTag: externalUrlEncrypted?.authTag ?? null,
    externalMimeType: metadata.media?.kind === "external_video" ? (metadata.media.mimeType ?? null) : null,
    externalWidth: metadata.media?.kind === "external_video" ? (metadata.media.width ?? null) : null,
    externalHeight: metadata.media?.kind === "external_video" ? (metadata.media.height ?? null) : null,
    externalDuration: metadata.media?.kind === "external_video" ? (metadata.media.duration ?? null) : null,
    embedUrl: embedUrlEncrypted?.encrypted ?? null,
    embedUrlIv: embedUrlEncrypted?.iv ?? null,
    embedUrlTag: embedUrlEncrypted?.authTag ?? null,
    embedType: metadata.media?.kind === "embed" ? (metadata.media.embedType ?? null) : null,
    embedWidth: metadata.media?.kind === "embed" ? (metadata.media.width ?? null) : null,
    embedHeight: metadata.media?.kind === "embed" ? (metadata.media.height ?? null) : null,
    embedDuration: metadata.media?.kind === "embed" ? (metadata.media.duration ?? null) : null,
    hasLargeMedia: metadata.layout?.hasLargeMedia ?? null,
    showLargeMedia: metadata.layout?.showLargeMedia ?? null,
    cacheId,
    duration: metadata.duration ?? null,
  }
}

function previewMediaKind(
  metadata: UrlPreviewResult,
  media: { photoId: number | null; externalUrl: string | null; embedUrl: string | null },
): PreviewAttachmentSource["mediaKind"] {
  switch (metadata.media?.kind) {
    case "photo":
      return media.photoId ? "photo" : null
    case "external_video":
      return media.externalUrl ? "external_video" : null
    case "embed":
      return media.embedUrl ? "embed" : null
    case "document":
      return null
    default:
      return null
  }
}

async function loadProcessedAttachment(attachmentId: number): Promise<ProcessedMessageAttachment | null> {
  const attachment = await db._query.messageAttachments.findFirst({
    where: eq(messageAttachments.id, attachmentId),
    with: {
      externalTask: true,
      linkEmbed: {
        with: {
          photo: {
            with: {
              photoSizes: {
                with: {
                  file: true,
                },
              },
            },
          },
          video: {
            with: {
              file: true,
              photo: {
                with: {
                  photoSizes: {
                    with: {
                      file: true,
                    },
                  },
                },
              },
            },
          },
          document: {
            with: {
              file: true,
              photo: {
                with: {
                  photoSizes: {
                    with: {
                      file: true,
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  })

  if (!attachment) {
    return null
  }

  return MessageModel.processAttachments([attachment])[0] ?? null
}

async function getOrSavePreviewImage(url: string, currentUserId: number): Promise<number | null> {
  const cachedPhotoId = await getCachedPreviewPhotoId(url).catch((error) => {
    log.warn("Failed to read URL preview image cache", { error, url })
    return null
  })
  if (cachedPhotoId) {
    return cachedPhotoId
  }

  return downloadAndSavePreviewImage(url, currentUserId)
}

async function downloadAndSavePreviewImage(url: string, currentUserId: number): Promise<number | null> {
  try {
    const image = await fetchBinary(url, {
      maxBytes: maxImageBytes,
      allowedContentTypes: previewImageTypes,
    })
    if (!image) {
      return null
    }

    const buffer = await resizePreviewImage(Buffer.from(image.bytes))

    const file = new File([buffer], `url_preview_${Date.now()}.jpg`, { type: "image/jpeg" })
    const result = await uploadPhoto(file, { userId: currentUserId })
    return Number(result.photoId)
  } catch (error) {
    log.warn("Failed to download URL preview image", { error, url })
    return null
  }
}

async function pushInsertedPreviewAttachment(
  input: ProcessUrlPreviewInput,
  inserted: InsertPreviewOutput,
): Promise<void> {
  const attachment = await loadProcessedAttachment(inserted.attachmentId)
  if (!attachment) {
    log.warn("URL preview attachment was inserted but could not be loaded", {
      attachmentId: inserted.attachmentId,
      messageId: input.message.messageId,
      chatId: input.chatId,
    })
    return
  }

  const protoAttachment = encodeMessageAttachment(attachment)
  if (!protoAttachment) {
    return
  }

  await pushAttachmentUpdate({
    attachment: protoAttachment,
    message: input.message,
    chatId: input.chatId,
    inputPeer: input.inputPeer,
    currentUserId: input.currentUserId,
    update: inserted.update,
  })
}

async function resizePreviewImage(source: Buffer): Promise<Buffer> {
  return await sharp(source, {
    animated: false,
    limitInputPixels: maxImagePixels,
  })
    .rotate()
    .resize({
      width: maxImageWidth,
      height: maxImageHeight,
      fit: "inside",
      withoutEnlargement: true,
    })
    .flatten({ background: "#ffffff" })
    .jpeg({ quality: jpegQuality, mozjpeg: true })
    .toBuffer()
}

async function pushAttachmentUpdate(input: {
  attachment: MessageAttachment
  message: DbMessage
  chatId: number
  inputPeer: InputPeer
  currentUserId: number
  update: UpdateSeqAndDate
}) {
  const updateGroup = await getUpdateGroupFromInputPeer(input.inputPeer, { currentUserId: input.currentUserId })
  const updateForUser = (userId: number): Update => {
    const encodingForInputPeer: InputPeer =
      updateGroup.type === "dmUsers" && userId !== input.currentUserId
        ? { type: { oneofKind: "user", user: { userId: BigInt(input.currentUserId) } } }
        : input.inputPeer

    return encodeMessageAttachmentUpdate({
      messageId: BigInt(input.message.messageId),
      chatId: BigInt(input.chatId),
      encodingForUserId: userId,
      encodingForPeer: { inputPeer: encodingForInputPeer },
      attachment: input.attachment,
      seq: input.update.seq,
      date: input.update.date,
    })
  }

  publishToUpdateGroup(updateGroup, updateForUser)
}

function publishToUpdateGroup(updateGroup: UpdateGroup, updateForUser: (userId: number) => Update) {
  if (updateGroup.type === "spaceUsers") {
    const userIds = connectionManager.getSpaceUserIds(updateGroup.spaceId)
    userIds.forEach((userId) => RealtimeUpdates.pushToUser(userId, [updateForUser(userId)]))
    return
  }

  updateGroup.userIds.forEach((userId) => {
    RealtimeUpdates.pushToUser(userId, [updateForUser(userId)])
  })
}

async function acquirePreviewSlot(input: ProcessUrlPreviewInput): Promise<(() => void) | null> {
  if (activePreviewJobs < maxConcurrentPreviewJobs) {
    activePreviewJobs += 1
    return releasePreviewSlot
  }

  if (queuedPreviewJobs.length >= maxQueuedPreviewJobs) {
    log.warn("Dropping URL preview because the preview queue is full", {
      url: input.previewRoute ? previewRouteUrl(input.previewRoute) : input.previewUrl,
      messageId: input.message.messageId,
      chatId: input.chatId,
      activePreviewJobs,
      queuedPreviewJobs: queuedPreviewJobs.length,
    })
    return null
  }

  await new Promise<void>((resolve) => {
    queuedPreviewJobs.push(resolve)
  })

  return releasePreviewSlot
}

function releasePreviewSlot() {
  const nextJob = queuedPreviewJobs.shift()
  if (nextJob) {
    nextJob()
    return
  }

  activePreviewJobs = Math.max(0, activePreviewJobs - 1)
}
