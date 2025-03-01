import type { DbUser } from "@in/server/db/schema"
import { User, UserStatus_Status } from "@in/protocol/core"
import { encodeDate } from "@in/server/realtime/encoders/helpers"

export const encodeUser = ({ user, min = false }: { user: DbUser; min?: boolean }): User => {
  return {
    id: BigInt(user.id),
    username: user.username ?? undefined,
    firstName: user.firstName ?? undefined,
    lastName: user.lastName ?? undefined,
    email: min ? undefined : user.email ?? undefined,
    phoneNumber: min ? undefined : user.phoneNumber ?? undefined,
    min: min ?? false,
    status: min
      ? undefined
      : {
          online: user.online ? UserStatus_Status.ONLINE : UserStatus_Status.OFFLINE,
          lastOnline: { date: user.lastOnline ? encodeDate(user.lastOnline) : undefined },
        },
  }
}
