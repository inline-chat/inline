import type { DeleteMemberInput, DeleteMemberResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { Functions } from "@in/server/functions"
import { Cause, Effect } from "effect"
import { SpaceIdInvalidError, SpaceNotExistsError } from "@in/server/functions/_errors"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { MemberNotExistsError } from "@in/server/modules/effect/commonErrors"
import { Log } from "@in/server/utils/log"

const log = new Log("realtime.deleteMemberHandler")

export const deleteMemberHandler = async (
  input: DeleteMemberInput,
  handlerContext: HandlerContext,
): Promise<DeleteMemberResult> => {
  if (!input.userId) {
    throw RealtimeRpcError.UserIdInvalid
  }

  const exit = await Effect.runPromiseExit(
    Functions.spaces.deleteMember(input, {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    }),
  )

  if (exit._tag === "Failure") {
    const causeError = Cause.squash(exit.cause)

    log.error("deleteMemberHandler failed", causeError)

    if (causeError instanceof SpaceIdInvalidError || causeError instanceof SpaceNotExistsError) {
      throw RealtimeRpcError.SpaceIdInvalid
    }

    if (causeError instanceof MemberNotExistsError) {
      throw RealtimeRpcError.UserIdInvalid
    }

    if (causeError instanceof RealtimeRpcError) {
      throw causeError
    }

    throw RealtimeRpcError.InternalError
  }

  return {
    updates: exit.value.result.updates,
  }
}
