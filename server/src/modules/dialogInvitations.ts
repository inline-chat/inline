import { dialogs, users, type DbChat, type DbDialog } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { DIALOG_FOLLOWING, DIALOG_UNFOLLOWED, enqueueFollowModeUpdates } from "@in/server/modules/dialogFollow"
import { setDialogOpenForUsersInTransaction } from "@in/server/modules/dialogOpen"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { and, eq, inArray } from "drizzle-orm"

/** Initialize a private invitation in the membership transaction, without
 * reopening/refollowing a user's explicitly unfollowed conversation. */
export async function initializeInvitedDialogs(
  tx: Transaction,
  input: { chat: DbChat; userIds: number[] },
): Promise<{ dialogs: DbDialog[]; changedDialogs: DbDialog[] }> {
  if (input.chat.publicThread === true) return { dialogs: [], changedDialogs: [] }
  const userIds = Array.from(new Set(input.userIds)).sort((a, b) => a - b)
  if (userIds.length === 0) return { dialogs: [], changedDialogs: [] }
  for (const userId of userIds) {
    await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("no key update").limit(1)
  }
  const previous = await tx
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, userIds)))
  const previouslyUnfollowed = new Set(
    previous.filter((dialog) => dialog.followMode === DIALOG_UNFOLLOWED).map((dialog) => dialog.userId),
  )
  const eligibleUserIds = userIds.filter((userId) => !previouslyUnfollowed.has(userId))
  if (eligibleUserIds.length === 0) return { dialogs: previous, changedDialogs: [] }
  const { changedDialogs: openedDialogs } = await setDialogOpenForUsersInTransaction(tx, {
    chat: input.chat,
    userIds: eligibleUserIds,
    open: true,
    showInChatList: true,
  })
  const alreadyFollowing = new Set(
    previous.filter((dialog) => dialog.followMode === DIALOG_FOLLOWING).map((dialog) => dialog.userId),
  )
  const followUserIds = eligibleUserIds.filter((userId) => !alreadyFollowing.has(userId))
  if (followUserIds.length > 0) {
    await tx
      .update(dialogs)
      .set({ followMode: DIALOG_FOLLOWING })
      .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, followUserIds)))
    await enqueueFollowModeUpdates(tx, input.chat, followUserIds, DIALOG_FOLLOWING)
  }
  const changedUserIds = new Set([...openedDialogs.map((dialog) => dialog.userId), ...followUserIds])
  const finalDialogs = await tx
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, userIds)))
  const changedDialogs = finalDialogs.filter((dialog) => changedUserIds.has(dialog.userId))
  for (const dialog of changedDialogs) {
    await UserBucketUpdates.enqueue(
      {
        userId: dialog.userId,
        update: {
          oneofKind: "userChatOpen",
          userChatOpen: {
            chat: await Encoders.chatForUser(input.chat, { encodingForUserId: dialog.userId, tx }),
            dialog: Encoders.dialog(dialog, {
              unreadCount: await DialogsModel.getUnreadCount(input.chat.id, dialog.userId, tx),
            }),
          },
        },
      },
      { tx },
    )
  }
  return { dialogs: finalDialogs, changedDialogs }
}
