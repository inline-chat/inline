import type { CreateBotInput, CreateBotResult, DeleteMemberInput, DeleteMemberResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { createBot } from "@in/server/functions/createBot"
import { Functions } from "@in/server/functions"
import { Effect } from "effect"
import { SpaceIdInvalidError, SpaceNotExistsError } from "@in/server/functions/_errors"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { MemberNotExistsError } from "@in/server/modules/effect/commonErrors"

export const deleteMemberHandler = async (
  input: DeleteMemberInput,
  handlerContext: HandlerContext,
): Promise<DeleteMemberResult> => {
  try {
    const result = await Effect.runPromise(
      Functions.spaces.deleteMember(input, {
        currentSessionId: handlerContext.sessionId,
        currentUserId: handlerContext.userId,
      }),
    )

    return {
      updates: result.result.updates,
    }
  } catch (error) {
    if (error instanceof SpaceIdInvalidError) {
      throw RealtimeRpcError.SpaceIdInvalid
    }

    if (error instanceof SpaceNotExistsError) {
      throw RealtimeRpcError.SpaceIdInvalid
    }

    if (error instanceof MemberNotExistsError) {
      throw RealtimeRpcError.UserIdInvalid
    }

    throw RealtimeRpcError.InternalError
  }
}
