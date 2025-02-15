import { getR2 } from "@in/server/libs/r2"

/**
 * Upload a file to the bucket.
 *
 * @param file - The file to upload.
 * @param fileUniqueId - The unique id of the file.
 * @param type - The type of the file.
 * @param mimeType - The mime type of the file.
 */
export async function uploadToBucket(file: File, { path, type }: { path: string; type: string }): Promise<void> {
  const r2 = getR2()

  if (!r2) {
    throw new Error("R2 is not initialized")
  }

  let destinationFile = r2.file(path)

  await destinationFile.write(file, {
    type,
  })
}
