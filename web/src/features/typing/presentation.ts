/**
 * What a chat says about who is composing, worded and prioritized as the Mac
 * says it (`InlineKit/ViewModels/ComposeActions.swift` `getTypingDisplayText`,
 * `getActivityDisplayText`; `InlineMac/Features/Chat/Toolbar/
 * ChatRouteToolbarTitleModel.swift` `resolvedStatus`):
 *
 * - Typing wins over every other activity. In a direct message it is just
 *   "typing"; elsewhere it names people: "Ada is typing", "Ada and Alan are
 *   typing", "Ada, Alan and Grace are typing", "Ada, Alan and 2 others are
 *   typing" (the short form, for sidebar rows, says "Ada and 3 others are
 *   typing" from three people on).
 * - Otherwise one activity: agent work is "Working"; uploads and recording
 *   are "sending photo", "sending video", "sending file", "recording voice",
 *   and in a chat with several people they name the person by first name:
 *   "Ada is sending photo".
 *
 * Texts carry no trailing ellipsis: the Mac strips it and draws animated
 * dots; views add `…` (or the animation) themselves.
 *
 * Names come from the user rows the core sends with a `composeActions`
 * subscription. A person whose row is missing is left out, as on the Mac.
 * Pure and framework-free.
 */

import type { ComposeActionKind, ComposeActivity, UserRow } from "@inline/core-protocol"
import type { UserID } from "@inline/ids"
import { userDisplayName, userShortName } from "@inline/chat-ui"

/** What the subtitle shows and how (the Mac `Status` cases that use the accent color). */
export type ComposeStatus =
  | { readonly kind: "typing"; readonly text: string }
  | { readonly kind: "working"; readonly text: string }
  | { readonly kind: "recording"; readonly text: string }
  | { readonly kind: "sending"; readonly media: "photo" | "video" | "document"; readonly text: string }

/** `full` for the chat header, `short` for a sidebar row. */
export type TypingLength = "full" | "short"

const activityText: Record<Exclude<ComposeActionKind, "typing">, string> = {
  uploadingPhoto: "sending photo",
  uploadingDocument: "sending file",
  uploadingVideo: "sending video",
  recordingVoice: "recording voice",
  working: "Working",
}

/**
 * Which activity speaks for a chat when nobody is typing. The Mac takes
 * whichever entry its dictionary yields first; this picks deterministically
 * with the Mac's outgoing priority (recording, video, photo, file), then
 * agent work, then the core's order.
 */
const activityPriority: Record<ComposeActionKind, number> = {
  recordingVoice: 5,
  uploadingVideo: 4,
  uploadingPhoto: 3,
  uploadingDocument: 2,
  working: 1,
  typing: 0,
}

/**
 * A user's name inside an app sentence, isolated for bidirectional text
 * (FIRST STRONG ISOLATE … POP DIRECTIONAL ISOLATE). Without it a name in a
 * right-to-left script reorders the words around it: "عمر is typing" drew
 * as "is typing عمر", and two such names swapped places. The sentence itself
 * takes the interface's direction, so its element must not use `dir="auto"`.
 */
export const isolateName = (name: string): string => `\u2068${name}\u2069`

/** The typing line for these names, or undefined for none. */
export const typingText = (rawNames: readonly string[], isDirect: boolean, length: TypingLength = "full"): string | undefined => {
  const names = rawNames.map(isolateName)
  const [first, second, third] = names
  if (first === undefined) return undefined
  if (isDirect) return "typing"
  if (second === undefined) return `${first} is typing`
  if (names.length === 2) return `${first} and ${second} are typing`
  if (length === "short") return `${first} and ${names.length - 1} others are typing`
  if (names.length === 3) return `${first}, ${second} and ${third} are typing`
  return `${first}, ${second} and ${names.length - 2} others are typing`
}

export type ComposeStatusInput = {
  /** One chat's activities, in the core's order. */
  readonly activities: readonly ComposeActivity[]
  readonly isDirect: boolean
  readonly user: (userId: UserID) => UserRow | undefined
  readonly length?: TypingLength
}

/** The status a chat shows for its compose activity, or undefined when nobody is doing anything. */
export const composeStatus = (input: ComposeStatusInput): ComposeStatus | undefined => {
  const typingNames: string[] = []
  let activity: ComposeActivity | undefined
  for (const entry of input.activities) {
    if (entry.action === "typing") {
      const user = input.user(entry.userId)
      if (user) typingNames.push(userDisplayName(user))
    } else if (!activity || activityPriority[entry.action] > activityPriority[activity.action]) {
      activity = entry
    }
  }
  const typing = typingText(typingNames, input.isDirect, input.length)
  if (typing) return { kind: "typing", text: typing }
  if (!activity || activity.action === "typing") return undefined
  if (activity.action === "working") return { kind: "working", text: activityText.working }
  const base = activityText[activity.action]
  const user = input.isDirect ? undefined : input.user(activity.userId)
  const text = user ? `${isolateName(userShortName(user))} is ${base}` : base
  switch (activity.action) {
    case "recordingVoice":
      return { kind: "recording", text }
    case "uploadingPhoto":
      return { kind: "sending", media: "photo", text }
    case "uploadingVideo":
      return { kind: "sending", media: "video", text }
    case "uploadingDocument":
      return { kind: "sending", media: "document", text }
  }
}

/** Equal statuses compare equal, so computeds keep their identity. */
export const sameStatus = (a: ComposeStatus | undefined, b: ComposeStatus | undefined): boolean =>
  a === b || (a !== undefined && b !== undefined && a.kind === b.kind && a.text === b.text)
