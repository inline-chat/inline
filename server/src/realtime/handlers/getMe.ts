import { UsersModel } from "@in/server/db/models/users"
import type { GetMeInput, GetMeResult } from "@in/server/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"

export const getMe = async (input: GetMeInput, handlerContext: HandlerContext): Promise<GetMeResult> => {
  let user = await UsersModel.getUserById(handlerContext.userId)

  if (!user) {
    throw new Error("User not found") // todo: make rpc error
  }

  return {
    user: {
      id: BigInt(user.id),
      username: user.username ?? undefined,
      firstName: user.firstName ?? undefined,
      lastName: user.lastName ?? undefined,
      email: user.email ?? undefined,
      phoneNumber: user.phoneNumber ?? undefined,
    },
  }
}
