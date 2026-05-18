import type { Chat, Dialog, InputPeer } from "@inline-chat/protocol/core"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  emitChatListOpenUpdates,
  ensureLinkedSubthreadDialogs,
  getDialogForUser,
  isLinkedSubthread,
  promoteLinkedSubthreadDialogsToChatList,
} from "@in/server/modules/subthreads"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type Input = {
  peerId: InputPeer
}

type Output = {
  chat: Chat
  dialog: Dialog
}

export async function showInChatList(input: Input, context: FunctionContext): Promise<Output> {
  if (input.peerId.type.oneofKind !== "chat") {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  let dialog = await getDialogForUser(chat.id, context.currentUserId)

  if (isLinkedSubthread(chat)) {
    const { dialogs, activatedDialogs } = await promoteLinkedSubthreadDialogsToChatList({
      chat,
      userIds: [context.currentUserId],
    })

    if (activatedDialogs.length > 0) {
      await emitChatListOpenUpdates({
        chat,
        dialogs: activatedDialogs,
      })
    }

    dialog = dialogs.find((candidate) => candidate.userId === context.currentUserId) ?? dialog
  } else if (!dialog) {
    const { dialogs } = await ensureLinkedSubthreadDialogs({
      chat,
      userIds: [context.currentUserId],
    })
    dialog = dialogs.find((candidate) => candidate.userId === context.currentUserId)
  }

  if (!dialog) {
    throw RealtimeRpcError.InternalError()
  }

  const unreadCount = await DialogsModel.getUnreadCount(chat.id, context.currentUserId)

  return {
    chat: Encoders.chat(chat, { encodingForUserId: context.currentUserId }),
    dialog: Encoders.dialog(dialog, { unreadCount }),
  }
}
