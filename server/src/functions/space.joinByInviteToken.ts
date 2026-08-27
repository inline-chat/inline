import { spaceInviteLinks, spaces } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { joinSpaceByResolvedLink } from "@in/server/functions/space.joinByLink.shared"
import {
  hashSpaceInviteToken,
  isValidSpaceInviteToken,
} from "@in/server/modules/spaces/spaceInviteLinks"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type {
  JoinSpaceByInviteTokenInput,
  JoinSpaceByInviteTokenResult,
} from "@inline-chat/protocol/core"
import { and, eq, gt, isNull } from "drizzle-orm"

export const joinSpaceByInviteToken = async (
  input: JoinSpaceByInviteTokenInput,
  context: FunctionContext,
): Promise<JoinSpaceByInviteTokenResult> => {
  if (!isValidSpaceInviteToken(input.token)) {
    throw RealtimeRpcError.SpaceInviteInvalid()
  }
  const tokenHash = hashSpaceInviteToken(input.token)

  return joinSpaceByResolvedLink({
    currentUserId: context.currentUserId,
    resolveLockedSpace: async (tx) => {
      const [candidate] = await tx
        .select({ spaceId: spaceInviteLinks.spaceId })
        .from(spaceInviteLinks)
        .where(and(
          eq(spaceInviteLinks.tokenHash, tokenHash),
          isNull(spaceInviteLinks.revokedAt),
          gt(spaceInviteLinks.expiresAt, new Date()),
        ))
        .limit(1)
      if (!candidate) return undefined

      const [space] = await tx
        .select()
        .from(spaces)
        .where(and(
          eq(spaces.id, candidate.spaceId),
          eq(spaces.isPublic, false),
          isNull(spaces.deleted),
        ))
        .for("update")
        .limit(1)
      if (!space) return undefined

      const [stillValid] = await tx
        .select({ id: spaceInviteLinks.id })
        .from(spaceInviteLinks)
        .where(and(
          eq(spaceInviteLinks.spaceId, space.id),
          eq(spaceInviteLinks.tokenHash, tokenHash),
          isNull(spaceInviteLinks.revokedAt),
          gt(spaceInviteLinks.expiresAt, new Date()),
        ))
        .for("update")
        .limit(1)
      return stillValid ? space : undefined
    },
  })
}
