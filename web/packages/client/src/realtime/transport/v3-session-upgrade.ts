import { AuthUpgradeDeclined_Reason, Method } from "@inline-chat/protocol/core"
import {
  InlineProtocolV3Connection,
  InlineProtocolV3Error,
  globalInlineProtocolClock,
  globalInlineProtocolTimers,
  type InlineProtocolPublicKey,
  type InlineProtocolRuntime,
} from "@inline-chat/protocol/secure/connection"
import { Log } from "@inline/log"
import type { InlineProtocolCredentials, InlineProtocolKeyStore } from "./v3-credentials"

export type V3SessionUpgradeOptions = {
  url: string
  runtime: InlineProtocolRuntime
  rsaPublicKeys: readonly InlineProtocolPublicKey[]
  keyStore: InlineProtocolKeyStore
  /** The bearer session being upgraded. */
  source: { userId: string; token: string }
  /** False once the source session is no longer the signed-in one; checked between steps. */
  isCurrent: () => boolean
  requestTimeoutMs?: number
}

export class V3SessionUpgradeError extends Error {
  constructor(
    readonly code: "declined-disabled" | "declined-ineligible" | "declined-source-rejected" | "declined" | "not-bound" | "mismatch" | "superseded",
    message: string,
  ) {
    super(message)
    this.name = `V3SessionUpgradeError:${code}`
  }
}

const declinedCode = (reason: AuthUpgradeDeclined_Reason): V3SessionUpgradeError["code"] => {
  switch (reason) {
    case AuthUpgradeDeclined_Reason.DISABLED:
      return "declined-disabled"
    case AuthUpgradeDeclined_Reason.INELIGIBLE:
      return "declined-ineligible"
    case AuthUpgradeDeclined_Reason.SOURCE_REJECTED:
      return "declined-source-rejected"
    default:
      return "declined"
  }
}

/**
 * Adds V3 authority to a bearer session (`authUpgradeSession`), following the
 * Apple clients' `LegacyProtocolUpgradeAttempt`:
 *
 * 1. Reuse a staged permanent key, or create one and store it as `staged`
 *    before the request that can bind it, so a retry after a lost reply proves
 *    possession of the same key instead of minting another authority.
 * 2. Send `authUpgradeSession` with the bearer inside the encrypted carrier and
 *    check the response names the same user.
 * 3. Bind a fresh temporary key to the permanent key and prove it with `getMe`.
 * 4. Store the credentials as `bound`.
 *
 * Returns the bound credentials, or the existing ones if already bound.
 */
export const upgradeBearerSession = async (options: V3SessionUpgradeOptions): Promise<InlineProtocolCredentials> => {
  const { keyStore, source } = options
  const requireCurrent = () => {
    if (!options.isCurrent()) throw new V3SessionUpgradeError("superseded", "Account changed during upgrade")
  }
  const base = {
    url: options.url,
    runtime: options.runtime,
    ...(options.requestTimeoutMs != null ? { requestTimeoutMs: options.requestTimeoutMs } : {}),
  }
  requireCurrent()
  const existing = await keyStore.get(source.userId)
  requireCurrent()
  if (existing?.state === "bound") return existing

  let permanentConnection: InlineProtocolV3Connection | undefined
  let temporaryConnection: InlineProtocolV3Connection | undefined
  try {
    if (existing?.state === "staged") {
      permanentConnection = await InlineProtocolV3Connection.connect({
        ...base, rsaPublicKeys: [], authorization: existing.permanent,
      })
    } else {
      permanentConnection = await InlineProtocolV3Connection.connect({
        ...base, rsaPublicKeys: options.rsaPublicKeys, temporary: false,
      })
      requireCurrent()
      await keyStore.set(source.userId, {
        userId: source.userId,
        state: "staged",
        permanent: permanentConnection.authorization,
      })
    }
    requireCurrent()
    const result = await permanentConnection.authUpgradeSession(source.token)
    requireCurrent()
    if (result.state.oneofKind === "declined") {
      throw new V3SessionUpgradeError(declinedCode(result.state.declined.reason), "Server declined the session upgrade")
    }
    if (result.state.oneofKind === "notBound") {
      throw new V3SessionUpgradeError("not-bound", "Server did not bind the permanent key")
    }
    if (result.state.oneofKind !== "authorized") {
      throw new InlineProtocolV3Error("protocol", "Unexpected auth.upgradeSession result")
    }
    const authorized = result.state.authorized
    if (authorized.user?.id === undefined || authorized.user.id.toString() !== source.userId || authorized.accountSessionId <= 0n) {
      throw new V3SessionUpgradeError("mismatch", "Upgrade bound a different account")
    }
    const permanent = permanentConnection.authorization
    await permanentConnection.close()
    permanentConnection = undefined
    requireCurrent()

    temporaryConnection = await InlineProtocolV3Connection.connect({
      ...base, rsaPublicKeys: options.rsaPublicKeys, temporary: true,
    })
    requireCurrent()
    await temporaryConnection.bindTemporary(permanent)
    requireCurrent()
    // An application answer proves the carrier and the binding; getMe proves the identity.
    const me = await temporaryConnection.callRpc({ method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } })
    if (me.oneofKind !== "getMe" || me.getMe.user?.id.toString() !== source.userId) {
      throw new V3SessionUpgradeError("mismatch", "Temporary key answered for a different account")
    }
    requireCurrent()
    const credentials: InlineProtocolCredentials = {
      userId: source.userId,
      accountSessionId: authorized.accountSessionId.toString(),
      state: "bound",
      permanent,
      temporary: temporaryConnection.authorization,
    }
    await keyStore.set(source.userId, credentials)
    return credentials
  } finally {
    await permanentConnection?.close()
    await temporaryConnection?.close()
  }
}

export type V3SessionUpgraderOptions = Omit<V3SessionUpgradeOptions, "source" | "isCurrent"> & {
  /** The current bearer session, or null when signed out. */
  source: () => { userId: string; token: string } | null
  timeoutMs?: number
  retryDelayMs?: number
  logger?: Log
}

/**
 * Runs `upgradeBearerSession` in the background at most once per opportunity:
 * one attempt at a time, a deadline per attempt, and a quiet period after any
 * outcome. Failures never reach the transport or the session; they are logged
 * by category only (no tokens, keys or server text).
 */
export class V3SessionUpgrader {
  readonly #options: V3SessionUpgraderOptions
  readonly #log: Log
  #attempt: Promise<void> | undefined
  #retryAfter: { userId: string; token: string; at: number } | undefined
  #generation = 0

  constructor(options: V3SessionUpgraderOptions) {
    this.#options = options
    this.#log = options.logger ?? new Log("RealtimeV3.SessionUpgrade")
  }

  /** Starts an attempt if none is running and the quiet period has passed. */
  start(): void {
    const source = this.#options.source()
    if (!source || this.#attempt) return
    const clock = this.#options.runtime.clock ?? globalInlineProtocolClock()
    const quiet = this.#retryAfter
    if (quiet && quiet.userId === source.userId && quiet.token === source.token && clock.monotonicMilliseconds() < quiet.at) return
    const generation = ++this.#generation
    const timers = this.#options.runtime.timers ?? globalInlineProtocolTimers()
    const started = clock.monotonicMilliseconds()
    const isCurrent = () => {
      const current = this.#options.source()
      return generation === this.#generation && current?.userId === source.userId && current.token === source.token
    }
    const attempt = (async () => {
      let timer: unknown
      try {
        await Promise.race([
          upgradeBearerSession({ ...this.#options, source, isCurrent }),
          new Promise<never>((_, reject) => {
            timer = timers.setTimeout(
              () => reject(new InlineProtocolV3Error("timeout", "Session upgrade timed out")),
              this.#options.timeoutMs ?? 20_000,
            )
          }),
        ])
        this.#log.info("transport.v3.upgrade", { outcome: "bound", durationMs: Math.round(clock.monotonicMilliseconds() - started) })
      } catch (error) {
        const reason = error instanceof V3SessionUpgradeError || error instanceof InlineProtocolV3Error ? error.code : "unexpected"
        this.#log.warn("transport.v3.upgrade", { outcome: "deferred", reason })
      } finally {
        timers.clearTimeout(timer)
        if (generation === this.#generation) {
          this.#retryAfter = { userId: source.userId, token: source.token, at: clock.monotonicMilliseconds() + (this.#options.retryDelayMs ?? 300_000) }
        }
      }
    })()
    this.#attempt = attempt
    void attempt.finally(() => {
      if (this.#attempt === attempt) this.#attempt = undefined
    })
  }

  /** Cancels interest in the running attempt; it stops at its next account check. */
  async stop(): Promise<void> {
    ++this.#generation
    const attempt = this.#attempt
    this.#attempt = undefined
    await attempt
  }

  /** Resolves when the running attempt, if any, settles. For tests and shutdown. */
  async settled(): Promise<void> {
    await this.#attempt
  }
}
