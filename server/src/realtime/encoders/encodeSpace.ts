import { Member_Role, Space } from "@in/protocol/core"
import type { DbSpace } from "@in/server/db/schema"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

// New encoders for Member and MinUser
export function encodeSpace(space: DbSpace, { encodingForUserId }: { encodingForUserId: number }): Space {
  return {
    id: BigInt(space.id),
    name: space.name,
    creator: encodingForUserId === space.creatorId,
    date: encodeDateStrict(space.date),
  }
}
