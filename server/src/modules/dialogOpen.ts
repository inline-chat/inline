import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import type { Transaction } from "@in/server/db/types"
import { dialogs, type DbChat, type DbDialog, type DbNewDialog } from "@in/server/db/schema"
import { and, desc, eq, inArray, isNotNull, isNull, or } from "drizzle-orm"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"

type ChatForDialogOpen = Pick<
  DbChat,
  "id" | "spaceId" | "type" | "minUserId" | "maxUserId" | "parentChatId" | "parentMessageId"
>
type DialogForOpenDefault = Pick<DbDialog, "open">
type DialogForOpenFields = Pick<DbDialog, "open" | "order">

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

/** Use this when making visibility decisions from stored dialog state. */
export function effectiveDialogOpenForDialog(dialog: DialogForOpenDefault): boolean {
  return dialog.open === true
}

/** Preserve tri-state over the wire: null means no authoritative open/close choice. */
export function encodedDialogOpen(dialog: DialogForOpenDefault): boolean | undefined {
  return dialog.open ?? undefined
}

/** Use this for new dialog rows so every write path follows the same defaulting rule. */
export function dialogOpenDefaultsForChat(
  chat: Pick<DbChat, "type">,
): Pick<DbNewDialog, "open"> & Partial<Pick<DbNewDialog, "order">> {
  if (defaultDialogOpenForChat(chat)) {
    return { open: true }
  }

  return { open: null }
}

/** Use this when a user action or incoming message explicitly opens an existing dialog. */
export function dialogOpenFieldsForOpen(
  dialog?: DialogForOpenFields,
  order?: string | null,
): Pick<DbNewDialog, "open"> & Partial<Pick<DbNewDialog, "order">> {
  if (dialog?.open === true && dialog.order) {
    return { open: true }
  }

  return { open: true, order: order ?? dialog?.order ?? FractionalIndex.after(null) }
}

export async function nextDialogOrder(
  tx: Transaction,
  userId: number,
  lane: "sidebar" | "pinned" = "sidebar",
): Promise<string> {
  const column = lane === "pinned" ? dialogs.pinnedOrder : dialogs.order
  const laneFilter =
    lane === "pinned"
      ? eq(dialogs.pinned, true)
      : and(eq(dialogs.open, true), or(isNull(dialogs.pinned), eq(dialogs.pinned, false)))
  const [lastDialog] = await tx
    .select({ order: column })
    .from(dialogs)
    .where(and(eq(dialogs.userId, userId), isNotNull(column), laneFilter))
    .orderBy(desc(column))
    .limit(1)

  return FractionalIndex.after(lastDialog?.order ?? null)
}

export async function setDialogOpenForUsers(input: {
  chat: ChatForDialogOpen
  userIds: number[]
  open: boolean
  order?: string | null
  showInChatList?: boolean
}): Promise<{ dialogs: DbDialog[]; changedDialogs: DbDialog[] }> {
  const userIds = await UsersModel.getActiveUserIds(uniqueUserIds(input.userIds))
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
      const showInChatList = input.showInChatList !== false
      const dialogsToOpen = existingDialogs.filter((dialog) => {
        if (dialog.open !== true || !dialog.order || dialog.archived === true) {
          return true
        }

        return showInChatList && dialog.chatListHidden === true
      })
      const missingUserIds = userIds.filter((userId) => !existingUserIds.has(userId))

      for (const dialog of dialogsToOpen) {
        const order =
          dialog.open === true && dialog.order
            ? undefined
            : await orderForUser(tx, dialog.userId, userIds.length, input.order)

        await tx
          .update(dialogs)
          .set({
            ...dialogOpenFieldsForOpen(dialog, order),
            archived: false,
            ...(showInChatList ? { chatListHidden: null } : {}),
          })
          .where(and(eq(dialogs.chatId, input.chat.id), eq(dialogs.userId, dialog.userId)))
        changedUserIds.add(dialog.userId)
      }

      if (missingUserIds.length > 0) {
        const rows: DbNewDialog[] = []

        for (const userId of missingUserIds) {
          rows.push({
            chatId: input.chat.id,
            userId,
            peerUserId: peerUserIdFor(input.chat, userId),
            spaceId: input.chat.spaceId ?? null,
            ...dialogOpenFieldsForOpen(undefined, await orderForUser(tx, userId, userIds.length, input.order)),
            archived: false,
            ...chatListVisibilityFieldsForOpen(input.chat, showInChatList),
          })
        }

        await tx
          .insert(dialogs)
          .values(rows)
          .onConflictDoNothing()
        missingUserIds.forEach((userId) => changedUserIds.add(userId))
      }
    } else {
      const persistCloseUserIds = existingDialogs
        .filter((dialog) => dialog.open !== false || dialog.openedDate != null || dialog.order != null)
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
            order: null,
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
              order: null,
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

async function orderForUser(
  tx: Transaction,
  userId: number,
  userCount: number,
  preferredOrder?: string | null,
): Promise<string> {
  if (userCount === 1 && preferredOrder) {
    return preferredOrder
  }

  return nextDialogOrder(tx, userId)
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

function chatListVisibilityFieldsForOpen(
  chat: ChatForDialogOpen,
  showInChatList: boolean,
): Partial<Pick<DbNewDialog, "chatListHidden">> {
  if (showInChatList) {
    return { chatListHidden: null }
  }

  if (chat.parentChatId != null || chat.parentMessageId != null) {
    return { chatListHidden: true }
  }

  return {}
}
