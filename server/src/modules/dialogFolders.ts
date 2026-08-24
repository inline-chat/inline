import type { Dialog, DialogFolder, Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { DialogsModel } from "@in/server/db/models/dialogs"
import {
  dialogFolders,
  dialogs,
  type DbDialog,
  type DbDialogFolder,
} from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, asc, eq, isNotNull, isNull, ne, notInArray, or } from "drizzle-orm"

export type DialogFolderChange =
  | { oneofKind: "folder"; folder: DialogFolder }
  | { oneofKind: "deletedFolderId"; deletedFolderId: bigint }
  | { oneofKind: undefined }

export async function encodeFolderDialogs(tx: Transaction, rows: DbDialog[]): Promise<Dialog[]> {
  const result: Dialog[] = []
  for (const dialog of rows) {
    const unreadCount = await DialogsModel.getUnreadCount(dialog.chatId, dialog.userId, tx)
    result.push(Encoders.dialog(dialog, { unreadCount }))
  }
  return result
}

export async function enqueueDialogFolderUpdate(input: {
  tx: Transaction
  userId: number
  folderChange: DialogFolderChange
  dialogs: Dialog[]
}): Promise<{ update: Update; seq: number; date: Date }> {
  const stored = await UserBucketUpdates.enqueue(
    {
      userId: input.userId,
      update: {
        oneofKind: "userDialogFolder",
        userDialogFolder: {
          folderChange: input.folderChange,
          dialogs: input.dialogs,
        },
      },
    },
    { tx: input.tx },
  )

  return {
    seq: stored.seq,
    date: stored.date,
    update: {
      seq: stored.seq,
      date: encodeDateStrict(stored.date),
      update: {
        oneofKind: "dialogFolder",
        dialogFolder: {
          folderChange: input.folderChange,
          dialogs: input.dialogs,
        },
      },
    },
  }
}

export function pushDialogFolderUpdate(
  userId: number,
  update: Update,
  skipSessionId?: number,
): void {
  RealtimeUpdates.pushToUser(
    userId,
    [update],
    skipSessionId === undefined ? undefined : { skipSessionId },
  )
}

export async function rootDialogFolderPositions(
  tx: Transaction,
  input: {
    userId: number
    excludingFolderId?: number
    excludingChatIds?: number[]
  },
): Promise<string[]> {
  const dialogConditions = [
    eq(dialogs.userId, input.userId),
    eq(dialogs.open, true),
    or(isNull(dialogs.pinned), eq(dialogs.pinned, false)),
    isNull(dialogs.folderId),
    isNotNull(dialogs.order),
  ]
  if (input.excludingChatIds && input.excludingChatIds.length > 0) {
    dialogConditions.push(notInArray(dialogs.chatId, input.excludingChatIds))
  }

  const folderConditions = [
    eq(dialogFolders.userId, input.userId),
    isNull(dialogFolders.pinnedOrder),
  ]
  if (input.excludingFolderId !== undefined) {
    folderConditions.push(ne(dialogFolders.id, input.excludingFolderId))
  }

  const dialogRows = await tx
    .select({ order: dialogs.order })
    .from(dialogs)
    .where(and(...dialogConditions))
    .orderBy(asc(dialogs.order))
  const folderRows = await tx
    .select({ order: dialogFolders.order })
    .from(dialogFolders)
    .where(and(...folderConditions))
    .orderBy(asc(dialogFolders.order))

  return [...dialogRows, ...folderRows]
    .flatMap((row) => (row.order == null ? [] : [row.order]))
    .sort()
}

export async function folderChildren(
  tx: Transaction,
  userId: number,
  folderId: number,
): Promise<DbDialog[]> {
  return tx
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.userId, userId), eq(dialogs.folderId, folderId)))
    .orderBy(asc(dialogs.order), asc(dialogs.id))
}

export async function ownedDialogFolder(
  tx: Transaction,
  userId: number,
  folderId: number,
): Promise<DbDialogFolder | undefined> {
  const [folder] = await tx
    .select()
    .from(dialogFolders)
    .where(and(eq(dialogFolders.id, folderId), eq(dialogFolders.userId, userId)))
    .limit(1)
  return folder
}

export async function getDialogFolders(userId: number): Promise<DbDialogFolder[]> {
  return db
    .select()
    .from(dialogFolders)
    .where(eq(dialogFolders.userId, userId))
    .orderBy(asc(dialogFolders.order), asc(dialogFolders.id))
}
