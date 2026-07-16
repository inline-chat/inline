import { encodeMinUserInfo, TMinUserInfo } from "@in/server/api-types"
import { Type, type Static } from "@sinclair/typebox"
import { UsersModel } from "@in/server/db/models/users"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  q: Type.String(),
  limit: Type.Optional(Type.Integer({ default: 10 })),
})

export const Response = Type.Object({
  users: Type.Array(TMinUserInfo),
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  const users = await UsersModel.searchUsers({
    query: input.q?.trim().replace(/^@+/, ""),
    limit: input.limit ?? 10,
    excludeUserId: currentUserId,
  })

  return { users: users.map((u) => encodeMinUserInfo(u.user, { photoFile: u.photoFile ?? undefined })) }
}
