import type { DialogFollowMode, InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { DialogsModel } from "@in/server/db/models/dialogs"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import {
  DIALOG_FOLLOWING,
  decodeDialogFollowMode,
  isValidDialogFollowMode,
  setDialogFollowModeForUsers,
} from "@in/server/modules/dialogFollow"
import {
  emitChatListOpenUpdates,
  isLinkedSubthread,
  showAndOpenLinkedSubthreadDialogs,
} from "@in/server/modules/subthreads"
import { canUseThreadFollowMode } from "@in/server/modules/threadAutoFollow"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type Input = {
  peerId: InputPeer
  followMode?: DialogFollowMode
}

type Output = {
  updates: Update[]
}

export const updateDialogFollowMode = async (input: Input, context: FunctionContext): Promise<Output> => {
  if (!isValidDialogFollowMode(input.followMode)) {
    throw RealtimeRpcError.BadRequest()
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  if (!canUseThreadFollowMode(chat)) {
    throw RealtimeRpcError.BadRequest()
  }

  const followMode = decodeDialogFollowMode(input.followMode)
  const { changedDialogs: followChangedDialogs, updates } = await setDialogFollowModeForUsers({
    chat,
    userIds: [context.currentUserId],
    followMode,
    showInChatList: followMode === DIALOG_FOLLOWING,
    skipSessionId: context.currentSessionId,
  })

  const responseUpdates = updates.map(({ update }) => update)

  if (followMode === DIALOG_FOLLOWING) {
    const { dialogs, changedDialogs: openChangedDialogs } = isLinkedSubthread(chat)
      ? await showAndOpenLinkedSubthreadDialogs({
          chat,
          userIds: [context.currentUserId],
        })
      : await setDialogOpenForUsers({
          chat,
          userIds: [context.currentUserId],
          open: true,
        })

    const dialog = dialogs.find((candidate) => candidate.userId === context.currentUserId)
    if (!dialog) {
      throw RealtimeRpcError.InternalError()
    }

    const changedUserIds = new Set([
      ...followChangedDialogs.map((changedDialog) => changedDialog.userId),
      ...openChangedDialogs.map((changedDialog) => changedDialog.userId),
    ])
    const changedDialogs = dialogs.filter((candidate) => changedUserIds.has(candidate.userId))

    if (changedDialogs.length > 0) {
      await emitChatListOpenUpdates({
        chat,
        dialogs: changedDialogs,
        skipSessionId: context.currentSessionId,
      })
    }

    const unreadCount = await DialogsModel.getUnreadCount(chat.id, context.currentUserId)
    responseUpdates.push({
      update: {
        oneofKind: "chatOpen",
        chatOpen: {
          chat: await Encoders.chatForUser(chat, { encodingForUserId: context.currentUserId }),
          dialog: Encoders.dialog(dialog, { unreadCount }),
        },
      },
    })
  }

  return {
    updates: responseUpdates,
  }
}
