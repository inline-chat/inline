/**
 * What the timeline shows around its rows: the "loading older" and "loading
 * newer" placeholders and the empty state. Pure; tested in `chrome.test.ts`.
 *
 * The older placeholder is a fixed-height reserve that is always in the
 * content, above the first row: its height never changes, so pages arriving
 * above the reader move nothing except through the controller's
 * compensation (the host contract wants the content's top padding fixed
 * while reading). The newer placeholder sits below the last row and exists
 * only while the rendered rows do not reach the live end; it is below
 * anything being read, so adding or removing it moves no row.
 */

import type { Range, TimelineWindow } from "@inline/timeline"

export type OlderEdge =
  /** Nothing older: the start of the conversation. */
  | "start"
  /** Older rows exist, loaded but not rendered or not loaded yet. */
  | "more"
  /** The core is loading an older page. */
  | "loading"

export type NewerEdge =
  /** The rendered rows reach the live end: no placeholder. */
  | "none"
  | "more"
  | "loading"

export type EdgeInput = {
  /** The core's window, when the caller passes one. */
  window: TimelineWindow | undefined
  range: Range
  /** Number of loaded items. */
  length: number
  /** The controller keeps the list hidden (opening at uncached unread history). */
  hidden: boolean
}

export const olderEdge = (input: EdgeInput): OlderEdge => {
  const { window, range } = input
  if (window?.loading === "older") return "loading"
  if (range.start > 0 || window?.hasOlder === true) return "more"
  return "start"
}

export const newerEdge = (input: EdgeInput): NewerEdge => {
  const { window, range, length } = input
  const reachesEnd = range.end >= length && (window === undefined || window.atLatest)
  if (reachesEnd) return "none"
  return window?.loading === "newer" ? "loading" : "more"
}

/**
 * The empty state shows only for a chat that really has no messages: nothing
 * loaded, the core not loading, the list not hidden. A chat whose rows are
 * still on their way shows nothing rather than a false "no messages".
 */
export const isEmpty = (input: EdgeInput): boolean =>
  input.length === 0 && !input.hidden && (input.window === undefined || input.window.loading === "none")
