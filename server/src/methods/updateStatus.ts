import { db } from "@in/server/db"
import { Type, type Static } from "@sinclair/typebox"
import { presenceManager } from "@in/server/ws/presence"
import { TOptional } from "@in/server/models"
import { Log } from "@in/server/utils/log"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  online: Type.Boolean(),
})

export const Response = Type.Object({
  online: Type.Boolean(),
  lastOnline: TOptional(Type.Integer()),
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  Log.shared.info("Updating status", { currentUserId, online: input.online })
  let { online, lastOnline } = await presenceManager.updateUserOnlineStatus(currentUserId, input.online)
  return { online, lastOnline: lastOnline?.getTime() ?? null }
}
