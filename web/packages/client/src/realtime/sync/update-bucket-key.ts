import type { Peer, Update } from "@inline-chat/protocol/core"
import { spaceId } from "@inline/ids"
import type { SyncBucketKey } from "./sync-types"

const chatPeer = (chatId: bigint | number | undefined): Peer | undefined => {
  if (chatId == null) return undefined
  return {
    type: {
      oneofKind: "chat",
      chat: { chatId: BigInt(chatId) },
    },
  }
}

const chatKey = (peer?: Peer): SyncBucketKey | undefined => {
  if (!peer || peer.type.oneofKind === undefined) return undefined
  return { kind: "chat", peer }
}

const inferredUpdateBucketKey = (
  update: Update,
): SyncBucketKey | undefined => {
  switch (update.update.oneofKind) {
    case "newMessage":
      return chatKey(
        update.update.newMessage.message?.peerId ??
          chatPeer(update.update.newMessage.message?.chatId),
      )
    case "editMessage":
      return chatKey(
        update.update.editMessage.message?.peerId ??
          chatPeer(update.update.editMessage.message?.chatId),
      )
    case "deleteMessages":
      return chatKey(update.update.deleteMessages.peerId)
    case "updateMessageId":
      return { kind: "user" }
    case "updateComposeAction":
      return chatKey(update.update.updateComposeAction.peerId)
    case "updateUserStatus":
      return { kind: "user" }
    case "messageAttachment":
      return chatKey(
        update.update.messageAttachment.peerId ??
          chatPeer(update.update.messageAttachment.chatId),
      )
    case "updateReaction":
      return chatKey(chatPeer(update.update.updateReaction.reaction?.chatId))
    case "deleteReaction":
      return chatKey(chatPeer(update.update.deleteReaction.chatId))
    case "deleteChat":
      return chatKey(update.update.deleteChat.peerId)
    case "markAsUnread":
      return { kind: "user" }
    case "newChat":
      return chatKey(update.update.newChat.chat?.peerId)
    case "chatMoved":
      return chatKey(update.update.chatMoved.chat?.peerId)
    case "chatVisibility":
      return chatKey(chatPeer(update.update.chatVisibility.chatId))
    case "chatInfo":
      return chatKey(chatPeer(update.update.chatInfo.chatId))
    case "chatPermissions":
      return { kind: "user" }
    case "pinnedMessages":
      return chatKey(update.update.pinnedMessages.peerId)
    case "participantAdd":
      return chatKey(chatPeer(update.update.participantAdd.chatId))
    case "participantDelete":
      return chatKey(chatPeer(update.update.participantDelete.chatId))
    case "participantGroupAdd":
      return chatKey(chatPeer(update.update.participantGroupAdd.chatId))
    case "participantGroupDelete":
      return chatKey(chatPeer(update.update.participantGroupDelete.chatId))
    case "clearChatHistory":
      if (update.update.clearChatHistory.target.oneofKind === "peerId") {
        return chatKey(update.update.clearChatHistory.target.peerId)
      }
      if (update.update.clearChatHistory.target.oneofKind === "spaceId") {
        return {
          kind: "space",
          spaceId: spaceId(update.update.clearChatHistory.target.spaceId),
        }
      }
      return undefined
    case "newMessageNotification":
      return chatKey(
        update.update.newMessageNotification.message?.peerId ??
          chatPeer(
            update.update.newMessageNotification.message?.chatId,
          ),
      )
    case "chatSkipPts":
      return chatKey(chatPeer(update.update.chatSkipPts.chatId))
    case "chatHasNewUpdates":
      return chatKey(
        update.update.chatHasNewUpdates.peerId ??
          chatPeer(update.update.chatHasNewUpdates.chatId),
      )
    case "spaceHasNewUpdates":
      return {
        kind: "space",
        spaceId: spaceId(
          update.update.spaceHasNewUpdates.spaceId,
        ),
      }
    case "spaceMemberAdd":
      return update.update.spaceMemberAdd.member
        ? {
            kind: "space",
            spaceId: spaceId(update.update.spaceMemberAdd.member.spaceId),
          }
        : undefined
    case "spaceMemberDelete":
      return {
        kind: "space",
        spaceId: spaceId(update.update.spaceMemberDelete.spaceId),
      }
    case "spaceMemberUpdate":
      return update.update.spaceMemberUpdate.member
        ? {
            kind: "space",
            spaceId: spaceId(update.update.spaceMemberUpdate.member.spaceId),
          }
        : undefined
    case "joinSpace":
    case "updatedUser":
    case "updateUserSettings":
    case "dialogArchived":
    case "dialogNotificationSettings":
    case "updateReadMaxId":
    case "chatOpen":
    case "dialogFollowMode":
    case "messageActionAnswered":
      return { kind: "user" }
    case "messageActionInvoked":
      return chatKey(
        chatPeer(update.update.messageActionInvoked.chatId),
      )
    case "botPresence":
      return chatKey(update.update.botPresence.peerId)
    case "spaceSettings":
      return {
        kind: "space",
        spaceId: spaceId(update.update.spaceSettings.spaceId),
      }
    case undefined:
      return undefined
  }
}

/**
 * Some wire update kinds are produced by more than one persisted bucket. The
 * flattened protocol payload does not carry its originating bucket, so those
 * cases must be treated as ambiguous instead of guessing and corrupting an
 * unrelated cursor.
 */
export const updateBucketKeys = (
  update: Update,
): SyncBucketKey[] => {
  const inferred = inferredUpdateBucketKey(update)
  switch (update.update.oneofKind) {
    case "participantAdd":
    case "participantDelete":
    case "participantGroupAdd":
    case "participantGroupDelete":
      return inferred
        ? [{ kind: "user" }, inferred]
        : [{ kind: "user" }]
    case "spaceMemberDelete":
      return inferred
        ? [{ kind: "user" }, inferred]
        : [{ kind: "user" }]
    default:
      return inferred ? [inferred] : []
  }
}

export const updateBucketKey = (
  update: Update,
): SyncBucketKey | undefined => {
  const keys = updateBucketKeys(update)
  return keys.length === 1 ? keys[0] : undefined
}
