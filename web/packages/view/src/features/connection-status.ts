/**
 * What the user is told about the core: one status for the chat subtitle and
 * the window chrome, and the connection display rule of the Mac app
 * (feature-map rule 15, `RealtimeV2/Realtime/RealtimeState.swift`):
 *
 * - On cold start (the connection has never reached `connected` or
 *   `updating` in this session) a connecting state shows at once.
 * - After that, a connecting state shows only once it has lasted 1 s; a
 *   reconnect that finishes sooner shows nothing.
 * - While shown, a change between connecting states shows at once, and
 *   `connected` hides it at once (the Mac hide delay is 0).
 */

import type { ConnectionState, CoreResource, SyncStall } from "@inline/core-protocol"
import type { ChatID, SpaceID, UserID } from "@inline/ids"
import {
  computed,
  effect,
  plainEqual,
  signal,
  untracked,
  type Clock,
  type Dispose,
  type ReadSignal,
} from "@inline/reactive"

/** The connection states worth showing. */
export type DisplayedConnection = "connecting" | "updating" | "waitingForNetwork"

/** Mac `RealtimeConnectionDisplayPolicy.macOS.reconnectDelaySeconds`. */
export const reconnectDisplayDelayMs = 1_000

const displayable = (state: ConnectionState | undefined): state is DisplayedConnection =>
  state === "connecting" || state === "updating" || state === "waitingForNetwork"

export interface ConnectionDisplay {
  /** The connection state to show, or undefined when there is nothing to say. */
  readonly displayed: ReadSignal<DisplayedConnection | undefined>
  dispose(): void
}

export const createConnectionDisplay = (options: {
  readonly connection: ReadSignal<ConnectionState | undefined>
  readonly clock: Clock
  readonly reconnectDelayMs?: number
}): ConnectionDisplay => {
  const { clock } = options
  const delay = options.reconnectDelayMs ?? reconnectDisplayDelayMs
  const displayed = signal<DisplayedConnection | undefined>(undefined)
  let reachedConnected = false
  let showTimer: unknown
  let current: ConnectionState | undefined

  const cancelShow = () => {
    if (showTimer === undefined) return
    clock.clearTimeout(showTimer)
    showTimer = undefined
  }

  const apply = (state: ConnectionState | undefined) => {
    if (state === current) return
    current = state
    if (!displayable(state)) {
      cancelShow()
      displayed.set(undefined)
    } else if (displayed.peek() !== undefined) {
      displayed.set(state)
    } else if (showTimer === undefined) {
      const wait = reachedConnected ? delay : 0
      if (wait <= 0) {
        displayed.set(state)
      } else {
        showTimer = clock.setTimeout(() => {
          showTimer = undefined
          if (displayable(current)) displayed.set(current)
        }, wait)
      }
    }
    if (state === "connected" || state === "updating") reachedConnected = true
  }

  const stop: Dispose = effect(() => {
    const state = options.connection.get()
    untracked(() => apply(state))
  })

  return {
    displayed: { get: () => displayed.get(), peek: () => displayed.peek() },
    dispose: () => {
      stop()
      cancelShow()
    },
  }
}

/**
 * One user-facing status, most important first:
 *
 * - `starting`: no core resource yet, or the core is opening storage.
 * - `outdated`, `superseded`: a newer build owns the data; offer a reload.
 * - `failed`: the core could not start (`CoreResource.failure` says why).
 * - `signedOut`: the core has no session (also after a revocation).
 * - `storageFull`: durable intents are refused until space is freed.
 * - `connecting`, `updating`, `waitingForNetwork`: as the display rule allows.
 * - `storageNotKept`: storage is in memory; nothing survives a reload.
 * - `ready`.
 */
export type SessionStatus =
  | "starting"
  | "outdated"
  | "superseded"
  | "failed"
  | "signedOut"
  | "storageFull"
  | DisplayedConnection
  | "storageNotKept"
  | "ready"

export const sessionStatus = (core: CoreResource | undefined, connection: DisplayedConnection | undefined): SessionStatus => {
  if (!core) return "starting"
  switch (core.phase) {
    case "starting":
      return "starting"
    case "outdated":
    case "superseded":
    case "failed":
    case "signedOut":
      return core.phase
    case "ready":
      break
  }
  if (core.storage === "full") return "storageFull"
  if (connection) return connection
  if (core.storage === "memory") return "storageNotKept"
  return "ready"
}

/** `sessionStatus` as a signal. */
export const sessionStatusSignal = (
  core: ReadSignal<CoreResource | undefined>,
  display: ConnectionDisplay,
): ReadSignal<SessionStatus> => computed(() => sessionStatus(core.get(), display.displayed.get()))

/**
 * Why the app may be behind the server, for an indicator that tells the
 * user what is going on and whether a retry helps. One value, most
 * important first:
 *
 * - `starting`: the core has not reported yet, or is opening storage.
 * - `stopped`: the core is not running this session (`outdated`,
 *   `superseded`, `failed`, `signedOut`); `status` has the screen to show.
 * - `refused`: the server refused this session (revoked); sign-out follows.
 * - `offline`: the device has no network (`waitingForNetwork`). Actions that
 *   need a connection are refused with `offline`; sends wait in the outbox.
 * - `connecting`: the device has network and the app is reaching the
 *   server (shown by the rule 15 delay, like `connection`).
 * - `updating`: connected and catching up.
 * - `syncStalled`: connected, but some sync scopes stopped retrying: the
 *   server kept failing them (`retryable`: `retrySync` may help) or they
 *   need a refresh this build cannot do. Their data may be behind. Show a
 *   quiet indicator with a retry, not an error.
 * - `ok`.
 */
export type SessionHealth =
  | { readonly kind: "starting" }
  | { readonly kind: "stopped" }
  | { readonly kind: "refused" }
  | { readonly kind: "offline" }
  | { readonly kind: "connecting" }
  | { readonly kind: "updating" }
  | { readonly kind: "syncStalled"; readonly stalls: readonly SyncStall[]; readonly retryable: boolean }
  | { readonly kind: "ok" }

export const sessionHealth = (core: CoreResource | undefined, connection: DisplayedConnection | undefined): SessionHealth => {
  if (!core || core.phase === "starting") return { kind: "starting" }
  if (core.connection === "sessionRevoked") return { kind: "refused" }
  if (core.phase !== "ready") return { kind: "stopped" }
  if (connection === "waitingForNetwork") return { kind: "offline" }
  if (connection === "connecting") return { kind: "connecting" }
  if (connection === "updating") return { kind: "updating" }
  const stalls = core.stalledSync ?? []
  if (stalls.length > 0) {
    return { kind: "syncStalled", stalls, retryable: stalls.some((stall) => stall.reason === "retryLimit") }
  }
  return { kind: "ok" }
}

/** `sessionHealth` as a signal; equal values keep their identity. */
export const sessionHealthSignal = (
  core: ReadSignal<CoreResource | undefined>,
  display: ConnectionDisplay,
): ReadSignal<SessionHealth> =>
  computed(() => sessionHealth(core.get(), display.displayed.get()), { equals: plainEqual })

/**
 * Whether a stalled sync scope covers a chat: the account's own scope covers
 * everything; a space's covers its chats; a chat's covers that chat (by ID,
 * or by peer for a direct message). For a quiet "may be behind" note in a chat.
 */
export const isSyncStalledFor = (
  stalls: readonly SyncStall[],
  target: { readonly chatId: ChatID; readonly spaceId?: SpaceID; readonly peerUserId?: UserID },
): boolean =>
  stalls.some((stall) => {
    switch (stall.scope) {
      case "account":
        return true
      case "space":
        return stall.spaceId !== undefined && stall.spaceId === target.spaceId
      case "chat":
        return (
          (stall.chatId !== undefined && stall.chatId === target.chatId) ||
          (stall.peerUserId !== undefined && stall.peerUserId === target.peerUserId)
        )
    }
  })

/**
 * What replaces a chat's subtitle (rule 15: connection, then typing, then
 * other activity, then for direct messages bot status or local time). Typing,
 * activity and local time are not in the contract yet; the view passes what
 * it has.
 */
export type ChatSubtitle =
  | { readonly kind: "connection"; readonly state: DisplayedConnection }
  | { readonly kind: "typing"; readonly text: string }
  | { readonly kind: "bot" }
  | { readonly kind: "none" }

export const chatSubtitle = (input: {
  readonly connection: DisplayedConnection | undefined
  /** TODO(contract): typing is not on the protocol; pass the line when it is. */
  readonly typing?: string
  readonly isDirect: boolean
  readonly peerIsBot?: boolean
}): ChatSubtitle => {
  if (input.connection) return { kind: "connection", state: input.connection }
  if (input.typing) return { kind: "typing", text: input.typing }
  if (input.isDirect && input.peerIsBot) return { kind: "bot" }
  return { kind: "none" }
}
