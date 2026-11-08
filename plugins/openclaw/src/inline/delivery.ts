import { randomBytes } from "node:crypto"
import { setTimeout as delay } from "node:timers/promises"
import type { InlineSdkClient, InlineSdkSendMessageParams } from "@inline-chat/realtime-sdk"

const MAX_SEND_RETRIES = 2
const MAX_SEND_WAIT_SECONDS = 60

/** Only an explicit server rejection is retry-safe; transport uncertainty is not. */
function retryDelayMs(error: unknown): number | undefined {
  const seen = new Set<unknown>()
  let wait: number | undefined
  while (error && typeof error === "object" && !seen.has(error)) {
    seen.add(error)
    const entry = error as { code?: unknown; rpcCode?: unknown; retryAfterSeconds?: unknown; cause?: unknown }
    if (entry.code === "commit-outcome-unknown") return undefined
    const seconds = entry.retryAfterSeconds
    if (entry.code === "rpc-error" && (entry.rpcCode === 3 || entry.rpcCode === 429)
      && typeof seconds === "number" && Number.isFinite(seconds)
      && seconds > 0 && seconds <= MAX_SEND_WAIT_SECONDS) {
      wait = seconds * 1_000
    }
    error = entry.cause
  }
  return wait
}

/** Monitor sends bypass the host outbox. Keep one identity across flood retries. */
export function createInlineMessageSender(
  client: Pick<InlineSdkClient, "sendMessage">,
  signal?: AbortSignal,
): InlineSdkClient["sendMessage"] {
  return async (params: InlineSdkSendMessageParams) => {
    const request = { ...params, randomId: params.randomId ?? (randomBytes(8).readBigInt64LE() || 1n) }
    for (let retry = 0; ; retry++) {
      signal?.throwIfAborted()
      try {
        return await client.sendMessage(request)
      } catch (error) {
        const wait = retryDelayMs(error)
        if (retry >= MAX_SEND_RETRIES || wait === undefined) throw error
        // Never shorten a server wait. Long waits stay with the caller's failure path.
        await delay(wait, undefined, { signal })
      }
    }
  }
}
