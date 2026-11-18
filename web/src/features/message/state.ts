/**
 * The delivery state glyph beside an own message's time. Mac:
 * `Views/Message/MessageTimeAndState.swift` draws a clock while sending, a
 * checkmark once sent and a warning triangle when it failed, for outgoing
 * messages only.
 *
 * The web adds `uncertain` (the request was in flight when the connection
 * dropped). It must look neither failed nor delivered: a dotted circle, in
 * the muted tone of `sending`, with its own label.
 */

import type { MessageState } from "@inline/core-protocol"

export type StateGlyph = "clock" | "check" | "warning" | "unknown"

export type StatePresentation = {
  readonly state: MessageState
  readonly glyph: StateGlyph
  /** Accessible name and tooltip. */
  readonly label: string
  readonly tone: "muted" | "danger"
}

const presentations: Record<MessageState, StatePresentation> = {
  sending: { state: "sending", glyph: "clock", label: "Sending", tone: "muted" },
  sent: { state: "sent", glyph: "check", label: "Sent", tone: "muted" },
  failed: { state: "failed", glyph: "warning", label: "Failed to send", tone: "danger" },
  uncertain: { state: "uncertain", glyph: "unknown", label: "Not confirmed yet", tone: "muted" },
}

/**
 * The glyph for a message, or undefined for messages from others, which
 * show no state. An unknown state value (a newer core) reads as uncertain,
 * never as delivered or failed.
 */
export const statePresentation = (state: MessageState, out: boolean): StatePresentation | undefined => {
  if (!out) return undefined
  return presentations[state] ?? presentations.uncertain
}
