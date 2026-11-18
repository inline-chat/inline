/**
 * The updater's state holder. On the web the service worker glue (package
 * 2I) reports into it and installs the apply handler; in Electron the preload
 * bridge does. The platform only exposes the read side and `apply`.
 */

import { signal } from "@inline/reactive"
import type { Updater, UpdateState } from "./platform"

export interface UpdateFeed {
  /** The service worker glue (or the bridge) reports what it sees. */
  report(state: UpdateState): void
  /**
   * What `apply` does once an update is ready: on the web, tell the waiting
   * service worker to activate and reload. Replaces any earlier handler.
   */
  setApplyHandler(handler: (() => void) | null): void
}

const NONE: UpdateState = { status: "none" }

const sameState = (a: UpdateState, b: UpdateState): boolean =>
  a.status === b.status && (a.status === "none" || a.version === (b as { version?: string }).version)

export const createUpdateFeed = (): { updater: Updater; feed: UpdateFeed } => {
  const state = signal<UpdateState>(NONE, { equals: sameState })
  let handler: (() => void) | null = null
  return {
    updater: {
      state,
      apply() {
        if (state.peek().status !== "ready") return
        handler?.()
      },
    },
    feed: {
      report: (next) => state.set(next),
      setApplyHandler: (next) => {
        handler = next
      },
    },
  }
}
