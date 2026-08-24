import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import type { Transaction } from "@in/server/db/types"
import { chats, dialogFolders, dialogs, users, type DbChat, type DbDialog, type DbNewDialog } from "@in/server/db/schema"
import { and, asc, desc, eq, inArray, isNotNull, isNull, or } from "drizzle-orm"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"

export type DialogOpenPlacement = "top" | "bottom"

// Product default. Keep aligned with DialogOpenPlacement.defaultValue in InlineKit.
export const defaultDialogOpenPlacement: DialogOpenPlacement = "top"

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

  return {
    open: true,
    order: order ?? dialog?.order ?? dialogOrderAtPlacement(null, defaultDialogOpenPlacement),
  }
}

export async function nextDialogOrder(
  tx: Transaction,
  userId: number,
  lane: "sidebar" | "pinned" = "sidebar",
): Promise<string> {
  return dialogOrderForPlacement(tx, userId, "bottom", lane)
}

export async function dialogOrderForPlacement(
  tx: Transaction,
  userId: number,
  placement: DialogOpenPlacement,
  lane: "sidebar" | "pinned" = "sidebar",
  preferredOrder?: string | null,
): Promise<string> {
  // The user row is the database-owned serialization point for all derived
  // order allocations. Lock it before reading the edge so UPDATE_DIALOG_OPEN,
  // UPDATE_DIALOG_ORDER, and other dialog-opening paths cannot derive the same
  // fractional key on separate connections.
  await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("update").limit(1)

  const column = lane === "pinned" ? dialogs.pinnedOrder : dialogs.order
  const laneFilter =
    lane === "pinned"
      ? eq(dialogs.pinned, true)
      : and(
          eq(dialogs.open, true),
          or(isNull(dialogs.pinned), eq(dialogs.pinned, false)),
          isNull(dialogs.folderId),
        )
  const [edgeDialog] = await tx
    .select({ order: column })
    .from(dialogs)
    .where(and(eq(dialogs.userId, userId), isNotNull(column), laneFilter))
    .orderBy(placement === "top" ? asc(column) : desc(column))
    .limit(1)

  let edgeOrder = edgeDialog?.order
  const folderColumn = lane === "pinned" ? dialogFolders.pinnedOrder : dialogFolders.order
  const folderLaneFilter = lane === "pinned"
    ? isNotNull(dialogFolders.pinnedOrder)
    : isNull(dialogFolders.pinnedOrder)
  const [edgeFolder] = await tx
    .select({ order: folderColumn })
    .from(dialogFolders)
    .where(and(eq(dialogFolders.userId, userId), folderLaneFilter))
    .orderBy(placement === "top" ? asc(folderColumn) : desc(folderColumn))
    .limit(1)
  if (
    edgeFolder?.order != null &&
    (edgeOrder == null || (placement === "top" ? edgeFolder.order < edgeOrder : edgeFolder.order > edgeOrder))
  ) {
    edgeOrder = edgeFolder.order
  }

  return dialogOrderAtPlacement(edgeOrder, placement, preferredOrder)
}

export function dialogOrderAtPlacement(
  edgeOrder: string | null | undefined,
  placement: DialogOpenPlacement,
  preferredOrder?: string | null,
): string {
  const preferredOrderIsAtEdge =
    preferredOrder != null &&
    (edgeOrder == null || (placement === "top" ? preferredOrder < edgeOrder : preferredOrder > edgeOrder))
  if (preferredOrderIsAtEdge) {
    return preferredOrder
  }

  return placement === "top" ? FractionalIndex.before(edgeOrder) : FractionalIndex.after(edgeOrder)
}

export async function openPrimarySpaceChatForUser(input: {
  spaceId: number
  userId: number
  canAccessPublicChats: boolean
}): Promise<{ chat: DbChat; dialog: DbDialog; changed: boolean } | null> {
  if (!input.canAccessPublicChats) {
    return null
  }

  const [chat] = await db
    .select()
    .from(chats)
    .where(
      and(
        eq(chats.spaceId, input.spaceId),
        eq(chats.type, "thread"),
        eq(chats.publicThread, true),
        eq(chats.threadNumber, 1),
        isNull(chats.parentChatId),
      ),
    )
    .limit(1)
  if (!chat) {
    return null
  }

  const { dialogs: userDialogs, changedDialogs } = await setDialogOpenForUsers({
    chat,
    userIds: [input.userId],
    open: true,
    showInChatList: true,
  })
  const dialog = userDialogs.find((candidate) => candidate.userId === input.userId)
  if (!dialog) {
    return null
  }

  return {
    chat,
    dialog,
    changed: changedDialogs.some((candidate) => candidate.userId === input.userId),
  }
}

export async function setDialogOpenForUsers(input: {
  chat: ChatForDialogOpen
  userIds: number[]
  open: boolean
  order?: string | null
  openPlacementByUserId?: ReadonlyMap<number, DialogOpenPlacement>
  showInChatList?: boolean
}): Promise<{ dialogs: DbDialog[]; changedDialogs: DbDialog[] }> {
  // Every derived allocation below takes the owning user's row lock. Keep
  // multi-user batches in one order so overlapping batches cannot deadlock.
  const userIds = (await UsersModel.getActiveUserIds(uniqueUserIds(input.userIds))).sort((a, b) => a - b)
  if (userIds.length === 0) {
    return { dialogs: [], changedDialogs: [] }
  }

  return db.transaction(async (tx) => {
    // Acquire all user owners before touching any dialog rows. Projection
    // writers use the same users -> dialogs order, so overlapping batches do
    // not deadlock or derive a stale fractional order.
    for (const userId of userIds) {
      await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("update").limit(1)
    }

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
        const placement = input.openPlacementByUserId?.get(dialog.userId) ?? defaultDialogOpenPlacement
        const order =
          dialog.open === true && dialog.order
            ? undefined
            : await orderForUser(tx, dialog.userId, userIds.length, input.order, placement)

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
          const placement = input.openPlacementByUserId?.get(userId) ?? defaultDialogOpenPlacement
          rows.push({
            chatId: input.chat.id,
            userId,
            peerUserId: peerUserIdFor(input.chat, userId),
            spaceId: input.chat.spaceId ?? null,
            ...dialogOpenFieldsForOpen(
              undefined,
              await orderForUser(tx, userId, userIds.length, input.order, placement),
            ),
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
        .filter(
          (dialog) =>
            dialog.open !== false || dialog.openedDate != null || dialog.order != null || dialog.folderId != null,
        )
        .map((dialog) => dialog.userId)
      const changedCloseUserIds = existingDialogs
        .filter((dialog) => effectiveDialogOpenForDialog(dialog) || dialog.folderId != null)
        .map((dialog) => dialog.userId)
      const missingUserIds = userIds.filter((userId) => !existingUserIds.has(userId))

      if (persistCloseUserIds.length > 0) {
        await tx
          .update(dialogs)
          .set({
            open: false,
            openedDate: null,
            order: null,
            folderId: null,
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
  placement: DialogOpenPlacement = defaultDialogOpenPlacement,
): Promise<string> {
  return dialogOrderForPlacement(
    tx,
    userId,
    placement,
    "sidebar",
    userCount === 1 ? preferredOrder : undefined,
  )
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
