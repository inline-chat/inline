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
    if (completed) return { kind: "completed" }
    const resultBody = await repository.result({
      authKeyId: input.authKeyId,
      protocolSessionId: input.sessionId,
      messageId: input.messageId,
    })
    if (!resultBody) throw new InlineProtocolReplayError({ operation: "complete_missing_claim" })
    return { kind: "superseded", resultBody }
  },
  dropAnswer: async (input) => {
    const dropped = await repository.complete({
      authKeyId: input.authKeyId,
      protocolSessionId: input.sessionId,
      messageId: input.messageId,
      resultBody: input.runningResultBody,
    })
    return dropped ? "running" : "unknown"
  },
  forgetAnswer: async (input) => {
    const replaced = await repository.replaceResult({
      authKeyId: input.authKeyId,
      protocolSessionId: input.sessionId,
      messageId: input.messageId,
      resultBody: input.forgottenResultBody,
    })
    if (!replaced) throw new InlineProtocolReplayError({ operation: "forget_missing_result" })
  },
})
