import { Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import type { RealtimeClient } from "../realtime"
import { Mutation, type Transaction } from "./transaction"

/**
 * `LOG_OUT`: ends this session on the server, so its token stops working
 * (InlineKit `InlineRPCClient.logout`). Transient: it is never queued for a
 * later connection or replayed after a restart; a sign-out that cannot reach
 * the server completes locally (the token then stays valid until revoked
 * elsewhere). `logOut` in `log-out.ts` is the older local-only teardown.
 */
export class LogOutRpcTransaction implements Transaction<Record<string, never>> {
  readonly method = Method.LOG_OUT
  readonly kind = Mutation({ transient: true })
  readonly context: Record<string, never> = {}

  input(): RpcCall["input"] {
    return { oneofKind: "logOut", logOut: {} }
  }

  apply(result: RpcResult["result"] | undefined, _db: Db) {
    if (!result || result.oneofKind !== "logOut") throw new Error("invalid")
  }
}

export const logOutRpc = () => new LogOutRpcTransaction()

/**
 * Send `LOG_OUT` and wait at most `timeoutMs` for the server's answer.
 * Resolves true when the server confirmed (`loggedOut`), false on a
 * timeout or an answer without it. Rejects when the request failed
 * (offline, an RPC error); callers treat every outcome as "continue".
 */
export const logOutOnServer = async (
  realtime: Pick<RealtimeClient, "execute">,
  timeoutMs: number,
): Promise<boolean> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<"timeout">((resolve) => {
    timer = setTimeout(() => resolve("timeout"), timeoutMs)
  })
  const request = realtime.execute(logOutRpc())
  // After a timeout the request is abandoned; its later failure is expected.
  request.catch(() => undefined)
  try {
    const outcome = await Promise.race([request, timeout])
    if (outcome === "timeout") return false
    return outcome?.oneofKind === "logOut" && outcome.logOut.loggedOut
  } finally {
    if (timer) clearTimeout(timer)
  }
}
