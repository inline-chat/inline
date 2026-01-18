import type { Update } from "@in/protocol/core"
import type { ServerUpdate } from "@in/protocol/server"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"
import type { DbChat } from "@in/server/db/schema"
import type { UpdateGroup } from "@in/server/modules/updates"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { and, eq, inArray } from "drizzle-orm"

type UnarchiveIfNeededInput = {
  chat: DbChat
  updateGroup: UpdateGroup
  senderUserId: number
}

type UnarchiveIfNeededOutput = {
  updates: { userId: number; update: Update }[]
}

export const unarchiveIfNeeded = async (input: UnarchiveIfNeededInput): Promise<UnarchiveIfNeededOutput> => {
  const { chat, updateGroup, senderUserId } = input
  const candidateUserIds = updateGroup.userIds.filter((userId) => userId !== senderUserId)
  if (candidateUserIds.length === 0) {
    return { updates: [] }
  }

  const archivedRows = await db
    .select({ userId: dialogs.userId })
    .from(dialogs)
    .where(
      and(
        eq(dialogs.chatId, chat.id),
        inArray(dialogs.userId, candidateUserIds),
        eq(dialogs.archived, true),
      ),
    )

  if (archivedRows.length === 0) {
    return { updates: [] }
  }

  const targets = archivedRows.map((row) => ({
    userId: row.userId,
    peerId: encodeOutputPeerFromChat(chat, { currentUserId: row.userId }),
  }))

  await db.transaction(async (tx) => {
    await tx
      .update(dialogs)
      .set({ archived: false })
      .where(
        and(
          eq(dialogs.chatId, chat.id),
          inArray(
            dialogs.userId,
            targets.map((target) => target.userId),
          ),
          eq(dialogs.archived, true),
        ),
      )

    for (const target of targets) {
      const userUpdate: ServerUpdate["update"] = {
        oneofKind: "userDialogArchived",
        userDialogArchived: {
          peerId: target.peerId,
          archived: false,
        },
      }

      await UserBucketUpdates.enqueue(
        {
          userId: target.userId,
          update: userUpdate,
        },
        { tx },
      )
    }
  })

  const updates = targets.map((target) => ({
    userId: target.userId,
    update: {
      update: {
        oneofKind: "dialogArchived" as const,
        dialogArchived: {
          peerId: target.peerId,
          archived: false,
        },
      },
    },
  }))

  return { updates }
}
