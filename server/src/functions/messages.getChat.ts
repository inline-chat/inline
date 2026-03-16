import type { Chat, Dialog, InputPeer, Message } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { DialogsModel } from "@in/server/db/models/dialogs"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "@in/server/db"
import { and, desc, eq, isNull, not } from "drizzle-orm"
import { chats, dialogs, messages, type DbChat, type DbDialog } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { ensureLinkedSubthreadDialogs, getAnchorMessageForChat, isLinkedSubthread } from "@in/server/modules/subthreads"

type Input = {
  peerId: InputPeer
}

type Output = {
  chat: Chat
  dialog?: Dialog
  pinnedMessageIds: bigint[]
  anchorMessage?: Message
}

const log = new Log("functions.getChat")

async function getChatAndDialogForDM(
  peerUserId: number,
  currentUserId: number,
): Promise<{ chat: DbChat; dialog: DbDialog }> {
  const minUserId = Math.min(currentUserId, peerUserId)
  const maxUserId = Math.max(currentUserId, peerUserId)

  const existingChat = await db.query.chats.findFirst({
    where: {
      type: "private",
      minUserId: minUserId,
      maxUserId: maxUserId,
    },
    with: {
      dialogs: {
        where: {
          userId: currentUserId,
        },
      },
    },
  })

  if (existingChat) {
    const dialog = existingChat.dialogs[0]

    if (dialog) {
      return { chat: existingChat, dialog }
    }

    log.info("Creating dialog for existing DM chat", { chatId: existingChat.id, currentUserId })

    const [newDialog] = await db
      .insert(dialogs)
      .values({
        chatId: existingChat.id,
        userId: currentUserId,
        peerUserId,
      })
      .returning()

    if (!newDialog) {
      throw RealtimeRpcError.InternalError()
    }

    return { chat: existingChat, dialog: newDialog }
  }

  const user = await UsersModel.getUserById(peerUserId)
  if (!user) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  log.info("Auto-creating private chat and dialogs for both users", {
    currentUserId,
    peerUserId,
  })

  const { chat, dialog } = await ChatModel.createUserChatAndDialog({
    peerUserId,
    currentUserId,
  })

  await ChatModel.createUserChatAndDialog({
    peerUserId: currentUserId,
    currentUserId: peerUserId,
  })

  return { chat, dialog }
}

async function getChatAndDialogForThread(
  chatId: number,
  currentUserId: number,
): Promise<{ chat: DbChat; dialog?: DbDialog }> {
  const result = await db.query.chats.findFirst({
    where: {
      id: chatId,
    },
    with: {
      dialogs: {
        where: {
          userId: currentUserId,
        },
      },
    },
  })

  if (!result) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  const chat = result
  const dialog = result.dialogs[0]

  if (chat.type === "private") {
    if (!chat.minUserId || !chat.maxUserId) {
      log.error("Private chat missing user IDs", { chatId, minUserId: chat.minUserId, maxUserId: chat.maxUserId })
      throw RealtimeRpcError.ChatIdInvalid()
    }

    if (chat.minUserId !== currentUserId && chat.maxUserId !== currentUserId) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    if (dialog) {
      return { chat, dialog }
    }

    log.info("Creating dialog for private chat", { chatId, currentUserId })

    const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId

    if (!peerUserId) {
      log.error("Cannot determine peer user ID for private chat", { chatId, currentUserId, minUserId: chat.minUserId, maxUserId: chat.maxUserId })
      throw RealtimeRpcError.InternalError()
    }

    const [newDialog] = await db
      .insert(dialogs)
      .values({
        chatId,
        userId: currentUserId,
        peerUserId,
      })
      .returning()

    if (!newDialog) {
      throw RealtimeRpcError.InternalError()
    }

    return { chat, dialog: newDialog }
  }

  await AccessGuards.ensureChatAccess(chat, currentUserId)

  if (dialog) {
    return { chat, dialog }
  }

  if (isLinkedSubthread(chat)) {
    const { dialogs: ensuredDialogs } = await ensureLinkedSubthreadDialogs({
      chat,
      userIds: [currentUserId],
      sidebarVisible: false,
    })

    return {
      chat,
      dialog: ensuredDialogs.find((existingDialog) => existingDialog.userId === currentUserId),
    }
  }

  log.info("Creating dialog for thread", { chatId, currentUserId, spaceId: chat.spaceId })

  const [newDialog] = await db
    .insert(dialogs)
    .values({
      chatId,
      userId: currentUserId,
      spaceId: chat.spaceId,
    })
    .returning()

  if (!newDialog) {
    throw RealtimeRpcError.InternalError()
  }

  return { chat, dialog: newDialog }
}

export const getChat = async (input: Input, context: FunctionContext): Promise<Output> => {
  const inputPeer = input.peerId
  const currentUserId = context.currentUserId

  let chat: DbChat
  let dialog: DbDialog | undefined

  if (inputPeer.type.oneofKind === "user") {
    const peerUserId = Number(inputPeer.type.user.userId)

    if (!peerUserId || peerUserId <= 0) {
      throw RealtimeRpcError.UserIdInvalid()
    }

    const result = await getChatAndDialogForDM(peerUserId, currentUserId)
    chat = result.chat
    dialog = result.dialog
  } else if (inputPeer.type.oneofKind === "chat") {
    const chatId = Number(inputPeer.type.chat.chatId)

    if (!chatId || chatId <= 0) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    const result = await getChatAndDialogForThread(chatId, currentUserId)
    chat = result.chat
    dialog = result.dialog
  } else if (inputPeer.type.oneofKind === "self") {
    const result = await getChatAndDialogForDM(currentUserId, currentUserId)
    chat = result.chat
    dialog = result.dialog
  } else {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const [unreadData] = await DialogsModel.getBatchUnreadCounts({
    userId: currentUserId,
    chatIds: dialog ? [chat.id] : [],
  })

  const encodedChat = Encoders.chat(chat, { encodingForUserId: currentUserId })
  const encodedDialog = dialog ? Encoders.dialog(dialog, { unreadCount: unreadData?.unreadCount ?? 0 }) : undefined
  const anchorMessage = await getAnchorMessageForChat(chat)
  const encodedAnchorMessage = anchorMessage
    ? Encoders.fullMessage({
        message: anchorMessage,
        encodingForUserId: currentUserId,
        encodingForPeer: {
          peer: {
            type: {
              oneofKind: "chat",
              chat: { chatId: BigInt(chat.parentChatId ?? chat.id) },
            },
          },
        },
      })
    : undefined

  const pinnedRows = await db
    .select({ messageId: messages.messageId })
    .from(messages)
    .where(and(eq(messages.chatId, chat.id), not(isNull(messages.pinnedAt))))
    .orderBy(desc(messages.pinnedAt), desc(messages.messageId))

  const pinnedMessageIds = pinnedRows.map((row) => BigInt(row.messageId))

  return {
    chat: encodedChat,
    dialog: encodedDialog,
    pinnedMessageIds,
    anchorMessage: encodedAnchorMessage,
  }
}
