/**
 * This user's own compose activity in one chat, reported to the core with
 * the `composeAction` intent, after the Mac (`ComposeActions.swift`,
 * `startedTyping`, `stoppedTyping`, `beginActivity`, `endActivity`):
 *
 * - `noteTyping()` (the composer calls it on input) sends `typing` at once,
 *   then at most every 3 s (`COMPOSE_ACTION_RULE.refreshMs`) while typing
 *   continues; the other side expires it 6 s after the last one.
 * - `stopTyping()` (the composer emptied, or the message was sent) sends a
 *   stop, only if typing was sent since the last stop. The next keystroke
 *   sends `typing` again at once.
 * - `beginActivity(kind)` (an upload, a voice recording) returns an `end`
 *   function. Activities are counted per chat: several uploads share one
 *   status, the strongest is shown (recording, video, photo, file), and the
 *   stop goes out when the last one ends. While one runs, typing is not
 *   reported and `stopTyping` sends nothing, so it cannot clear the upload.
 *   The core refreshes an ongoing activity every 3 s itself.
 * - `dispose()` (the chat closed) stops whatever was reported.
 *
 * Time is the injected clock's. Sends are best effort: the core drops them
 * offline and never stores them.
 */

import type { ComposeActionKind } from "@inline/core-protocol"
import { COMPOSE_ACTION_RULE } from "@inline/core-protocol"
import type { ChatID } from "@inline/ids"
import { effect, untracked, type Clock, type ReadSignal, type StoreClient } from "@inline/reactive"

export type OutgoingActivityKind = Exclude<ComposeActionKind, "typing" | "working">

/** The Mac's `outgoingPriority`. */
const priority: Record<OutgoingActivityKind, number> = {
  recordingVoice: 4,
  uploadingVideo: 3,
  uploadingPhoto: 2,
  uploadingDocument: 1,
}

export type ComposeReporter = {
  noteTyping(): void
  stopTyping(): void
  /** Start an upload or recording; call the returned function when it ends (safe to call twice). */
  beginActivity(kind: OutgoingActivityKind): () => void
  /** The action currently reported, for tests and diagnostics. */
  readonly current: () => ComposeActionKind | null
  /**
   * Follow a composer document: a change of revision with text reports
   * typing, one that leaves it empty (cleared after a send, or deleted)
   * stops it. The first value (a restored draft) reports nothing.
   * Returns a function that stops following.
   */
  followComposer(doc: ReadSignal<{ readonly text: string; readonly revision: number }>): () => void
  dispose(): void
}

export const createComposeReporter = (options: {
  readonly chatId: ChatID
  readonly clock: Pick<Clock, "now">
  /** Default: `client.intent({ kind: "composeAction", chatId, action })`. */
  readonly send?: (action: ComposeActionKind | null) => void
  readonly client?: Pick<StoreClient, "intent">
}): ComposeReporter => {
  const { chatId, clock } = options
  const send =
    options.send ??
    ((action: ComposeActionKind | null) => {
      const handle = options.client?.intent({ kind: "composeAction", chatId, action })
      // Best effort: a refusal or a stopped core changes nothing for the user.
      handle?.catch(() => undefined)
    })

  let lastTypingSent: number | undefined
  let typingSent = false
  const activities = new Map<number, OutgoingActivityKind>()
  let nextActivity = 1
  let reported: OutgoingActivityKind | null = null
  let disposed = false

  const strongest = (): OutgoingActivityKind | null => {
    let best: OutgoingActivityKind | null = null
    for (const kind of activities.values()) if (best === null || priority[kind] > priority[best]) best = kind
    return best
  }

  const syncActivity = () => {
    const next = strongest()
    if (next === reported) return
    reported = next
    if (next !== null) {
      send(next)
    } else {
      // The stop that ends the upload also ends any typing reported before it.
      send(null)
      typingSent = false
      lastTypingSent = undefined
    }
  }

  const noteTyping = () => {
    if (disposed || activities.size > 0) return
    const now = clock.now()
    if (lastTypingSent !== undefined && now - lastTypingSent < COMPOSE_ACTION_RULE.refreshMs) return
    lastTypingSent = now
    typingSent = true
    send("typing")
  }

  const stopTyping = () => {
    if (disposed || activities.size > 0) return
    lastTypingSent = undefined
    if (!typingSent) return
    typingSent = false
    send(null)
  }

  return {
    noteTyping,
    stopTyping,
    beginActivity: (kind) => {
      if (disposed) return () => undefined
      const id = nextActivity++
      activities.set(id, kind)
      syncActivity()
      return () => {
        if (!activities.delete(id) || disposed) return
        syncActivity()
      }
    },
    current: () => reported ?? (typingSent ? "typing" : null),
    followComposer: (doc) => {
      let first = true
      let revision = -1
      return effect(() => {
        const value = doc.get()
        untracked(() => {
          if (first) {
            first = false
            revision = value.revision
            return
          }
          if (value.revision === revision) return
          revision = value.revision
          if (value.text.trim().length > 0) noteTyping()
          else stopTyping()
        })
      })
    },
    dispose: () => {
      if (disposed) return
      if (reported !== null || typingSent) send(null)
      disposed = true
      activities.clear()
      reported = null
      typingSent = false
    },
  }
}
