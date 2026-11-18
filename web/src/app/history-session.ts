/**
 * Browser history entries from before a sign-out read as `/`.
 *
 * A page cannot delete history entries: after an account ends, Back and
 * Forward can still reach the paths the ended account visited
 * (`/c/<id>/m/<id>`). Its data is erased, but the next account (or the
 * sign-in screen) would open those paths as deep links. So every entry the
 * app writes carries the history session it was written in (`inlineSession`
 * in `history.state`, beside the workspace binding's own stamp), the session
 * starts anew when an account ends (`endSession`), and an entry of an
 * earlier session is reported, on `popstate` and when read, as `/` (its
 * address is rewritten to `/` in place, also while signed out). An entry the app never wrote (the
 * first load, a typed URL) carries no session and is left alone.
 *
 * The session survives a reload in `sessionStorage` (per tab, like the
 * history itself); without it, a page adopts the session of the entry it
 * loaded on, so a reload alone never invalidates its own entries.
 *
 * Framework-free; `boot.ts` wraps the browser adapter once, and the runtime
 * calls `endSession` when an account ends.
 */

import type { HistoryAdapter, HistoryLocation } from "@inline/view"

/** Where the tab's history session is kept. */
export const HISTORY_SESSION_KEY = "inline:history-session"

const FIELD = "inlineSession"

type SessionStorageLike = Pick<Storage, "getItem" | "setItem">

export type SessionHistory = HistoryAdapter & {
  /** An account ended: entries written before now read as `/`, and the current entry becomes `/`. */
  endSession(): void
  /** The current history session (tests and diagnostics). */
  readonly session: () => string
}

const sessionOf = (state: unknown): string | undefined => {
  if (typeof state !== "object" || state === null) return undefined
  const value = (state as Record<string, unknown>)[FIELD]
  return typeof value === "string" ? value : undefined
}

const withSession = (state: unknown, session: string): Record<string, unknown> =>
  typeof state === "object" && state !== null && !Array.isArray(state)
    ? { ...(state as Record<string, unknown>), [FIELD]: session }
    : { [FIELD]: session }

const randomSession = (): string => {
  const bytes = new Uint8Array(8)
  globalThis.crypto.getRandomValues(bytes)
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

export const createSessionHistory = (
  inner: HistoryAdapter,
  options: { readonly storage?: SessionStorageLike | undefined; readonly newSession?: () => string } = {},
): SessionHistory => {
  const newSession = options.newSession ?? randomSession
  const read = (): string | undefined => {
    try {
      return options.storage?.getItem(HISTORY_SESSION_KEY) ?? undefined
    } catch {
      return undefined
    }
  }
  const store = (value: string) => {
    try {
      options.storage?.setItem(HISTORY_SESSION_KEY, value)
    } catch {
      // Storage unavailable: the session lives as long as the page.
    }
  }
  let session = read() ?? sessionOf(inner.current().state) ?? newSession()
  store(session)

  /** The entry as the app should see it: an earlier session's is `/` (and is rewritten so, once). */
  const present = (location: HistoryLocation): HistoryLocation => {
    const written = sessionOf(location.state)
    if (written === undefined || written === session) return location
    try {
      if (sessionOf(inner.current().state) === written) inner.replace("/", withSession(null, session))
    } catch {
      // A history the page may not write: still reported as `/`.
    }
    return { path: "/", state: null }
  }
  // Also while nothing else listens (signed out, the sign-in screen): Back to an
  // earlier session's entry shows `/` in the address bar at once. Registered
  // first, so it runs before any workspace binding's listener.
  inner.listen((location) => void present(location))

  return {
    current: () => present(inner.current()),
    push: (path, state) => inner.push(path, withSession(state, session)),
    replace: (path, state) => inner.replace(path, withSession(state, session)),
    go: (delta) => inner.go(delta),
    listen: (listener) => inner.listen((location) => listener(present(location))),
    endSession: () => {
      session = newSession()
      store(session)
      inner.replace("/", withSession(null, session))
    },
    session: () => session,
  }
}
