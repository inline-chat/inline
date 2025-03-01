import { UsersModel } from "@in/server/db/models/users"
import { type GetMeInput, type GetMeResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const getMe = async (_: GetMeInput, handlerContext: HandlerContext): Promise<GetMeResult> => {
  let user = await UsersModel.getUserById(handlerContext.userId)

  if (!user) {
    throw RealtimeRpcError.InternalError
  }

  return {
    user: Encoders.user({ user, min: false }),
  }
}
