import { getChatAcknowledgements } from "@in/server/db/models/acknowledgements"
import { DialogsModel } from "@in/server/db/models/dialogs"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { DbChat, DbDialog } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { resolveChatPermissions } from "@in/server/modules/authorization/chatPermissions"
import { openPrimarySpaceChatForUserInTransaction } from "@in/server/modules/dialogOpen"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { Chat, Dialog, Update } from "@inline-chat/protocol/core"

export type PersistedUserChatOpenProjection = {
  userId: number
  chatRow: DbChat
  dialogRow: DbDialog
  chat: Chat
  dialog: Dialog
  update: UpdateSeqAndDate
}

/**
 * Opens a space's primary chat and records the complete user-bucket snapshot in
 * the caller's transaction. Membership writers should pass
 * `persistWhenUnchanged` after a real add: a dialog row may survive an earlier
 * removal, but the new membership still needs replay evidence. Retry-only
 * callers leave it false so an already-authoritative dialog stays idempotent.
 */
export async function persistPrimarySpaceChatOpenProjectionInTransaction(
  tx: Transaction,
  input: {
    spaceId: number
    userId: number
    canAccessPublicChats: boolean
    persistWhenUnchanged?: boolean
  },
): Promise<PersistedUserChatOpenProjection | null> {
  const opened = await openPrimarySpaceChatForUserInTransaction(tx, input)
  if (!opened || (!opened.changed && input.persistWhenUnchanged !== true)) {
    return null
  }

  // These reads intentionally use the caller's transaction. The encoded
  // snapshot must reflect the membership, dialog, permissions, unread state,
  // and acknowledgement rows that commit with its user-bucket sequence.
  const permissions = await resolveChatPermissions(opened.chat, input.userId, tx)
  const unreadCount = await DialogsModel.getUnreadCount(opened.dialog.chatId, input.userId, tx)
  const acknowledgementCursors = (await getChatAcknowledgements([opened.chat.id], { tx })).get(opened.chat.id) ?? []
  const chat = {
    ...Encoders.chat(opened.chat, { encodingForUserId: input.userId, permissions }),
    acknowledgements: { cursors: acknowledgementCursors },
  }
  const dialog = Encoders.dialog(opened.dialog, { unreadCount })
  const update = await UserBucketUpdates.enqueue(
    {
      userId: input.userId,
      update: {
        oneofKind: "userChatOpen",
        userChatOpen: { chat, dialog },
      },
    },
    { tx },
  )

  return {
    userId: input.userId,
    chatRow: opened.chat,
    dialogRow: opened.dialog,
    chat,
    dialog,
    update,
  }
}

export function liveUpdateForPersistedUserChatOpenProjection(
  projection: PersistedUserChatOpenProjection,
): Update {
  return {
    seq: projection.update.seq,
    date: encodeDateStrict(projection.update.date),
    update: {
      oneofKind: "chatOpen",
      chatOpen: {
        chat: projection.chat,
        dialog: projection.dialog,
      },
    },
  }
}

export function pushPersistedUserChatOpenProjection(
  projection: PersistedUserChatOpenProjection,
  options?: { skipSessionId?: number },
): void {
  RealtimeUpdates.pushToUser(
    projection.userId,
    [liveUpdateForPersistedUserChatOpenProjection(projection)],
    options,
  )
}
