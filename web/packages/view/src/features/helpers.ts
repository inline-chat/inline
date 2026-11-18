/**
 * Small pure helpers shared by the feature models: chat titles and avatars by
 * the Mac rules, the chat a destination shows, and ID ordering.
 */

import type { ChatRow, DialogRow, UserRow } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { userAvatarSeed, userDisplayName } from "@inline/chat-ui"
import type { Destination } from "../workspace/destination"

/** The chat a destination shows, if any. A thread destination shows the thread. */
export const destinationChatId = (destination: Destination): ChatID | undefined => {
  switch (destination.kind) {
    case "chat":
    case "message":
    case "chatInfo":
      return destination.chatId
    case "thread":
      return destination.threadId
    default:
      return undefined
  }
}

/**
 * Order two message IDs (positive int64 decimal strings). Canonical decimals
 * compare by length, then lexically, which avoids a BigInt per comparison.
 */
export const compareMessageIds = (a: MessageID, b: MessageID): number => {
  if (a.length !== b.length) return a.length < b.length ? -1 : 1
  return a < b ? -1 : a > b ? 1 : 0
}

/** The peer of a direct message, from whichever row knows it. */
export const peerUserIdOf = (dialog: DialogRow | undefined, chat: ChatRow | undefined): UserID | undefined =>
  dialog?.peerUserId ?? chat?.peerUserId

/**
 * A chat's title, by the Mac sidebar rule (`ChatListItem.displayTitle`,
 * `Chat.humanReadableTitle`): a direct message shows the peer's name; a
 * thread its trimmed title, else "New thread"; anything unknown "Chat".
 *
 * The Mac sidebar shows only the peer's first name; the web uses the full
 * display name from `chat-ui` (`userDisplayName`), as the chat header does.
 */
export const chatTitle = (chat: ChatRow | undefined, peer: UserRow | undefined, peerUserId?: UserID): string => {
  const isDirect = peerUserId !== undefined || chat?.peerUserId !== undefined
  if (isDirect && peer) return userDisplayName(peer)
  const title = chat?.title?.trim()
  if (title) return title
  // Every chat that is not a direct message is a thread in Inline.
  if (chat && !isDirect) return "New thread"
  return "Chat"
}

/** What an avatar view needs: a user's photo and seed, or a chat's emoji and seed. */
export type AvatarInput =
  | { readonly kind: "user"; readonly userId: UserID; readonly seed: string; readonly photoUrl?: string }
  | { readonly kind: "chat"; readonly chatId: ChatID; readonly seed: string; readonly emoji?: string }

export const chatAvatar = (
  chatId: ChatID,
  chat: ChatRow | undefined,
  peer: UserRow | undefined,
  peerUserId: UserID | undefined,
): AvatarInput => {
  if (peerUserId !== undefined) {
    return {
      kind: "user",
      userId: peerUserId,
      seed: userAvatarSeed(peer),
      ...(peer?.photoUrl ? { photoUrl: peer.photoUrl } : {}),
    }
  }
  return {
    kind: "chat",
    chatId,
    seed: chat?.title?.trim() || "New thread",
    ...(chat?.emoji ? { emoji: chat.emoji } : {}),
  }
}
