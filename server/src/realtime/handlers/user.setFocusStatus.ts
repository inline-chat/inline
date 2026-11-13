import type { SetFocusStatusInput, SetFocusStatusResult } from "@inline-chat/protocol/core"
import { setFocusStatus } from "@in/server/functions/user.setFocusStatus"
import type { HandlerContext } from "@in/server/realtime/types"

export const setFocusStatusHandler = async (
  input: SetFocusStatusInput,
  handlerContext: HandlerContext,
): Promise<SetFocusStatusResult> => {
  await setFocusStatus(input, {
    currentSessionId: handlerContext.sessionId,
    currentUserId: handlerContext.userId,
  })
  return {}
}
