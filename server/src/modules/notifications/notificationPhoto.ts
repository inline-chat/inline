import type { DbFullPlainFile } from "@in/server/db/models/files"
import { getSignedMediaPhotoUrl } from "@in/server/modules/files/path"

type PhotoFile = Pick<DbFullPlainFile, "fileUniqueId" | "path" | "fileSize" | "mimeType" | "width" | "height">
type NotificationPhoto = { photoSizes: readonly { size: string | null; file: PhotoFile }[] | null }

// Keep these resource limits aligned with InlineNotificationPhoto on Apple.
const maximumBytes = 5 * 1_024 * 1_024
const photoUrlLifetimeSeconds = 60 * 60

export const notificationPhotoUrl = (
  photo: NotificationPhoto | null | undefined,
  sign: typeof getSignedMediaPhotoUrl = getSignedMediaPhotoUrl,
): string | undefined => {
  let best: PhotoFile | undefined
  for (const size of photo?.photoSizes ?? []) {
    const file = size.file
    const area = (file.width ?? 0) * (file.height ?? 0)
    if (size.size === "s" || !file.fileSize || file.fileSize > maximumBytes || file.fileSize < 0 ||
        !["image/jpeg", "image/png"].includes(file.mimeType ?? "") ||
        !file.width || !file.height || file.width < 0 || file.height < 0 || area > 40_000_000) continue
    if (!best || area > (best.width ?? 0) * (best.height ?? 0)) best = file
  }
  if (!best) return undefined
  try {
    const value = sign(best, photoUrlLifetimeSeconds)
    if (!value || Buffer.byteLength(value, "utf8") > 1_024) return undefined
    const url = new URL(value)
    return url.protocol === "https:" && !url.username && !url.password ? value : undefined
  } catch {
    // Optional artwork must never stop the message's text notification.
    return undefined
  }
}
