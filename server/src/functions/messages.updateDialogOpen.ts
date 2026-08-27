import type { Chat, Dialog, InputPeer, User } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { UsersModel } from "@in/server/db/models/users"
import { dialogFolders } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"
import { emitChatListOpenUpdates } from "@in/server/modules/subthreads"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type Input = {
  peerId: InputPeer
  open: boolean
  order?: string
  folderId?: number
}

type Output = {
  chat?: Chat
  dialog?: Dialog
  user?: User
}

export async function updateDialogOpen(input: Input, context: FunctionContext): Promise<Output> {
  if (
    (input.order != null && !FractionalIndex.isValid(input.order)) ||
    (input.folderId != null && (!input.open || !Number.isSafeInteger(input.folderId) || input.folderId <= 0))
  ) {
    throw RealtimeRpcError.BadRequest()
  }

  if (input.folderId != null) {
    const [folder] = await db
      .select({ id: dialogFolders.id })
      .from(dialogFolders)
      .where(and(eq(dialogFolders.id, input.folderId), eq(dialogFolders.userId, context.currentUserId)))
      .limit(1)
    if (!folder) {
      throw RealtimeRpcError.BadRequest()
    }
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const { dialogs, changedDialogs } = await setDialogOpenForUsers({
    chat,
    userIds: [context.currentUserId],
    open: input.open,
    order: input.order,
    folderId: input.folderId,
    showInChatList: false,
  })

  const dialog = dialogs.find((candidate) => candidate.userId === context.currentUserId)
  if (!dialog) {
    throw RealtimeRpcError.InternalError()
  }

  if (changedDialogs.length > 0) {
    await emitChatListOpenUpdates({
      chat,
      dialogs: changedDialogs,
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
