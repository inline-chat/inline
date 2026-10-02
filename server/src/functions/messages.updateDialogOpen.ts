import type { Chat, Dialog, InputPeer, User } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { UsersModel } from "@in/server/db/models/users"
import { chats, dialogFolders, users } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { setDialogOpenForUsersInTransaction } from "@in/server/modules/dialogOpen"
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

  const requestedChat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(requestedChat, context.currentUserId)

  const { chat, dialogs, changedDialogs } = await db.transaction(async (tx) => {
    // Wait for the user's current workbench state before protecting the chat.
    // This permits draft cleanup to finish its DELETE upgrade without a cycle.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, context.currentUserId)).for("no key update").limit(1)
    const [chat] = await tx.select().from(chats).where(eq(chats.id, requestedChat.id)).for("key share").limit(1)
    if (!chat) throw RealtimeRpcError.ChatIdInvalid()
    const access = await getEffectiveChatAccessUserIds(tx, [chat.id], { userIds: [context.currentUserId] })
    if (!access.get(chat.id)?.has(context.currentUserId)) throw RealtimeRpcError.PeerIdInvalid()

    const result = await setDialogOpenForUsersInTransaction(tx, {
      chat,
      userIds: [context.currentUserId],
      open: input.open,
      order: input.order,
      folderId: input.folderId,
      showInChatList: false,
    })
    return { chat, ...result }
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
