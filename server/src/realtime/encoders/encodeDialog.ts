import { Dialog, Peer } from "@inline-chat/protocol/core"
import type { DbDialog } from "@in/server/db/schema"
import { encodeDate } from "@in/server/realtime/encoders/helpers"
import { decodeDialogNotificationSettings } from "@in/server/modules/notifications/dialogNotificationSettings"
import { encodedDialogOpen } from "@in/server/modules/dialogOpen"
import { Log } from "@in/server/utils/log"

const log = new Log("encodeDialog")

// New encoders for Member and MinUser
export function encodeDialog(dialog: DbDialog, { unreadCount }: { unreadCount: number }): Dialog {
  let peer: Peer

  if (dialog.peerUserId) {
    peer = {
      type: {
        oneofKind: "user",
        user: {
          userId: BigInt(dialog.peerUserId),
        },
      },
    }
  } else if (dialog.chatId) {
    peer = {
      type: {
        oneofKind: "chat",
        chat: {
          chatId: BigInt(dialog.chatId),
        },
      },
    }
  } else {
    log.error("Invalid dialog", { dialog })
    throw new Error("Invalid dialog")
  }

  return {
    spaceId: dialog.spaceId ? BigInt(dialog.spaceId) : undefined,
    peer,
    chatId: BigInt(dialog.chatId),
    archived: dialog.archived ?? false,
    pinned: dialog.pinned ?? false,
    unreadCount: unreadCount,
    readMaxId: dialog.readInboxMaxId ? BigInt(dialog.readInboxMaxId) : undefined,
    unreadMark: dialog.unreadMark ?? undefined,
    notificationSettings: decodeDialogNotificationSettings(dialog.notificationSettings),
    open: encodedDialogOpen(dialog),
    openedDate: encodeDate(dialog.openedDate ?? undefined),
    order: dialog.order ?? undefined,
    pinnedOrder: dialog.pinnedOrder ?? undefined,
    sidebarVisible: dialog.chatListHidden !== true,
    chatListHidden: dialog.chatListHidden === true ? true : undefined,
  }
}
