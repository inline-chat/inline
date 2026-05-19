import { db } from "@in/server/db"
import { dialogs, type DbChat, type DbDialog, type DbNewDialog } from "@in/server/db/schema"
import { and, eq, inArray } from "drizzle-orm"

type ChatForDialogOpen = Pick<DbChat, "id" | "spaceId" | "type" | "minUserId" | "maxUserId">
type DialogForOpenDefault = Pick<DbDialog, "open">

// Sidebar inbox state is tri-state by design:
// - true: explicitly shown in the sidebar inbox
// - false: explicitly removed from the sidebar inbox
// - null: no user choice yet; currently treated as closed
//
// New-row product defaults are still materialized here at insert time. That
// lets new DM rows start open while old/null rows remain closed until a write
// explicitly opens them.

export function defaultDialogOpenForChat(chat: Pick<DbChat, "type">): boolean {
  return chat.type === "private"
}

/** Use this when encoding an existing dialog without the chat row. */
export function effectiveDialogOpenForDialog(dialog: DialogForOpenDefault): boolean {
  return dialog.open === true
}

/** Use this for new dialog rows so every write path follows the same defaulting rule. */
export function dialogOpenDefaultsForChat(
  chat: Pick<DbChat, "type">,
  now: Date = new Date(),
): Pick<DbNewDialog, "open" | "openedDate"> {
  if (defaultDialogOpenForChat(chat)) {
    return { open: true, openedDate: now }
  }

  return { open: null, openedDate: null }
}

/** Use this when a user action or incoming message explicitly opens an existing dialog. */
export function dialogOpenFieldsForOpen(
  dialog?: Pick<DbDialog, "open">,
  now: Date = new Date(),
): Pick<DbNewDialog, "open"> & Partial<Pick<DbNewDialog, "openedDate">> {
  if (dialog?.open === true) {
    return { open: true }
  }

  return { open: true, openedDate: now }
}

export async function setDialogOpenForUsers(input: {
  chat: ChatForDialogOpen
  userIds: number[]
  open: boolean
}): Promise<{ dialogs: DbDialog[]; changedDialogs: DbDialog[] }> {
  const userIds = uniqueUserIds(input.userIds)
  if (userIds.length === 0) {
    return { dialogs: [], changedDialogs: [] }
  }

  return db.transaction(async (tx) => {
    const existingDialogs = await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, userIds)))

    const existingUserIds = new Set(existingDialogs.map((dialog) => dialog.userId))
    const changedUserIds = new Set<number>()

    if (input.open) {
      const now = new Date()
      const transitionUserIds = existingDialogs
        .filter((dialog) => dialog.open !== true)
        .map((dialog) => dialog.userId)
      const cleanupUserIds = existingDialogs
        .filter((dialog) => dialog.open === true && (dialog.archived === true || dialog.chatListHidden === true))
        .map((dialog) => dialog.userId)
      const missingUserIds = userIds.filter((userId) => !existingUserIds.has(userId))

      if (transitionUserIds.length > 0) {
        await tx
          .update(dialogs)
          .set({
            ...dialogOpenFieldsForOpen(undefined, now),
            archived: false,
            chatListHidden: null,
          })
          .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, transitionUserIds)))
        transitionUserIds.forEach((userId) => changedUserIds.add(userId))
      }

      if (cleanupUserIds.length > 0) {
        await tx
          .update(dialogs)
          .set({
            archived: false,
            chatListHidden: null,
          })
          .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, cleanupUserIds)))
        cleanupUserIds.forEach((userId) => changedUserIds.add(userId))
      }

      if (missingUserIds.length > 0) {
        await tx
          .insert(dialogs)
          .values(
            missingUserIds.map((userId) => ({
              chatId: input.chat.id,
              userId,
              peerUserId: peerUserIdFor(input.chat, userId),
              spaceId: input.chat.spaceId ?? null,
              ...dialogOpenFieldsForOpen(undefined, now),
              archived: false,
              chatListHidden: null,
            })),
          )
          .onConflictDoNothing()
        missingUserIds.forEach((userId) => changedUserIds.add(userId))
      }
    } else {
      const persistCloseUserIds = existingDialogs
        .filter((dialog) => dialog.open !== false || dialog.openedDate != null)
        .map((dialog) => dialog.userId)
      const changedCloseUserIds = existingDialogs
        .filter((dialog) => effectiveDialogOpenForDialog(dialog))
        .map((dialog) => dialog.userId)
      const missingUserIds = userIds.filter((userId) => !existingUserIds.has(userId))

      if (persistCloseUserIds.length > 0) {
        await tx
          .update(dialogs)
          .set({
            open: false,
            openedDate: null,
          })
          .where(and(eq(dialogs.chatId, input.chat.id), inArray(dialogs.userId, persistCloseUserIds)))
        changedCloseUserIds.forEach((userId) => changedUserIds.add(userId))
      }

      if (missingUserIds.length > 0) {
        await tx
          .insert(dialogs)
          .values(
            missingUserIds.map((userId) => ({
              chatId: input.chat.id,
              userId,
              peerUserId: peerUserIdFor(input.chat, userId),
              spaceId: input.chat.spaceId ?? null,
              open: false,
              openedDate: null,
            })),
          )
          .onConflictDoNothing()
      }
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
}

function uniqueUserIds(userIds: number[]): number[] {
  return Array.from(new Set(userIds.filter((userId) => Number.isSafeInteger(userId) && userId > 0)))
}

function peerUserIdFor(chat: ChatForDialogOpen, userId: number): number | null {
  if (chat.type !== "private") {
    return null
  }

  if (chat.minUserId == null || chat.maxUserId == null) {
    return null
  }

  return chat.minUserId === userId ? chat.maxUserId : chat.minUserId
}
