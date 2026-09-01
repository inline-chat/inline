import type { Chat, Dialog, InputPeer, Message, User } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import { DialogsModel } from "@in/server/db/models/dialogs"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { db } from "@in/server/db"
import { and, desc, eq, isNull, not } from "drizzle-orm"
import { chats, dialogs, messages, users, type DbChat, type DbDialog, type DbNewDialog } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { ensureLinkedSubthreadDialogs, isLinkedSubthread } from "@in/server/modules/subthreads"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"

type Input = {
  peerId: InputPeer
  includeRecentMessages?: boolean
}

type Output = {
  chat: Chat
  dialog?: Dialog
  pinnedMessageIds: bigint[]
  anchorMessage?: Message
  user?: User
  messages: Message[]
}

const log = new Log("functions.getChat")
const CHAT_REPAIR_MESSAGE_LIMIT = 100

const createDialogOrLoadConcurrentWinner = async (
  values: DbNewDialog,
): Promise<DbDialog> => {
  const [created] = await db
    .insert(dialogs)
    .values(values)
    .onConflictDoNothing({
      target: [dialogs.chatId, dialogs.userId],
    })
    .returning()

  if (created) return created

  const concurrentWinner = await db.query.dialogs.findFirst({
    where: {
      chatId: values.chatId,
      userId: values.userId,
    },
  })
  if (!concurrentWinner) {
    throw RealtimeRpcError.InternalError()
  }
  return concurrentWinner
}

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

    const newDialog = await createDialogOrLoadConcurrentWinner({
      chatId: existingChat.id,
      userId: currentUserId,
      peerUserId,
      ...dialogOpenDefaultsForChat(existingChat),
    })

    return { chat: existingChat, dialog: newDialog }
  }

  const user = await UsersModel.getUserById(peerUserId)
  if (!user || UsersModel.isDeleted(user)) {
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

    const newDialog = await createDialogOrLoadConcurrentWinner({
      chatId,
      userId: currentUserId,
      peerUserId,
      ...dialogOpenDefaultsForChat(chat),
    })

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
      chatListHidden: true,
    })

    return {
      chat,
      dialog: ensuredDialogs.find((existingDialog) => existingDialog.userId === currentUserId),
    }
  }

  log.info("Creating dialog for thread", { chatId, currentUserId, spaceId: chat.spaceId })

  const newDialog = await createDialogOrLoadConcurrentWinner({
    chatId,
    userId: currentUserId,
    spaceId: chat.spaceId,
  })

  return { chat, dialog: newDialog }
}

export const getChat = async (input: Input, context: FunctionContext): Promise<Output> => {
  const inputPeer = input.peerId
  const currentUserId = context.currentUserId

  let chat: DbChat
  let peerUserId: number | undefined

  if (inputPeer.type.oneofKind === "user") {
    peerUserId = Number(inputPeer.type.user.userId)

    if (!peerUserId || peerUserId <= 0) {
      throw RealtimeRpcError.UserIdInvalid()
    }

    const result = await getChatAndDialogForDM(peerUserId, currentUserId)
    chat = result.chat
  } else if (inputPeer.type.oneofKind === "chat") {
    const chatId = Number(inputPeer.type.chat.chatId)

    if (!chatId || chatId <= 0) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    const result = await getChatAndDialogForThread(chatId, currentUserId)
    chat = result.chat
  } else if (inputPeer.type.oneofKind === "self") {
    peerUserId = currentUserId
    const result = await getChatAndDialogForDM(currentUserId, currentUserId)
    chat = result.chat
  } else {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  return db.transaction(
    async (tx): Promise<Output> => {
      const [snapshotChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).limit(1)
      if (!snapshotChat) throw RealtimeRpcError.ChatIdInvalid()
      await AccessGuards.ensureChatAccess(snapshotChat, currentUserId, tx)

      const [snapshotDialog] = await tx
        .select()
        .from(dialogs)
        .where(and(eq(dialogs.chatId, snapshotChat.id), eq(dialogs.userId, currentUserId)))
        .limit(1)
      const unreadCount = snapshotDialog
        ? await DialogsModel.getUnreadCount(snapshotChat.id, currentUserId, tx)
        : 0
      const encodedChat = await Encoders.chatForUser(snapshotChat, {
        encodingForUserId: currentUserId,
        tx,
      })

      const anchorRows = snapshotChat.parentChatId != null && snapshotChat.parentMessageId != null
        ? await MessageModel.getMessagesByIds(
            snapshotChat.parentChatId,
            [BigInt(snapshotChat.parentMessageId)],
            { tx },
          )
        : []
      const anchorMessage = anchorRows[0]
      const encodedAnchorMessage = anchorMessage
        ? Encoders.fullMessage({
            message: anchorMessage,
            encodingForUserId: currentUserId,
            encodingForPeer: {
              peer: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(snapshotChat.parentChatId ?? snapshotChat.id) },
                },
              },
            },
          })
        : undefined

      const pinnedRows = await tx
        .select({ messageId: messages.messageId })
        .from(messages)
        .where(and(eq(messages.chatId, snapshotChat.id), not(isNull(messages.pinnedAt))))
        .orderBy(desc(messages.pinnedAt), desc(messages.messageId))

      const recentMessages = input.includeRecentMessages
        ? await MessageModel.getLatestMessagesForChat(snapshotChat.id, CHAT_REPAIR_MESSAGE_LIMIT, tx)
        : []
      const encodedMessages = recentMessages.map((message) =>
        Encoders.fullMessage({
          message,
          encodingForUserId: currentUserId,
          encodingForPeer: { inputPeer },
        }),
      )

      const [peerUser] = peerUserId
        ? await tx.select().from(users).where(eq(users.id, peerUserId)).limit(1)
        : []

      return {
        chat: encodedChat,
        dialog: snapshotDialog ? Encoders.dialog(snapshotDialog, { unreadCount }) : undefined,
        pinnedMessageIds: pinnedRows.map((row) => BigInt(row.messageId)),
        anchorMessage: encodedAnchorMessage,
        user: peerUser ? Encoders.user({ user: peerUser, viewerUserId: currentUserId }) : undefined,
        messages: encodedMessages,
      }
    },
    { isolationLevel: "repeatable read", accessMode: "read only" },
  )
}
