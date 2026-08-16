import type { ServerReplayRepository } from "@inline-chat/protocol/server"
import { InlineProtocolReplayRepository } from "@in/server/db/models/inlineProtocol"
import { InlineProtocolReplayError } from "./errors"

export const makeInlineProtocolReplayRepository = (
  repository = new InlineProtocolReplayRepository(),
): ServerReplayRepository => ({
  claim: (input) => repository.claim({
    authKeyId: input.authKeyId,
    protocolSessionId: input.sessionId,
    messageId: input.messageId,
    authenticatedBody: input.authenticatedBody,
  }),
  complete: async (input) => {
    const completed = await repository.complete({
      authKeyId: input.authKeyId,
      protocolSessionId: input.sessionId,
      messageId: input.messageId,
      resultBody: input.resultBody,
    })
    if (!completed) throw new InlineProtocolReplayError({ operation: "complete_missing_claim" })
  },
})
