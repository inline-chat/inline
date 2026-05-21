import type { Chat, Dialog, InputPeer, User } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { dialogs } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { dialogOpenFieldsForOpen, nextDialogOrder } from "@in/server/modules/dialogOpen"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"
import { emitChatListOpenUpdates } from "@in/server/modules/subthreads"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type Input = {
  peerId: InputPeer
  order?: string
  pinnedOrder?: string
  pinned?: boolean
}

type Output = {
  chat: Chat
  dialog: Dialog
  user?: User
}

export async function updateDialogOrder(input: Input, context: FunctionContext): Promise<Output> {
  if (input.order == null && input.pinnedOrder == null && input.pinned == null) {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.order != null && !FractionalIndex.isValid(input.order)) {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.pinnedOrder != null && !FractionalIndex.isValid(input.pinnedOrder)) {
    throw RealtimeRpcError.BadRequest()
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const dialog = await db.transaction(async (tx) => {
    const whereClause = and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId))
    const [existingDialog] = await tx.select().from(dialogs).where(whereClause).limit(1)

    if (!existingDialog) {
      throw RealtimeRpcError.InternalError()
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
        const order = input.order ?? existingDialog.order ?? (await nextDialogOrder(tx, context.currentUserId))
        const pinnedOrder =
          input.pinnedOrder ?? existingDialog.pinnedOrder ?? (await nextDialogOrder(tx, context.currentUserId, "pinned"))

        Object.assign(updateSet, dialogOpenFieldsForOpen(existingDialog, order))
        updateSet.archived = false
        updateSet.chatListHidden = null
        updateSet.pinnedOrder = pinnedOrder
      } else if (input.order != null) {
        Object.assign(updateSet, dialogOpenFieldsForOpen(existingDialog, input.order))
        updateSet.archived = false
        updateSet.chatListHidden = null
      }
    }

    const [dialog] = await tx.update(dialogs).set(updateSet).where(whereClause).returning()
    return dialog
  })

  if (!dialog) {
    throw RealtimeRpcError.InternalError()
  }

  await emitChatListOpenUpdates({
    chat,
    dialogs: [dialog],
    skipSessionId: context.currentSessionId,
  })

  const unreadCount = await DialogsModel.getUnreadCount(chat.id, context.currentUserId)
  const peerUser = dialog.peerUserId ? await UsersModel.getUserById(dialog.peerUserId) : undefined

  const output: Output = {
    chat: Encoders.chat(chat, { encodingForUserId: context.currentUserId }),
    dialog: Encoders.dialog(dialog, { unreadCount }),
  }

  if (peerUser) {
    output.user = Encoders.user({ user: peerUser, min: false })
  }

  return output
}
