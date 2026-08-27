import { lower, spaces } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { joinSpaceByResolvedLink } from "@in/server/functions/space.joinByLink.shared"
import { normalizeSpaceHandle } from "@in/server/modules/spaces/spaceHandle"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { JoinPublicSpaceInput, JoinPublicSpaceResult } from "@inline-chat/protocol/core"
import { and, eq, isNull } from "drizzle-orm"

export const joinPublicSpace = async (
  input: JoinPublicSpaceInput,
  context: FunctionContext,
): Promise<JoinPublicSpaceResult> => {
  const normalizedHandle = normalizeSpaceHandle(input.handle)
  if (!normalizedHandle) {
    throw RealtimeRpcError.BadRequest()
  }
  const handle = normalizedHandle.toLowerCase()

  return joinSpaceByResolvedLink({
    currentUserId: context.currentUserId,
    resolveLockedSpace: async (tx) => {
      const [space] = await tx
        .select()
        .from(spaces)
        .where(and(
          eq(lower(spaces.handle), handle),
          eq(spaces.isPublic, true),
          eq(spaces.canPublicJoin, true),
          isNull(spaces.deleted),
        ))
        .for("update")
        .limit(1)
      // Preserve the established public-handle RPC contract. The private
      // bearer-token path uses SPACE_INVITE_INVALID, while public handles have
      // always collapsed missing, private, deleted, and disabled spaces into
      // SPACE_ID_INVALID.
      if (!space) throw RealtimeRpcError.SpaceIdInvalid()
      return space
    },
  })
}
