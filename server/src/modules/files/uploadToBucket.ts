import { getR2 } from "@in/server/libs/r2"

type BucketWriter = (path: string, file: File, type: string) => Promise<number>

const writeBucketObject: BucketWriter = async (path, file, type) => {
  const r2 = getR2()
  if (!r2) throw new Error("R2 is not initialized")
  return r2.file(path).write(file, { type })
}

/**
 * Upload a file to the bucket.
 *
 * @param file - The file to upload.
 * @param fileUniqueId - The unique id of the file.
 * @param type - The type of the file.
 * @param mimeType - The mime type of the file.
 */
export async function uploadToBucket(
  file: File,
  { path, type }: { path: string; type: string },
  write: BucketWriter = writeBucketObject,
): Promise<void> {
  if (file.size === 0) {
    throw new Error("Cannot upload empty file to bucket")
  }
  if (!type.trim()) {
    throw new Error("Missing content type for bucket upload")
  }

  const written = await write(path, file, type)
  if (written !== file.size) {
    throw new Error(`File storage wrote ${written} of ${file.size} bytes`)
  }
}

/** Delete one exact, already-resolved object path. Callers own authorization and fencing. */
export async function deleteFromBucket(path: string): Promise<void> {
  const r2 = getR2()
  if (!r2) throw new Error("R2 is not initialized")
  await r2.file(path).delete()
}
