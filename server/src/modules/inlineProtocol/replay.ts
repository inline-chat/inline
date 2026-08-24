import type { ServerReplayRepository } from "@inline-chat/protocol/server"
import { InlineProtocolReplayRepository } from "@in/server/db/models/inlineProtocol"
import { Log } from "@in/server/utils/log"
import { InlineProtocolReplayError } from "./errors"

const REPLAY_CLEANUP_INTERVAL_MS = 60_000
const REPLAY_CLEANUP_FULL_BATCH_DELAY_MS = 250
const REPLAY_CLEANUP_BATCH_SIZE = 1_000
const log = new Log("InlineProtocol.V3.Replay")

export type InlineProtocolReplayOwner = ServerReplayRepository & {
  close(): void
}

export const makeInlineProtocolReplayRepository = (
  repository = new InlineProtocolReplayRepository(),
): InlineProtocolReplayOwner => {
  let closed = false
  let timer: ReturnType<typeof setTimeout> | undefined
  let cleanup: Promise<void> | undefined

  const scheduleCleanup = (delayMs: number): void => {
    if (closed || timer !== undefined) return
    timer = setTimeout(() => {
      timer = undefined
      if (closed || cleanup !== undefined) return
      cleanup = repository.cleanupExpiredCompleted(new Date(), REPLAY_CLEANUP_BATCH_SIZE)
        .then((deleted) => {
          scheduleCleanup(deleted === REPLAY_CLEANUP_BATCH_SIZE
            ? REPLAY_CLEANUP_FULL_BATCH_DELAY_MS
            : REPLAY_CLEANUP_INTERVAL_MS)
        })
        .catch((error) => {
          log.warn("Inline Protocol replay cleanup failed", { error })
          scheduleCleanup(REPLAY_CLEANUP_INTERVAL_MS)
        })
        .finally(() => { cleanup = undefined })
    }, delayMs)
    timer.unref?.()
  }

  scheduleCleanup(REPLAY_CLEANUP_INTERVAL_MS)
  return {
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
      const running = await repository.isInFlight({
        authKeyId: input.authKeyId,
        protocolSessionId: input.sessionId,
        messageId: input.messageId,
      })
      return running ? "running" : "unknown"
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
    close: () => {
      closed = true
      if (timer !== undefined) clearTimeout(timer)
      timer = undefined
    },
  }
}
