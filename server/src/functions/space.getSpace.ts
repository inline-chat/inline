import { db } from "@in/server/db"
import { SpaceSettingsModel } from "@in/server/db/models/spaceSettings"
import { members, spaces } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { GetSpaceInput, GetSpaceResult } from "@inline-chat/protocol/core"
import { and, eq, isNull } from "drizzle-orm"

export async function getSpace(input: GetSpaceInput, context: FunctionContext): Promise<GetSpaceResult> {
  const spaceId = toPositiveSpaceId(input.spaceId)

  return db.transaction(
    async (tx) => {
      const [space] = await tx
        .select()
        .from(spaces)
        .where(and(eq(spaces.id, spaceId), isNull(spaces.deleted)))
        .limit(1)
      if (!space) throw RealtimeRpcError.SpaceIdInvalid()

      const [membership] = await tx
        .select()
        .from(members)
        .where(and(eq(members.spaceId, spaceId), eq(members.userId, context.currentUserId)))
        .limit(1)
      if (!membership) throw RealtimeRpcError.SpaceIdInvalid()

      return {
        space: Encoders.space(space, { encodingForUserId: context.currentUserId }),
        membership: Encoders.member(membership),
        settings: await SpaceSettingsModel.get(spaceId, tx),
      }
    },
    { isolationLevel: "repeatable read", accessMode: "read only" },
  )
}

function toPositiveSpaceId(id: bigint): number {
  const value = Number(id)
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }
  return value
}
