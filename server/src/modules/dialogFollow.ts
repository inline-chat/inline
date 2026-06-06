import { DialogFollowMode, type Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import { dialogs, type DbChat, type DbDialog, type DbNewDialog } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, eq, inArray } from "drizzle-orm"

export const DIALOG_FOLLOWING = "following" as const

export type DbDialogFollowMode = typeof DIALOG_FOLLOWING

type ChatForFollow = Pick<
  DbChat,
  "id" | "spaceId" | "type" | "minUserId" | "maxUserId" | "parentChatId" | "parentMessageId"
>

export function encodeDialogFollowMode(followMode: DbDialog["followMode"]): DialogFollowMode | undefined {
  return followMode === DIALOG_FOLLOWING ? DialogFollowMode.FOLLOWING : undefined
}

export function decodeDialogFollowMode(followMode: DialogFollowMode | undefined): DbDialogFollowMode | null {
  return followMode === DialogFollowMode.FOLLOWING ? DIALOG_FOLLOWING : null
}

export function isValidDialogFollowMode(followMode: DialogFollowMode | undefined): boolean {
  return (
    followMode === undefined ||
    followMode === DialogFollowMode.DIALOG_FOLLOW_MODE_UNSPECIFIED ||
    followMode === DialogFollowMode.FOLLOWING
  )
}

export async function getFollowingDialogUserIds(input: {
  chatId: number
  userIds: number[]
}): Promise<number[]> {
  const userIds = uniqueUserIds(input.userIds)
  if (userIds.length === 0) {
    return []
  }

  const rows = await db
    .select({ userId: dialogs.userId })
    .from(dialogs)
    .where(
      and(
        eq(dialogs.chatId, input.chatId),
        inArray(dialogs.userId, userIds),
        eq(dialogs.followMode, DIALOG_FOLLOWING),
      ),
    )

  return rows.map((row) => row.userId)
}

export async function setDialogFollowModeForUsers(input: {
  chat: ChatForFollow
  userIds: number[]
  followMode: DbDialogFollowMode | null
  skipSessionId?: number
  pushRealtime?: boolean
}): Promise<{ dialogs: DbDialog[]; changedDialogs: DbDialog[]; updates: { userId: number; update: Update }[] }> {
  const userIds = await UsersModel.getActiveUserIds(uniqueUserIds(input.userIds))
  if (userIds.length === 0) {
    return { dialogs: [], changedDialogs: [], updates: [] }
  }

  const result = await db.transaction(async (tx) => {
    const existingDialogs = await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, userIds)))

    const existingUserIds = new Set(existingDialogs.map((dialog) => dialog.userId))
    const changedUserIds = new Set<number>()

    const updateUserIds = existingDialogs
      .filter((dialog) => dialog.followMode !== input.followMode)
      .map((dialog) => dialog.userId)

    if (updateUserIds.length > 0) {
      await tx
        .update(dialogs)
        .set({ followMode: input.followMode })
        .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, updateUserIds)))

      updateUserIds.forEach((userId) => changedUserIds.add(userId))
    }

    const missingUserIds =
      input.followMode === null
        ? []
        : userIds.filter((userId) => !existingUserIds.has(userId))

    if (missingUserIds.length > 0) {
      await tx
        .insert(dialogs)
        .values(
          missingUserIds.map((userId) => ({
            chatId: input.chat.id,
            userId,
            peerUserId: peerUserIdFor(input.chat, userId),
            spaceId: input.chat.spaceId ?? null,
            ...dialogOpenDefaultsForChat(input.chat),
            ...chatListVisibilityFields(input.chat),
            followMode: input.followMode,
          })),
        )
        .onConflictDoUpdate({
          target: [dialogs.chatId, dialogs.userId],
          set: { followMode: input.followMode },
        })

      missingUserIds.forEach((userId) => changedUserIds.add(userId))
    }

    if (changedUserIds.size > 0) {
      await enqueueFollowModeUpdates(tx, input.chat, Array.from(changedUserIds), input.followMode)
    }

    const finalDialogs = await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, userIds)))

    return {
      dialogs: finalDialogs,
      changedDialogs: finalDialogs.filter((dialog) => changedUserIds.has(dialog.userId)),
    }
  })

  const updates = result.changedDialogs.map((dialog) => ({
    userId: dialog.userId,
    update: buildFollowModeUpdate(input.chat, dialog.userId, input.followMode),
  }))

  if (input.pushRealtime !== false) {
    updates.forEach(({ userId, update }) => {
      RealtimeUpdates.pushToUser(userId, [update], { skipSessionId: input.skipSessionId })
    })
  }

  return { ...result, updates }
}

async function enqueueFollowModeUpdates(
  tx: Transaction,
  chat: ChatForFollow,
  userIds: number[],
  followMode: DbDialogFollowMode | null,
): Promise<void> {
  await UserBucketUpdates.enqueueMany(
    userIds.map((userId) => ({
      userId,
      update: {
        oneofKind: "userDialogFollowMode" as const,
        userDialogFollowMode: {
          peerId: encodeOutputPeerFromChat(chat as DbChat, { currentUserId: userId }),
          followMode: encodeDialogFollowMode(followMode),
        },
      } satisfies ServerUpdate["update"],
    })),
    { tx },
  )
}

function buildFollowModeUpdate(chat: ChatForFollow, userId: number, followMode: DbDialogFollowMode | null): Update {
  return {
    update: {
      oneofKind: "dialogFollowMode",
      dialogFollowMode: {
        peerId: encodeOutputPeerFromChat(chat as DbChat, { currentUserId: userId }),
        followMode: encodeDialogFollowMode(followMode),
      },
    },
  }
}

function uniqueUserIds(userIds: number[]): number[] {
  return Array.from(new Set(userIds.filter((userId) => Number.isSafeInteger(userId) && userId > 0)))
}

function peerUserIdFor(chat: ChatForFollow, userId: number): number | null {
  if (chat.type !== "private") {
    return null
  }

  if (chat.minUserId == null || chat.maxUserId == null) {
    return null
  }

  return chat.minUserId === userId ? chat.maxUserId : chat.minUserId
}

function chatListVisibilityFields(chat: ChatForFollow): Partial<Pick<DbNewDialog, "chatListHidden">> {
  return chat.parentChatId != null || chat.parentMessageId != null ? { chatListHidden: true } : {}
}
