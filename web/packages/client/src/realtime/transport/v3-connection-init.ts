import type { ConnectionInit, UpdateSessionInput } from "@inline-chat/protocol/core"

/**
 * Who is connecting. Sent in `ConnectionInit` on both transports.
 *
 * What the server reads today (November 2026): over V2 it stores
 * `clientVersion` and `osVersion` on the session (semver of up to four parts,
 * else it falls back to `buildNumber`) and ignores the rest; over V3 it reads
 * only `supportsWorking` and `transferOnly`. Client type comes from the
 * session's login, not from this message. To store time zone and device name
 * on either transport, call the `updateSession` RPC (`updateSessionInput`).
 */
export type ClientIdentity = {
  clientType: "web"
  clientVersion?: string
  osVersion?: string
  /** Stable per installation (per browser profile, per origin). Never the account ID. */
  deviceId?: string
  deviceName?: string
  timeZone?: string
}

export type ConnectionInitInput = {
  token: string
  buildNumber?: number
  layer?: number
  supportsWorking?: boolean
  identity?: ClientIdentity
}

const present = (value: string | undefined) => (value != null && value.trim() !== "" ? value : undefined)

/** Builds the V2 `ConnectionInit`; the V3 transport strips the token before sending it. */
export const buildConnectionInit = (input: ConnectionInitInput): ConnectionInit => {
  const identity = input.identity
  const clientVersion = present(identity?.clientVersion)
  const osVersion = present(identity?.osVersion)
  const deviceId = present(identity?.deviceId)
  const deviceName = present(identity?.deviceName)
  const timeZone = present(identity?.timeZone)
  return {
    token: input.token,
    ...(input.buildNumber != null ? { buildNumber: input.buildNumber } : {}),
    ...(input.layer != null ? { layer: input.layer } : {}),
    ...(identity ? { clientType: identity.clientType } : {}),
    ...(clientVersion ? { clientVersion } : {}),
    ...(osVersion ? { osVersion } : {}),
    ...(deviceId ? { deviceId } : {}),
    ...(deviceName ? { deviceName } : {}),
    ...(timeZone ? { timeZone } : {}),
    ...(input.supportsWorking != null ? { supportsWorking: input.supportsWorking } : {}),
  }
}

/**
 * The V3 form of an init: the bound key, not a bearer, authenticates a V3
 * connection, so the token never enters the encrypted carrier.
 */
export const v3ConnectionInit = (init: ConnectionInit): ConnectionInit => {
  const { token: _token, transferOnly: _transferOnly, ...rest } = init
  return { ...rest, token: "" }
}

/** The `updateSession` RPC input that stores the identity the server does not take from `ConnectionInit`. */
export const updateSessionInput = (identity: ClientIdentity): UpdateSessionInput | undefined => {
  const input: UpdateSessionInput = {
    ...(present(identity.timeZone) ? { timeZone: identity.timeZone } : {}),
    ...(present(identity.deviceName) ? { deviceName: identity.deviceName } : {}),
    ...(present(identity.clientVersion) ? { clientVersion: identity.clientVersion } : {}),
    ...(present(identity.osVersion) ? { osVersion: identity.osVersion } : {}),
  }
  return Object.keys(input).length > 0 ? input : undefined
}

/** The IANA time zone of the runtime (`Intl`), or undefined where unavailable. */
export const currentTimeZone = (): string | undefined => {
  try {
    return present(Intl.DateTimeFormat().resolvedOptions().timeZone)
  } catch {
    return undefined
  }
}

const browserNames: ReadonlyArray<readonly [RegExp, string]> = [
  [/Edg\//, "Edge"],
  [/OPR\//, "Opera"],
  [/Firefox\//, "Firefox"],
  [/Chrome\//, "Chrome"],
  [/Safari\//, "Safari"],
]

const platformNames: ReadonlyArray<readonly [RegExp, string]> = [
  [/iPhone|iPad|iPod/, "iOS"],
  [/Android/, "Android"],
  [/Mac OS X|Macintosh/, "macOS"],
  [/Windows/, "Windows"],
  [/CrOS/, "ChromeOS"],
  [/Linux/, "Linux"],
]

/** A short, non-identifying device name from a user agent, such as "Chrome on macOS". */
export const describeUserAgent = (userAgent: string | undefined): string | undefined => {
  if (!userAgent) return undefined
  const browser = browserNames.find(([pattern]) => pattern.test(userAgent))?.[1]
  const platform = platformNames.find(([pattern]) => pattern.test(userAgent))?.[1]
  if (browser && platform) return `${browser} on ${platform}`
  return browser ?? platform
}

/** The web client's identity from runtime facts; the caller supplies the stable device ID and version. */
export const browserClientIdentity = (input: {
  clientVersion?: string
  deviceId?: string
  userAgent?: string
  timeZone?: string
}): ClientIdentity => {
  const deviceName = describeUserAgent(input.userAgent)
  const timeZone = input.timeZone ?? currentTimeZone()
  return {
    clientType: "web",
    ...(input.clientVersion ? { clientVersion: input.clientVersion } : {}),
    ...(input.deviceId ? { deviceId: input.deviceId } : {}),
    ...(deviceName ? { deviceName } : {}),
    ...(timeZone ? { timeZone } : {}),
  }
}
