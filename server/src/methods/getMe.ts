import { encodeFullUserInfo, TUserInfo } from "@in/server/api-types"
import { Type, type Static } from "@sinclair/typebox"
import { UsersModel } from "@in/server/db/models/users"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({})

export const Response = Type.Object({
  user: TUserInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  const user = await UsersModel.getUserWithPhoto(currentUserId)

  return {
    user: encodeFullUserInfo(user),
  }
}
