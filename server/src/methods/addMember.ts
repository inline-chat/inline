import type { HandlerContext } from "@in/server/controllers/helpers"
import { addSpaceMember, SpaceMemberAdmissionError } from "@in/server/functions/space.addMember.shared"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import { encodeMemberInfo, TMemberInfo } from "../api-types"
import { InlineError } from "../types/errors"
import { TInputId } from "../types/methods"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const Input = Type.Object({
  spaceId: TInputId,
  userId: TInputId,
})

export const Response = Type.Object({
  member: TMemberInfo,
})

export const handler = async (input: Static<typeof Input>, context: HandlerContext): Promise<Static<typeof Response>> => {
  try {
    const spaceId = Number(input.spaceId)
    if (!Number.isSafeInteger(spaceId) || spaceId <= 0) {
      throw new InlineError(InlineError.ApiError.SPACE_INVALID)
    }
    const userId = Number(input.userId)
    if (!Number.isSafeInteger(userId) || userId <= 0) {
      throw new InlineError(InlineError.ApiError.USER_INVALID)
    }

    const { member } = await addSpaceMember({
      spaceId,
      actorUserId: context.currentUserId,
      target: { kind: "userId", userId },
      admission: "manageMembers",
      role: "member",
      canAccessPublicChats: true,
    })

    return {
      member: encodeMemberInfo(member),
    }
  } catch (error) {
    if (error instanceof InlineError) throw error
    if (error instanceof SpaceMemberAdmissionError) {
      throw new InlineError(
        error.reason === "actorNotMember"
          ? InlineError.ApiError.SPACE_INVALID
          : InlineError.ApiError.SPACE_ADMIN_REQUIRED,
      )
    }
    if (RealtimeRpcError.is(error, RealtimeRpcError.Code.SPACE_ID_INVALID)) {
      throw new InlineError(InlineError.ApiError.SPACE_INVALID)
    }
    if (RealtimeRpcError.is(error, RealtimeRpcError.Code.USER_ID_INVALID)) {
      throw new InlineError(InlineError.ApiError.USER_INVALID)
    }
    if (RealtimeRpcError.is(error, RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED)) {
      throw new InlineError(InlineError.ApiError.SPACE_ADMIN_REQUIRED)
    }
    // The legacy API has no USER_ALREADY_MEMBER error. Preserve its historical
    // compatibility by mapping the unique-membership conflict to INTERNAL.
    if (RealtimeRpcError.is(error, RealtimeRpcError.Code.USER_ALREADY_MEMBER)) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    Log.shared.error("Failed to add member", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
