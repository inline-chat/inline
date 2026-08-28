import type { Chat, Dialog, DialogFolderDestination, InputPeer, User } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { dialogs, users } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { dialogOpenFieldsForOpen, nextDialogOrder } from "@in/server/modules/dialogOpen"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"
import { emitChatListOpenUpdates } from "@in/server/modules/subthreads"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import {
  encodeFolderDialogs,
  enqueueDialogFolderUpdate,
  folderChildren,
  ownedDialogFolder,
  pushDialogFolderUpdate,
  rootDialogFolderPositions,
} from "@in/server/modules/dialogFolders"

type Input = {
  peerId: InputPeer
  order?: string
  pinnedOrder?: string
  pinned?: boolean
  destination?: DialogFolderDestination
}

type Output = {
  chat: Chat
  dialog: Dialog
  user?: User
}

export async function updateDialogOrder(input: Input, context: FunctionContext): Promise<Output> {
  if (input.order == null && input.pinnedOrder == null && input.pinned == null && input.destination == null) {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.order != null && !FractionalIndex.isValid(input.order)) {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.pinnedOrder != null && !FractionalIndex.isValid(input.pinnedOrder)) {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.destination?.destination.oneofKind === "root" && input.destination.destination.root !== true) {
    throw RealtimeRpcError.BadRequest()
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const mutation = await db.transaction(async (tx) => {
    // Keep the dialog mutation and its subsequent user-bucket projection on
    // one deterministic owner path: users before dialogs.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, context.currentUserId)).for("update").limit(1)

    const whereClause = and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId))
    const [existingDialog] = await tx.select().from(dialogs).where(whereClause).limit(1)

    if (!existingDialog) {
      throw RealtimeRpcError.InternalError()
    }

    const nextUniqueDialogOrder = async (lane: "sidebar" | "pinned" = "sidebar") => {
      const base = await nextDialogOrder(tx, context.currentUserId, lane)
      const candidate = `${base}${existingDialog.id.toString(36).padStart(7, "0")}`
      if (!FractionalIndex.isValid(candidate)) {
        throw RealtimeRpcError.InternalError()
      }
      return candidate
    }

    const updateSet: Partial<typeof dialogs.$inferInsert> = {}
    if (input.order != null) {
      updateSet.order = input.order
    }
    if (input.pinnedOrder != null) {
      updateSet.pinnedOrder = input.pinnedOrder
    }

    if (input.pinned !== undefined) {
      updateSet.pinned = input.pinned

      if (input.pinned) {
        const order = input.order ?? existingDialog.order ?? (await nextUniqueDialogOrder())
        const pinnedOrder =
          input.pinnedOrder ?? existingDialog.pinnedOrder ?? (await nextUniqueDialogOrder("pinned"))

        Object.assign(updateSet, dialogOpenFieldsForOpen(existingDialog, order))
        updateSet.archived = false
        updateSet.chatListHidden = null
        updateSet.pinnedOrder = pinnedOrder
        updateSet.folderId = null
      } else if (input.order != null) {
        Object.assign(updateSet, dialogOpenFieldsForOpen(existingDialog, input.order))
        updateSet.archived = false
        updateSet.chatListHidden = null
      }
    }

    if (input.destination) {
      switch (input.destination.destination.oneofKind) {
        case "root": {
          updateSet.folderId = null
          updateSet.order = input.order ?? (await nextDialogOrder(tx, context.currentUserId))
          Object.assign(updateSet, dialogOpenFieldsForOpen(existingDialog, updateSet.order))
          updateSet.archived = false
          updateSet.chatListHidden = null
          break
        }
        case "folderId": {
          const folderId = Number(input.destination.destination.folderId)
          if (!Number.isSafeInteger(folderId) || folderId <= 0) {
            throw RealtimeRpcError.BadRequest()
          }
          const folder = await ownedDialogFolder(tx, context.currentUserId, folderId)
          if (!folder) throw RealtimeRpcError.BadRequest()
          const children = await folderChildren(tx, context.currentUserId, folder.id)
          const positions = await rootDialogFolderPositions(tx, {
            userId: context.currentUserId,
            excludingChatIds: [chat.id],
          })
          const right = positions.find((position) => position > folder.order)
          const childOrders = children
            .filter((child) => child.id !== existingDialog.id)
            .flatMap((child) => (child.order == null ? [] : [child.order]))
          const lastChildOrder = childOrders[childOrders.length - 1]
          updateSet.folderId = folder.id
          updateSet.order = input.order ?? FractionalIndex.between(lastChildOrder ?? folder.order, right)
          // Folder membership never creates a child pin; a pinned folder only preserves one.
          updateSet.pinned = folder.pinnedOrder != null && existingDialog.pinned === true
          Object.assign(updateSet, dialogOpenFieldsForOpen(existingDialog, updateSet.order))
          updateSet.archived = false
          updateSet.chatListHidden = null
          break
        }
        case undefined:
          throw RealtimeRpcError.BadRequest()
      }
    }

    const [dialog] = await tx.update(dialogs).set(updateSet).where(whereClause).returning()
    if (!dialog) return { dialog: undefined, folderUpdate: undefined }

    if (input.destination) {
      const [encodedDialog] = await encodeFolderDialogs(tx, [dialog])
      if (!encodedDialog) throw RealtimeRpcError.InternalError()
      const persisted = await enqueueDialogFolderUpdate({
        tx,
        userId: context.currentUserId,
        folderChange: { oneofKind: undefined },
        dialogs: [encodedDialog],
      })
      return { dialog, folderUpdate: persisted.update }
    }
    return { dialog, folderUpdate: undefined }
  })

  const dialog = mutation.dialog

  if (!dialog) {
    throw RealtimeRpcError.InternalError()
  }

  if (mutation.folderUpdate) {
    pushDialogFolderUpdate(context.currentUserId, mutation.folderUpdate, context.currentSessionId)
  } else {
    await emitChatListOpenUpdates({
      chat,
      dialogs: [dialog],
      skipSessionId: context.currentSessionId,
    })
  }

  const unreadCount = await DialogsModel.getUnreadCount(chat.id, context.currentUserId)
  const peerUser = dialog.peerUserId ? await UsersModel.getUserById(dialog.peerUserId) : undefined

  const output: Output = {
    chat: await Encoders.chatForUser(chat, { encodingForUserId: context.currentUserId }),
    dialog: Encoders.dialog(dialog, { unreadCount }),
  }

  if (peerUser) {
    output.user = Encoders.user({ user: peerUser, min: true })
  }

  return output
}
