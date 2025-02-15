import { db } from "@in/server/db"
import { Type, type Static } from "@sinclair/typebox"
import { InlineError } from "@in/server/types/errors"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { encodeUserInfo, TUserInfo } from "@in/server/api-types"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  fileUniqueId: Type.String({
    examples: ["INP123456789012345678901"],
    title: "File unique id",
    description: "File unique id you received from uploadFile method as a result of uploading profile photo",
  }),
})

export const Response = Type.Object({
  user: TUserInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  // Get the file
  const file = await getFileByUniqueId(input.fileUniqueId)
  if (!file) {
    throw new InlineError(InlineError.ApiError.FILE_NOT_FOUND)
  }

  // Verify file ownership
  if (file.userId !== currentUserId) {
    throw new InlineError(InlineError.ApiError.FILE_NOT_FOUND)
  }

  // Update user's profile photo
  let user = await db.update(users).set({ photoFileId: file.id }).where(eq(users.id, currentUserId)).returning()

  let user0 = user[0]

  if (!user0) {
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  let u = encodeUserInfo(user0, { photoFile: file })
  return { user: u }
}
