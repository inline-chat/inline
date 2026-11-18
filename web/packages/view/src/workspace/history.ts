/**
 * History adapters: the small surface the workspace needs from a session
 * history. The browser adapter sits on the History API of an injected window;
 * the memory adapter is for tests and for windows that do not own an address
 * bar (an Electron window, a popout).
 */

export type HistoryLocation = {
  /** Path with query, for example `/c/1?x=2`. No origin, no hash. */
  readonly path: string
  /** The state object stored with the entry, or `null`. */
  readonly state: unknown
}

export interface HistoryAdapter {
  /** The entry the history is on now. */
  current(): HistoryLocation
  /** Add an entry after the current one, dropping any forward entries. */
  push(path: string, state: unknown): void
  /** Change the current entry in place. */
  replace(path: string, state: unknown): void
  /** Move by `delta` entries. Listeners hear about it, as they would of the user pressing Back. */
  go(delta: number): void
  /**
   * Listen for moves the adapter did not make itself through `push` or
   * `replace`: the user's Back and Forward, and `go`. In a browser this is
   * `popstate`, which arrives asynchronously; the memory adapter calls
   * listeners synchronously.
   */
  listen(listener: (location: HistoryLocation) => void): () => void
}

// MARK: - Memory

export type MemoryHistory = HistoryAdapter & {
  /** Every entry, oldest first. For tests and debugging. */
  entries(): readonly HistoryLocation[]
  /** The index of the current entry in `entries()`. */
  index(): number
  /** Shorthands for `go(-1)` and `go(1)`, like a user pressing the buttons. */
  back(): void
  forward(): void
}

export const createMemoryHistory = (initial: HistoryLocation | string = "/"): MemoryHistory => {
  const first = typeof initial === "string" ? { path: initial, state: null } : initial
  let entries: HistoryLocation[] = [first]
  let index = 0
  const listeners = new Set<(location: HistoryLocation) => void>()

  const at = (i: number): HistoryLocation => entries[i] ?? first

  const go = (delta: number) => {
    const target = index + Math.trunc(delta)
    // A browser ignores a move outside the stack; so does this.
    if (delta === 0 || target < 0 || target >= entries.length) return
    index = target
    const location = at(index)
    for (const listener of Array.from(listeners)) listener(location)
  }

  return {
    current: () => at(index),
    push: (path, state) => {
      entries = [...entries.slice(0, index + 1), { path, state }]
      index = entries.length - 1
    },
    replace: (path, state) => {
      entries = entries.map((entry, i) => (i === index ? { path, state } : entry))
    },
    go,
    back: () => go(-1),
    forward: () => go(1),
    listen: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    entries: () => entries,
    index: () => index,
  }
}

// MARK: - Browser

/** The parts of `window` the browser adapter uses. Injected, never read from globals. */
export type BrowserWindowLike = {
  readonly history: {
    readonly state: unknown
    pushState(state: unknown, unused: string, url?: string): void
    replaceState(state: unknown, unused: string, url?: string): void
    go(delta?: number): void
  }
  readonly location: { readonly pathname: string; readonly search: string }
  addEventListener(type: "popstate", listener: (event: { readonly state: unknown }) => void): void
  removeEventListener(type: "popstate", listener: (event: { readonly state: unknown }) => void): void
}

export const createBrowserHistory = (win: BrowserWindowLike): HistoryAdapter => {
  const current = (): HistoryLocation => ({
    path: `${win.location.pathname}${win.location.search}`,
    state: win.history.state ?? null,
  })
  return {
    current,
    push: (path, state) => win.history.pushState(state, "", path),
    replace: (path, state) => win.history.replaceState(state, "", path),
    go: (delta) => win.history.go(delta),
    listen: (listener) => {
      const onPop = () => listener(current())
      win.addEventListener("popstate", onPop)
      return () => win.removeEventListener("popstate", onPop)
    },
  }
}
