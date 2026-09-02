import { PutObjectCommand } from "@aws-sdk/client-s3"
import { Readable } from "node:stream"
import { getR2, getR2Aws } from "@in/server/libs/r2"

const DEFAULT_BUCKET_WRITE_TIMEOUT_MS = 60_000

type BucketWriter = (
  path: string,
  file: File,
  type: string,
  signal: AbortSignal,
) => Promise<number>

const writeBucketObject: BucketWriter = async (path, file, type, signal) => {
  const r2 = getR2Aws()
  if (!r2) throw new Error("R2 is not initialized")
  await r2.client.send(new PutObjectCommand({
    Body: Readable.fromWeb(file.stream() as never),
    Bucket: r2.bucket,
    ContentLength: file.size,
    ContentType: type,
    Key: path,
  }), { abortSignal: signal })
  return file.size
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
  {
    path,
    type,
    signal,
    timeoutMs = DEFAULT_BUCKET_WRITE_TIMEOUT_MS,
  }: { path: string; type: string; signal?: AbortSignal; timeoutMs?: number },
  write: BucketWriter = writeBucketObject,
): Promise<void> {
  if (file.size === 0) {
    throw new Error("Cannot upload empty file to bucket")
  }
  if (!type.trim()) {
    throw new Error("Missing content type for bucket upload")
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) {
    throw new RangeError("Invalid bucket write timeout")
  }

  const deadline = AbortSignal.timeout(timeoutMs)
  const requestSignal = signal ? AbortSignal.any([signal, deadline]) : deadline
  const written = await write(path, file, type, requestSignal)
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
