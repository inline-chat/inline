import { Member_Role, Space } from "@in/protocol/core"
import type { DbSpace } from "@in/server/db/schema"

// New encoders for Member and MinUser
export function encodeSpace(space: DbSpace): Space {
  return {
    id: BigInt(space.id),
    name: space.name,
  }
}
