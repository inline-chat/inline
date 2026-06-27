import type { Chat, Dialog, InputPeer, Peer, Update, User } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { UsersModel } from "@in/server/db/models/users"
import { chats, chatParticipants, dialogs, members, messages, UpdateBucket, type DbChat, type DbDialog } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"
import { emitChatListOpenUpdates } from "@in/server/modules/subthreads"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"

const log = new Log("functions.updateDialogOpen")

type Input = {
  peerId: InputPeer
  open: boolean
  order?: string
}

type Output = {
  chat?: Chat
  dialog?: Dialog
  user?: User
  deletedChat?: boolean
}

export async function updateDialogOpen(input: Input, context: FunctionContext): Promise<Output> {
  if (input.order != null && !FractionalIndex.isValid(input.order)) {
    throw RealtimeRpcError.BadRequest()
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  if (!input.open) {
    const deleteResult = await deleteEmptyUntitledThreadOnClose(chat, context)
    if (deleteResult) {
      return deleteResult
    }
  }

  const { dialogs, changedDialogs } = await setDialogOpenForUsers({
    chat,
    userIds: [context.currentUserId],
    open: input.open,
    order: input.order,
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
    chat: Encoders.chat(chat, { encodingForUserId: context.currentUserId }),
    dialog: Encoders.dialog(dialog, { unreadCount }),
  }

  if (peerUser) {
    output.user = Encoders.user({ user: peerUser, min: true })
  }

  return output
}

async function deleteEmptyUntitledThreadOnClose(chat: DbChat, context: FunctionContext): Promise<Output | undefined> {
  if (chat.type !== "thread") {
    return undefined
  }
  if (chat.createdBy !== context.currentUserId) {
    return undefined
  }
  if (isUntitled(chat) == false) {
    return undefined
  }

  let persistedUpdate: UpdateSeqAndDate | undefined
  let recipientIds: number[] = []
  let peerId: Peer | undefined
  let result: Output | undefined

  const didDelete = await db.transaction(async (tx) => {
    const [lockedChat] = await tx
      .select()
      .from(chats)
      .where(eq(chats.id, chat.id))
      .for("update")
      .limit(1)

    if (!lockedChat) {
      return false
    }
    if (lockedChat.type !== "thread" || lockedChat.createdBy !== context.currentUserId || isUntitled(lockedChat) == false) {
      return false
    }
    if (lockedChat.lastMsgId != null && lockedChat.lastMsgId !== 0) {
      return false
    }

    const [message] = await tx
      .select({ messageId: messages.messageId })
      .from(messages)
      .where(eq(messages.chatId, lockedChat.id))
      .limit(1)

    if (message) {
      return false
    }

    const [currentDialog] = await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, lockedChat.id), eq(dialogs.userId, context.currentUserId)))
      .limit(1)

    if (!currentDialog || currentDialog.open !== true || currentDialog.pinned === true) {
      return false
    }

    peerId = Encoders.peerFromChat(lockedChat, { currentUserId: context.currentUserId })
    recipientIds = await deleteRecipients(tx, lockedChat)
    result = {
      deletedChat: true,
      chat: Encoders.chat(lockedChat, { encodingForUserId: context.currentUserId }),
      dialog: Encoders.dialog(closedDialog(currentDialog), { unreadCount: 0 }),
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: deleteChatServerUpdate(lockedChat.id),
      bucket: UpdateBucket.Chat,
      entity: lockedChat,
    })
    persistedUpdate = update

    await UserBucketUpdates.enqueueMany(
      recipientIds.map((userId) => ({
        userId,
        update: {
          oneofKind: "userChatParticipantDelete",
          userChatParticipantDelete: {
            chatId: BigInt(lockedChat.id),
          },
        },
      })),
      { tx },
    )

    await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, lockedChat.id))
    await tx.delete(dialogs).where(eq(dialogs.chatId, lockedChat.id))
    await tx.delete(chats).where(eq(chats.id, lockedChat.id))

    return true
  })

  if (didDelete && persistedUpdate && peerId) {
    const update: Update = {
      seq: persistedUpdate.seq,
      date: encodeDateStrict(persistedUpdate.date),
      update: {
        oneofKind: "deleteChat",
        deleteChat: { peerId },
      },
    }

    recipientIds.forEach((userId) => {
      RealtimeUpdates.pushToUser(userId, [update])
    })

    log.info("Deleted empty untitled thread on sidebar close", { chatId: chat.id })
  }

  return didDelete ? result : undefined
}

function isUntitled(chat: Pick<DbChat, "title" | "isUntitled">): boolean {
  return chat.isUntitled === true
}

async function deleteRecipients(tx: Transaction, chat: DbChat): Promise<number[]> {
  if (chat.publicThread) {
    if (chat.spaceId == null) {
      return []
    }

    const rows = await tx
      .select({ userId: members.userId })
      .from(members)
      .where(and(eq(members.spaceId, chat.spaceId), eq(members.canAccessPublicChats, true)))

    return rows.map((row) => row.userId)
  }

  const rows = await tx
    .select({ userId: chatParticipants.userId })
    .from(chatParticipants)
    .where(eq(chatParticipants.chatId, chat.id))

  return rows.map((row) => row.userId)
}

function closedDialog(dialog: DbDialog): DbDialog {
  return {
    ...dialog,
    open: false,
    openedDate: null,
    order: null,
  }
}

function deleteChatServerUpdate(chatId: number): ServerUpdate["update"] {
  return {
    oneofKind: "deleteChat",
    deleteChat: {
      chatId: BigInt(chatId),
    },
  }
}
