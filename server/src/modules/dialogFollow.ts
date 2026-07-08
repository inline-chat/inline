import { DialogFollowMode, type Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@in/server/protocol/server"
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
export const DIALOG_UNFOLLOWED = "unfollowed" as const

export type DbDialogFollowMode = typeof DIALOG_FOLLOWING | typeof DIALOG_UNFOLLOWED

type ChatForFollow = Pick<
  DbChat,
  "id" | "spaceId" | "type" | "minUserId" | "maxUserId" | "parentChatId" | "parentMessageId"
>

export function encodeDialogFollowMode(followMode: DbDialog["followMode"]): DialogFollowMode | undefined {
  switch (followMode) {
    case DIALOG_FOLLOWING:
      return DialogFollowMode.FOLLOWING
    case DIALOG_UNFOLLOWED:
      return DialogFollowMode.UNFOLLOWED
    default:
      return undefined
  }
}

export function decodeDialogFollowMode(followMode: DialogFollowMode | undefined): DbDialogFollowMode | null {
  switch (followMode) {
    case DialogFollowMode.FOLLOWING:
      return DIALOG_FOLLOWING
    case DialogFollowMode.UNFOLLOWED:
      return DIALOG_UNFOLLOWED
    default:
      return null
  }
}

export function isValidDialogFollowMode(followMode: DialogFollowMode | undefined): boolean {
  return (
    followMode === undefined ||
    followMode === DialogFollowMode.DIALOG_FOLLOW_MODE_UNSPECIFIED ||
    followMode === DialogFollowMode.FOLLOWING ||
    followMode === DialogFollowMode.UNFOLLOWED
  )
}

export async function getFollowingDialogUserIds(input: {
  chatId: number
  userIds: number[]
}): Promise<number[]> {
  return getDialogUserIdsByFollowMode({
    ...input,
    followMode: DIALOG_FOLLOWING,
  })
}

export async function getUnfollowedDialogUserIds(input: {
  chatId: number
  userIds: number[]
}): Promise<number[]> {
  return getDialogUserIdsByFollowMode({
    ...input,
    followMode: DIALOG_UNFOLLOWED,
  })
}

async function getDialogUserIdsByFollowMode(input: {
  chatId: number
  userIds: number[]
  followMode: DbDialogFollowMode
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
        eq(dialogs.followMode, input.followMode),
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
  showInChatList?: boolean
}): Promise<{
  dialogs: DbDialog[]
  changedDialogs: DbDialog[]
  unhiddenDialogs: DbDialog[]
  updates: { userId: number; update: Update }[]
}> {
  const userIds = await UsersModel.getActiveUserIds(uniqueUserIds(input.userIds))
  if (userIds.length === 0) {
    return { dialogs: [], changedDialogs: [], unhiddenDialogs: [], updates: [] }
  }

  const result = await db.transaction(async (tx) => {
    const existingDialogs = await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, userIds)))

    const existingUserIds = new Set(existingDialogs.map((dialog) => dialog.userId))
    const changedUserIds = new Set<number>()
    const followModeChangedUserIds = new Set<number>()
    const shouldShowInChatList = input.showInChatList === true && input.followMode === DIALOG_FOLLOWING

    const followModeUpdateUserIds = existingDialogs
      .filter((dialog) => dialog.followMode !== input.followMode)
      .map((dialog) => dialog.userId)
    const visibilityUpdateUserIds =
      shouldShowInChatList
        ? existingDialogs
            .filter((dialog) => dialog.chatListHidden === true)
            .map((dialog) => dialog.userId)
        : []
    const updateUserIds = Array.from(new Set([...followModeUpdateUserIds, ...visibilityUpdateUserIds]))

    if (updateUserIds.length > 0) {
      await tx
        .update(dialogs)
        .set({
          followMode: input.followMode,
          ...(shouldShowInChatList ? { chatListHidden: null } : {}),
        })
        .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, updateUserIds)))

      updateUserIds.forEach((userId) => changedUserIds.add(userId))
      followModeUpdateUserIds.forEach((userId) => followModeChangedUserIds.add(userId))
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
            ...chatListVisibilityFields(input.chat, shouldShowInChatList),
            followMode: input.followMode,
          })),
        )
        .onConflictDoUpdate({
          target: [dialogs.chatId, dialogs.userId],
          set: {
            followMode: input.followMode,
            ...(shouldShowInChatList ? { chatListHidden: null } : {}),
          },
        })

      missingUserIds.forEach((userId) => changedUserIds.add(userId))
      missingUserIds.forEach((userId) => followModeChangedUserIds.add(userId))
    }

    if (followModeChangedUserIds.size > 0) {
      await enqueueFollowModeUpdates(tx, input.chat, Array.from(followModeChangedUserIds), input.followMode)
    }

    const finalDialogs = await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, userIds)))

    const unhiddenUserIds = new Set(visibilityUpdateUserIds)

    return {
      dialogs: finalDialogs,
      changedDialogs: finalDialogs.filter((dialog) => changedUserIds.has(dialog.userId)),
      unhiddenDialogs: finalDialogs.filter((dialog) => unhiddenUserIds.has(dialog.userId)),
      followModeChangedDialogs: finalDialogs.filter((dialog) => followModeChangedUserIds.has(dialog.userId)),
    }
  })

  const updates = result.followModeChangedDialogs.map((dialog) => ({
    userId: dialog.userId,
    update: buildFollowModeUpdate(input.chat, dialog.userId, input.followMode),
  }))

  if (input.pushRealtime !== false) {
    updates.forEach(({ userId, update }) => {
      RealtimeUpdates.pushToUser(userId, [update], { skipSessionId: input.skipSessionId })
    })
  }

  return {
    dialogs: result.dialogs,
    changedDialogs: result.changedDialogs,
    unhiddenDialogs: result.unhiddenDialogs,
    updates,
  }
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

function chatListVisibilityFields(
  chat: ChatForFollow,
  showInChatList: boolean,
): Partial<Pick<DbNewDialog, "chatListHidden">> {
  if (showInChatList) {
    return { chatListHidden: null }
  }

  return chat.parentChatId != null || chat.parentMessageId != null ? { chatListHidden: true } : {}
}
