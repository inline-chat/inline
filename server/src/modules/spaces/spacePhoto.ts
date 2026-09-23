import { getFileByUniqueId } from "@in/server/db/models/files"
import { InlineError } from "@in/server/types/errors"

export async function requireOwnedSpacePhoto(value: string | undefined, userId: number): Promise<string | null> {
  const id = value?.trim()
  if (!id) return null
  const file = await getFileByUniqueId(id)
  if (!file || file.userId !== userId || file.fileType !== "photo") throw new InlineError(InlineError.ApiError.FILE_UNIQUE_ID_INVALID)
  return file.fileUniqueId
}
