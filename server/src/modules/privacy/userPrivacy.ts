import type { User } from "@inline-chat/protocol/core"
import type { DbFile, DbUser } from "@in/server/db/schema"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"

export function encodePublicUser({ user, photoFile }: { user: DbUser; photoFile?: DbFile }): User {
  return encodeUser({ user, photoFile, min: true })
}
