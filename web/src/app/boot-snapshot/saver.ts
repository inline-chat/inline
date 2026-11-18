/**
 * Saves the boot snapshot of a running session: when the page is hidden
 * (`visibilitychange`) and on `pagehide`, the two signals browsers deliver
 * reliably (`beforeunload` and `unload` are not), once per hide; and, so a
 * crash does not lose everything, in the idle lane at most every
 * `throttleMs` while something changed. Erases it when the core says the
 * replica is outdated, erased (signed out) or not kept.
 */

import type { Dispose, IdleTask, ReadSignal } from "@inline/reactive"
import { effect, scope, untracked, type Clock } from "@inline/reactive"
import type { AccountSession } from "@inline/view/features"
import { captureBootSnapshot, type Capture } from "./capture"
import { eraseBootSnapshot, writeBootSnapshot, type SnapshotStorage } from "./storage"

/** Idle saves at most this often while the app is in use. */
export const SNAPSHOT_IDLE_INTERVAL_MS = 30_000

export type SaveReason = "hidden" | "pagehide" | "idle"

export type SaveResult =
  | {
      readonly reason: SaveReason
      readonly written: boolean
      /** Serialized length in UTF-16 code units. */
      readonly chars: number
      /** Capture, serialization and the storage write, in milliseconds. */
      readonly ms: number
      readonly dropped: Capture["dropped"]
    }
  | { readonly reason: SaveReason; readonly erased: true }

export type SaverSession = Pick<
  AccountSession,
  "userId" | "workspace" | "exportProvisional" | "coreResource" | "client" | "sidebar" | "disposed"
>

export type SaverOptions = {
  readonly session: SaverSession
  readonly storage: SnapshotStorage | undefined
  readonly buildId: string
  readonly clock: Clock
  readonly idle: (task: IdleTask) => () => void
  /** `pagehide`. */
  readonly onPageHide: (listener: () => void) => Dispose
  /** The page's visibility; hidden saves. */
  readonly visible?: ReadSignal<boolean>
  /** Wall clock in milliseconds, for `savedAt`. Default `Date.now`. */
  readonly now?: () => number
  /** A precise clock for the cost of a save (`performance.now`). Default `clock.now`. */
  readonly elapsed?: () => number
  readonly throttleMs?: number
  readonly onSave?: (result: SaveResult) => void
}

export type BootSnapshotSaver = {
  /** Save now (unless the core is not ready). */
  save(reason: SaveReason): SaveResult | undefined
  /** The last save's result. */
  readonly last: SaveResult | undefined
  dispose(): void
}

export const attachBootSnapshotSaver = (options: SaverOptions): BootSnapshotSaver => {
  const { session, storage, clock } = options
  const now = options.now ?? Date.now
  const elapsed = options.elapsed ?? (() => clock.now())
  const throttleMs = options.throttleMs ?? SNAPSHOT_IDLE_INTERVAL_MS
  let disposed = false
  let dirty = false
  let savedWhileHidden = false
  let timer: ReturnType<Clock["setTimeout"]> | undefined
  let cancelIdle: (() => void) | undefined
  let last: SaveResult | undefined

  const save = (reason: SaveReason): SaveResult | undefined => {
    if (disposed || session.disposed) return undefined
    const core = session.coreResource.peek()
    // Before the core is ready there is nothing newer than what is stored.
    if (core?.phase !== "ready" || core.storage === "memory") return undefined
    const started = elapsed()
    const capture = captureBootSnapshot(session, { buildId: options.buildId, now })
    dirty = false
    if (!capture) {
      eraseBootSnapshot(storage)
      last = { reason, erased: true }
    } else {
      const written = writeBootSnapshot(storage, capture.text)
      last = { reason, written, chars: capture.text.length, ms: elapsed() - started, dropped: capture.dropped }
    }
    options.onSave?.(last)
    return last
  }

  const schedule = () => {
    if (disposed || timer !== undefined || cancelIdle !== undefined) return
    timer = clock.setTimeout(() => {
      timer = undefined
      cancelIdle = options.idle(() => {
        cancelIdle = undefined
        if (dirty) save("idle")
        return false
      })
    }, throttleMs)
  }

  const hidden = (reason: SaveReason) => {
    if (savedWhileHidden) return
    // Only a save that ran counts: a page that starts hidden, before the core is ready, saves on pagehide.
    if (save(reason)) savedWhileHidden = true
  }

  const stop = scope(() => {
    // What the snapshot shows changed: the core's data, the open chat, the sidebar's mode.
    effect(() => {
      session.client.store.revision.get()
      session.workspace.focusedDestination.get()
      session.sidebar.mode.get()
      untracked(() => {
        dirty = true
        schedule()
      })
    })
    effect(() => {
      const core = session.coreResource.get()
      if (!core) return
      if (core.phase === "outdated" || core.phase === "signedOut" || core.storage === "memory") {
        untracked(() => eraseBootSnapshot(storage))
      }
    })
    if (options.visible) {
      const visible = options.visible
      effect(() => {
        const shown = visible.get()
        untracked(() => {
          if (shown) savedWhileHidden = false
          else hidden("hidden")
        })
      })
    }
  })
  const stopPageHide = options.onPageHide(() => hidden("pagehide"))

  return {
    save,
    get last() {
      return last
    },
    dispose: () => {
      if (disposed) return
      disposed = true
      stop()
      stopPageHide()
      if (timer !== undefined) clock.clearTimeout(timer)
      cancelIdle?.()
    },
  }
}
