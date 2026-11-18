/**
 * Turns a stored snapshot into what the session restores: the exported
 * subscriptions, with the chat window asked for again where the reader was,
 * so the core's window and the restored one share the message the timeline
 * holds.
 */

import type { ClientSnapshotData } from "@inline/reactive"
import type { BootSnapshot } from "./format"

export const provisionalData = (snapshot: BootSnapshot): ClientSnapshotData => {
  const around = snapshot.chat?.around
  return {
    ...snapshot.client,
    queries: snapshot.client.queries.map((entry) => {
      const query = entry.query
      if (query.kind !== "chatWindow") return entry
      // Around the saved place's message when there was one; otherwise the
      // session's default (unread, falling back to latest), which overlaps a
      // window that ended at the newest message.
      return { sub: entry.sub, query: { ...query, anchor: around ? { around } : "unread" } }
    }),
  }
}
