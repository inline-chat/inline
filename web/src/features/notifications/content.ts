/**
 * What a message notification says: the title and one-line body, by the Mac
 * rules (`MacNotifications.handleNewMessage`, `MessageNotificationPreview`),
 * and the message facts the policy needs that the row carries directly.
 *
 * Every piece of user text goes through `previewText` from `@inline/chat-ui`:
 * one line, control and bidi override characters removed, cut on a grapheme
 * boundary. The body is exactly what `previewText` returns, never more.
 */

import { previewText, serviceFallbackText, userDisplayName } from "@inline/chat-ui"
import type { ChatRow, MessageRow, SpaceRow, UserRow } from "@inline/core-protocol"

/** Mac `MessageNotificationPreview.preview` keeps at most 240 characters. */
export const NOTIFICATION_BODY_GRAPHEMES = 240
/** Names and titles are one short line (Mac `singleLine` at 256 bytes). */
export const NOTIFICATION_TITLE_GRAPHEMES = 80

const URGENT_NUDGE_TEXT = "\u{1F6A8}"

/** A nudge (`media.kind === "nudge"`). */
export const isNudge = (message: MessageRow): boolean => message.media?.kind === "nudge"

/** Mac `isUrgentNudge`: a nudge whose text is exactly the siren emoji. */
export const isUrgentNudge = (message: MessageRow): boolean =>
  isNudge(message) && message.text.trim() === URGENT_NUDGE_TEXT

/** Call transcript service messages never notify (Mac: `gridTranscript`). */
export const isCallTranscript = (message: MessageRow): boolean => message.service?.kind === "gridTranscript"

const voiceLabel = (seconds: number): string => {
  if (!(seconds > 0)) return "Voice message"
  const whole = Math.floor(seconds)
  return `Voice message (${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")})`
}

/**
 * The text of a notification body before it is cut, by the Mac rules: a
 * service message's fallback text; a nudge's label; a media prefix with the
 * caption or, without one, the media's name; else the text, or "New message".
 */
const rawBody = (message: MessageRow): string => {
  if (message.service) {
    const fallback = serviceFallbackText(message)
    if (fallback !== undefined) return fallback
  }
  const text = message.text.trim()
  const media = message.media
  let prefix = ""
  let fallback = "New message"
  switch (media?.kind) {
    case "nudge":
      return text === URGENT_NUDGE_TEXT ? "\u{1F6A8} Urgent nudge" : "\u{1F44B} Nudge"
    case "photo":
      prefix = "\u{1F5BC}\u{FE0F} "
      fallback = media.sticker ? "Sticker" : "Photo"
      break
    case "video":
      prefix = media.sticker ? "\u{1F5BC}\u{FE0F} " : media.video.animated ? "\u{1F39E}\u{FE0F} " : "\u{1F3A5} "
      fallback = media.sticker ? "Sticker" : media.video.animated ? "GIF" : "Video"
      break
    case "document":
      prefix = "\u{1F4C4} "
      fallback = previewText(media.document.fileName, { maxGraphemes: NOTIFICATION_TITLE_GRAPHEMES }) || "Document"
      break
    case "voice":
      prefix = "\u{1F3A4} "
      fallback = voiceLabel(media.voice.duration)
      break
    case undefined:
      break
  }
  return `${prefix}${text.length > 0 ? text : fallback}`
}

/** One line of body text, at most `NOTIFICATION_BODY_GRAPHEMES` graphemes. */
export const notificationBody = (message: MessageRow): string =>
  previewText(rawBody(message), { maxGraphemes: NOTIFICATION_BODY_GRAPHEMES, fallback: "New message" })

export type NotificationContentInput = {
  readonly message: MessageRow
  readonly sender: UserRow | undefined
  readonly chat: ChatRow | undefined
  /** The chat's space, for a thread title ("Design (Acme)"). */
  readonly space?: SpaceRow | undefined
  /** A direct message: the title is the sender. Otherwise the chat is a thread. */
  readonly isDirect: boolean
  /** The chat's title as the app shows it (`ChatModel.header.title`). */
  readonly chatTitle?: string
}

export type NotificationContent = { readonly title: string; readonly body: string }

const line = (text: string, fallback: string): string =>
  previewText(text, { maxGraphemes: NOTIFICATION_TITLE_GRAPHEMES, fallback })

/**
 * Title and body. A direct message: the sender's name over the preview. A
 * thread: the thread's title (with its space) over "Sender: preview"; the
 * Mac puts the sender in a subtitle, which page notifications do not have.
 */
export const notificationContent = (input: NotificationContentInput): NotificationContent => {
  const sender = input.sender ? line(userDisplayName(input.sender), "Unknown") : "Unknown"
  const body = notificationBody(input.message)
  if (input.isDirect) return { title: sender, body }
  const chatName = line(input.chatTitle ?? input.chat?.title ?? "", "New Message")
  const spaceName = input.space ? line(input.space.name, "") : ""
  const title = spaceName.length > 0 ? line(`${chatName} (${spaceName})`, chatName) : chatName
  return {
    title,
    body: previewText(`${sender}: ${body}`, { maxGraphemes: NOTIFICATION_BODY_GRAPHEMES, fallback: body }),
  }
}
