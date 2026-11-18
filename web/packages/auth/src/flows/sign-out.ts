/**
 * Sign-out ordering, and the hook that tells a tab its account ended.
 *
 * Order (the Mac app notifies the server first too, MacLogoutCoordinator.swift):
 *
 * 1. Revoke the session on the server, best effort and bounded in time, while
 *    the token is still at hand.
 * 2. `AuthStore.logout()`: clears the stored session. With the browser
 *    persistence this writes the logout tombstone and broadcasts to the other
 *    tabs, whose stores then emit `logout` (persistence.ts `clear`,
 *    `notifyChanged`; core.ts `refreshFromStorage`).
 * 3. `eraseAccountData(userId)`: the app's hook into the core, which closes
 *    the account and erases the replica, media cache, boot snapshot and
 *    service worker caches. It runs after the credentials are gone, so the
 *    user is signed out even if erasing fails; the core must also erase a
 *    leftover replica at boot when no session owns it.
 */

import type { UserID } from "@inline/ids"
import type { AuthStore } from "../core"
import type { SignInApi } from "./api"
import type { Clock, TimerHandle } from "./clock"

export type SignOutResult = {
  userId: UserID | null
  /** `ok` also covers a session the server already rejects (401). */
  revoke: "ok" | "failed" | "skipped"
  erase: "ok" | "failed" | "skipped"
  /** Whether the cleared session reached storage. */
  storage: "ready" | "unavailable"
}

export type SignOutOptions = {
  authStore: AuthStore
  /** Without it the server session is left to expire. */
  api?: Pick<SignInApi, "logout">
  eraseAccountData?: (userId: UserID) => Promise<void>
  /** With a clock, the revoke is abandoned after `revokeTimeoutMs`. */
  clock?: Clock
  revokeTimeoutMs?: number
}

const DEFAULT_REVOKE_TIMEOUT_MS = 5_000

const inFlight = new WeakMap<AuthStore, Promise<SignOutResult>>()

/** Signs out. A second call while one is running joins it. */
export const signOut = (options: SignOutOptions): Promise<SignOutResult> => {
  const running = inFlight.get(options.authStore)
  if (running) return running
  const task = run(options).finally(() => {
    if (inFlight.get(options.authStore) === task) inFlight.delete(options.authStore)
  })
  inFlight.set(options.authStore, task)
  return task
}

const run = async (options: SignOutOptions): Promise<SignOutResult> => {
  const { authStore } = options
  const state = authStore.getState()
  const token = state.token
  const userId = state.currentUserId ?? state.userIdHint

  let revoke: SignOutResult["revoke"] = "skipped"
  if (token && options.api) {
    revoke = await revokeBounded(options, token)
  }

  await authStore.logout()
  const storage = authStore.getState().storageStatus === "ready" ? "ready" : "unavailable"

  let erase: SignOutResult["erase"] = "skipped"
  if (userId && options.eraseAccountData) {
    try {
      await options.eraseAccountData(userId)
      erase = "ok"
    } catch {
      erase = "failed"
    }
  }

  return { userId: userId ?? null, revoke, erase, storage }
}

const revokeBounded = async (
  options: SignOutOptions,
  token: string,
): Promise<SignOutResult["revoke"]> => {
  const request = options.api!.logout(token).then(
    (result): SignOutResult["revoke"] => {
      if (result.ok) return "ok"
      if (result.error.kind === "server" && result.error.status === 401) return "ok"
      if (result.error.kind === "accountDeactivated") return "ok"
      return "failed"
    },
    (): SignOutResult["revoke"] => "failed",
  )
  const clock = options.clock
  if (!clock) return request
  let timer: TimerHandle | undefined
  const timeout = new Promise<SignOutResult["revoke"]>((resolve) => {
    timer = clock.setTimeout(() => resolve("failed"), options.revokeTimeoutMs ?? DEFAULT_REVOKE_TIMEOUT_MS)
  })
  try {
    return await Promise.race([request, timeout])
  } finally {
    clock.clearTimeout(timer)
  }
}

/**
 * Calls `onAccountEnded(userId)` whenever the signed-in account of this tab
 * ends: a local sign-out, a sign-out in another tab (through the auth
 * package's broadcast), a revoked session the core reports with
 * `AuthStore.logout()`, or a switch to another user. The app closes the
 * account's views and returns to sign-in. Returns a function that stops
 * watching.
 */
export const watchAccountEnd = (
  authStore: AuthStore,
  onAccountEnded: (userId: UserID) => void,
): (() => void) => {
  let current = authStore.isLoggedIn() ? authStore.getState().currentUserId : null
  return authStore.subscribe((state) => {
    const next = state.token != null ? state.currentUserId : null
    const previous = current
    current = next
    if (previous != null && previous !== next) onAccountEnded(previous)
  })
}
