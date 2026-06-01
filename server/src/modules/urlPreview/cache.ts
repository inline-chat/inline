import { createHash } from "node:crypto"

import { normalizePreviewUrl, type UrlPreviewResult } from "@inline-chat/url-preview"
import { db } from "@in/server/db"
import { urlPreviewCache, type DbUrlPreviewCache, type DbNewUrlPreviewCache } from "@in/server/db/schema"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import type { EncryptedData } from "@in/server/modules/encryption/encryption"
import { and, desc, eq, gt, isNotNull } from "drizzle-orm"

const cacheTtlMs = 7 * 24 * 60 * 60 * 1000

export function hashPreviewUrl(url: string): Buffer {
  return createHash("sha256").update(url).digest()
}

export async function getFreshPreviewCache(url: string, now = new Date()): Promise<DbUrlPreviewCache | null> {
  const normalized = normalizePreviewUrl(url)
  if (!normalized) {
    return null
  }

  const [cache] = await db
    .select()
    .from(urlPreviewCache)
    .where(and(eq(urlPreviewCache.urlHash, hashPreviewUrl(normalized)), gt(urlPreviewCache.expiresAt, now)))
    .limit(1)

  return cache ?? null
}

export async function touchPreviewCache(cacheId: number, now = new Date()): Promise<void> {
  await db
    .update(urlPreviewCache)
    .set({
      lastUsedAt: now,
      updatedAt: now,
    })
    .where(eq(urlPreviewCache.id, cacheId))
}

export async function getCachedPreviewPhotoId(imageUrl: string | undefined): Promise<number | null> {
  const normalized = imageUrl ? normalizePreviewUrl(imageUrl) : null
  if (!normalized) {
    return null
  }

  const [cache] = await db
    .select({
      id: urlPreviewCache.id,
      photoId: urlPreviewCache.photoId,
    })
    .from(urlPreviewCache)
    .where(and(eq(urlPreviewCache.imageUrlHash, hashPreviewUrl(normalized)), isNotNull(urlPreviewCache.photoId)))
    .orderBy(desc(urlPreviewCache.lastUsedAt))
    .limit(1)

  if (cache?.id) {
    await touchPreviewCache(cache.id)
  }

  return cache?.photoId ?? null
}

export async function upsertPreviewCache(input: {
  metadata: UrlPreviewResult
  photoId: number | null
  now?: Date
}): Promise<DbUrlPreviewCache> {
  const now = input.now ?? new Date()
  const values = buildCacheValues(input.metadata, input.photoId, now)

  const [cache] = await db
    .insert(urlPreviewCache)
    .values(values)
    .onConflictDoUpdate({
      target: urlPreviewCache.urlHash,
      set: {
        url: values.url,
        urlIv: values.urlIv,
        urlTag: values.urlTag,
        finalUrl: values.finalUrl,
        finalUrlIv: values.finalUrlIv,
        finalUrlTag: values.finalUrlTag,
        provider: values.provider,
        siteName: values.siteName,
        mediaType: values.mediaType,
        title: values.title,
        titleIv: values.titleIv,
        titleTag: values.titleTag,
        description: values.description,
        descriptionIv: values.descriptionIv,
        descriptionTag: values.descriptionTag,
        author: values.author,
        authorIv: values.authorIv,
        authorTag: values.authorTag,
        imageUrlHash: values.imageUrlHash,
        imageUrl: values.imageUrl,
        imageUrlIv: values.imageUrlIv,
        imageUrlTag: values.imageUrlTag,
        mediaKind: values.mediaKind,
        photoId: values.photoId,
        videoId: values.videoId,
        documentId: values.documentId,
        externalUrl: values.externalUrl,
        externalUrlIv: values.externalUrlIv,
        externalUrlTag: values.externalUrlTag,
        externalMimeType: values.externalMimeType,
        externalWidth: values.externalWidth,
        externalHeight: values.externalHeight,
        externalDuration: values.externalDuration,
        embedUrl: values.embedUrl,
        embedUrlIv: values.embedUrlIv,
        embedUrlTag: values.embedUrlTag,
        embedType: values.embedType,
        embedWidth: values.embedWidth,
        embedHeight: values.embedHeight,
        embedDuration: values.embedDuration,
        hasLargeMedia: values.hasLargeMedia,
        showLargeMedia: values.showLargeMedia,
        duration: values.duration,
        fetchedAt: values.fetchedAt,
        lastUsedAt: values.lastUsedAt,
        expiresAt: values.expiresAt,
        updatedAt: values.updatedAt,
      },
    })
    .returning()

  if (!cache) {
    throw new Error("URL preview cache upsert returned no row")
  }

  return cache
}

function buildCacheValues(metadata: UrlPreviewResult, photoId: number | null, now: Date): DbNewUrlPreviewCache {
  const url = normalizePreviewUrl(metadata.url)
  if (!url) {
    throw new Error("Cannot cache invalid URL preview URL")
  }

  const finalUrl = metadata.finalUrl ? normalizePreviewUrl(metadata.finalUrl) : null
  const imageUrl = metadata.imageUrl ? normalizePreviewUrl(metadata.imageUrl) : null
  const encryptedUrl = encryptRequired(url)
  const encryptedFinalUrl = finalUrl ? encryptMessage(finalUrl) : null
  const encryptedTitle = metadata.title ? encryptMessage(metadata.title) : null
  const encryptedDescription = metadata.description ? encryptMessage(metadata.description) : null
  const encryptedAuthor = metadata.author ? encryptMessage(metadata.author) : null
  const encryptedImageUrl = imageUrl ? encryptMessage(imageUrl) : null
  const externalUrl = metadata.media?.kind === "external_video" ? normalizePreviewUrl(metadata.media.url) : null
  const embedUrl = metadata.media?.kind === "embed" ? normalizePreviewUrl(metadata.media.url) : null
  const encryptedExternalUrl = externalUrl ? encryptMessage(externalUrl) : null
  const encryptedEmbedUrl = embedUrl ? encryptMessage(embedUrl) : null
  const mediaKind = cacheMediaKind(metadata, { photoId, externalUrl, embedUrl })

  return {
    urlHash: hashPreviewUrl(url),
    url: encryptedUrl.encrypted,
    urlIv: encryptedUrl.iv,
    urlTag: encryptedUrl.authTag,
    finalUrl: encryptedFinalUrl?.encrypted ?? null,
    finalUrlIv: encryptedFinalUrl?.iv ?? null,
    finalUrlTag: encryptedFinalUrl?.authTag ?? null,
    provider: metadata.provider,
    siteName: metadata.siteName ?? null,
    mediaType: metadata.mediaType ?? null,
    title: encryptedTitle?.encrypted ?? null,
    titleIv: encryptedTitle?.iv ?? null,
    titleTag: encryptedTitle?.authTag ?? null,
    description: encryptedDescription?.encrypted ?? null,
    descriptionIv: encryptedDescription?.iv ?? null,
    descriptionTag: encryptedDescription?.authTag ?? null,
    author: encryptedAuthor?.encrypted ?? null,
    authorIv: encryptedAuthor?.iv ?? null,
    authorTag: encryptedAuthor?.authTag ?? null,
    imageUrlHash: imageUrl ? hashPreviewUrl(imageUrl) : null,
    imageUrl: encryptedImageUrl?.encrypted ?? null,
    imageUrlIv: encryptedImageUrl?.iv ?? null,
    imageUrlTag: encryptedImageUrl?.authTag ?? null,
    mediaKind,
    photoId,
    videoId: null,
    documentId: null,
    externalUrl: encryptedExternalUrl?.encrypted ?? null,
    externalUrlIv: encryptedExternalUrl?.iv ?? null,
    externalUrlTag: encryptedExternalUrl?.authTag ?? null,
    externalMimeType: metadata.media?.kind === "external_video" ? (metadata.media.mimeType ?? null) : null,
    externalWidth: metadata.media?.kind === "external_video" ? (metadata.media.width ?? null) : null,
    externalHeight: metadata.media?.kind === "external_video" ? (metadata.media.height ?? null) : null,
    externalDuration: metadata.media?.kind === "external_video" ? (metadata.media.duration ?? null) : null,
    embedUrl: encryptedEmbedUrl?.encrypted ?? null,
    embedUrlIv: encryptedEmbedUrl?.iv ?? null,
    embedUrlTag: encryptedEmbedUrl?.authTag ?? null,
    embedType: metadata.media?.kind === "embed" ? (metadata.media.embedType ?? null) : null,
    embedWidth: metadata.media?.kind === "embed" ? (metadata.media.width ?? null) : null,
    embedHeight: metadata.media?.kind === "embed" ? (metadata.media.height ?? null) : null,
    embedDuration: metadata.media?.kind === "embed" ? (metadata.media.duration ?? null) : null,
    hasLargeMedia: metadata.layout?.hasLargeMedia ?? null,
    showLargeMedia: metadata.layout?.showLargeMedia ?? null,
    duration: metadata.duration ?? null,
    fetchedAt: now,
    lastUsedAt: now,
    expiresAt: new Date(now.getTime() + cacheTtlMs),
    createdAt: now,
    updatedAt: now,
  }
}

function cacheMediaKind(
  metadata: UrlPreviewResult,
  media: { photoId: number | null; externalUrl: string | null; embedUrl: string | null },
): DbNewUrlPreviewCache["mediaKind"] {
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

function encryptRequired(value: string): EncryptedData {
  const encrypted = encryptMessage(value)
  if (!encrypted.encrypted || !encrypted.iv || !encrypted.authTag) {
    throw new Error("Failed to encrypt required URL preview cache field")
  }
  return encrypted
}
