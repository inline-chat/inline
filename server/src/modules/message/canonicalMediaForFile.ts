import { documents, files, photos, photoSizes, videos, voices, type DbFile } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, asc, eq, sql } from "drizzle-orm"

type CanonicalMedia = {
  mediaType: "photo" | "video" | "document" | "voice"
  photoId?: number
  videoId?: number
  documentId?: number
  voiceId?: number
}

/** Real asset identities only. A file row is locked to serialize cross-chat reuse. */
export async function canonicalMediaForFile(tx: Transaction, fileId: number): Promise<CanonicalMedia> {
  const [file] = await tx.select().from(files).where(eq(files.id, fileId)).for("update").limit(1)
  if (!file) throw RealtimeRpcError.BadRequest()
  const type = file.fileType ?? (file.mimeType?.startsWith("image/") ? "photo" : "document")
  if (type === "photo") {
    const [existing] = await tx
      .select({ photoId: photoSizes.photoId })
      .from(photoSizes)
      .where(and(eq(photoSizes.fileId, file.id), sql`${photoSizes.photoId} IS NOT NULL`))
      .orderBy(asc(photoSizes.photoId))
      .limit(1)
    if (existing?.photoId != null) return { mediaType: "photo", photoId: existing.photoId }
    const [photo] = await tx
      .insert(photos)
      .values({
        format: file.mimeType === "image/png" ? "png" : "jpeg",
        width: file.width,
        height: file.height,
        date: file.date,
      })
      .returning()
    if (!photo) throw RealtimeRpcError.BadRequest()
    await tx
      .insert(photoSizes)
      .values({ photoId: photo.id, fileId: file.id, size: "f", width: file.width, height: file.height })
    return { mediaType: "photo", photoId: photo.id }
  }
  if (type === "video") {
    const [existing] = await tx
      .select({ id: videos.id })
      .from(videos)
      .where(eq(videos.fileId, file.id))
      .orderBy(asc(videos.id))
      .limit(1)
    if (existing) return { mediaType: "video", videoId: existing.id }
    const [video] = await tx
      .insert(videos)
      .values({
        fileId: file.id,
        date: file.date,
        width: file.width,
        height: file.height,
        duration: finiteDuration(file),
        isAnimated: false,
      })
      .returning()
    if (!video) throw RealtimeRpcError.BadRequest()
    return { mediaType: "video", videoId: video.id }
  }
  if (type === "voice") {
    const [existing] = await tx
      .select({ id: voices.id })
      .from(voices)
      .where(eq(voices.fileId, file.id))
      .orderBy(asc(voices.id))
      .limit(1)
    if (existing) return { mediaType: "voice", voiceId: existing.id }
    const [voice] = await tx
      .insert(voices)
      .values({ fileId: file.id, date: file.date, duration: finiteDuration(file) })
      .returning()
    if (!voice) throw RealtimeRpcError.BadRequest()
    return { mediaType: "voice", voiceId: voice.id }
  }
  const [existing] = await tx
    .select({ id: documents.id })
    .from(documents)
    .where(eq(documents.fileId, file.id))
    .orderBy(asc(documents.id))
    .limit(1)
  if (existing) return { mediaType: "document", documentId: existing.id }
  const [document] = await tx
    .insert(documents)
    .values({
      fileId: file.id,
      date: file.date,
      fileName: file.nameEncrypted,
      fileNameIv: file.nameIv,
      fileNameTag: file.nameTag,
    })
    .returning()
  if (!document) throw RealtimeRpcError.BadRequest()
  return { mediaType: "document", documentId: document.id }
}

function finiteDuration(file: DbFile): number | null {
  const duration = file.videoDuration
  return duration != null && Number.isFinite(duration) && duration >= 0 && duration <= 2_147_483_647
    ? Math.round(duration)
    : null
}
