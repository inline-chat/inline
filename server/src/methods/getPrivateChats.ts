import { db } from "@in/server/db"
import { and, eq, inArray, not, or } from "drizzle-orm"
import { chats, dialogs, files, messages, spaces, users, type DbChat } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { Authorize } from "@in/server/utils/authorize"
import {
  encodeChatInfo,
  encodeDialogInfo,
  encodeFullUserInfo,
  encodeMessageInfo,
  encodeUserInfo,
  TChatInfo,
  TDialogInfo,
  TMessageInfo,
  TPeerInfo,
  TUserInfo,
} from "../api-types"
import invariant from "tiny-invariant"
import { DialogsModel } from "@in/server/db/models/dialogs"

export const Input = Type.Object({})

export const Response = Type.Object({
  messages: Type.Array(TMessageInfo),
  chats: Type.Array(TChatInfo),
  dialogs: Type.Array(TDialogInfo),
  peerUsers: Type.Array(TUserInfo),
})

export const handler = async (_: Static<typeof Input>, context: HandlerContext): Promise<Static<typeof Response>> => {
  const currentUserId = context.currentUserId

  const selfChatInfo = await db
    .select()
    .from(chats)
    .where(and(eq(chats.type, "private"), eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId)))
    .leftJoin(dialogs, eq(chats.id, dialogs.chatId))
  let selfChat = selfChatInfo[0]?.chats
  let selfChatDialog = selfChatInfo[0]?.dialogs

  // -------------------------------------------------------------------------------------------------------------------
  // Recover from issues with self chat

  // NOTE(@mo): have to re-enable this so members don't error on missing chat or dialog client side
  if (!selfChat) {
    const [newSelfChat] = await db
      .insert(chats)
      .values({
        type: "private",
        date: new Date(),
        minUserId: currentUserId,
        maxUserId: currentUserId,
        title: "Saved Messages",
      })
      .returning()
    selfChat = newSelfChat
  }
  if (!selfChatDialog && selfChat) {
    const [newSelfChatDialog] = await db
      .insert(dialogs)
      .values({
        chatId: selfChat.id,
        peerUserId: currentUserId,
        userId: currentUserId,
      })
      .returning()
    selfChatDialog = newSelfChatDialog
  }

  // -------------------------------------------------------------------------------------------------------------------
  // Get all private chats
  // const result = await db._query.chats.findMany({
  //   where: and(eq(chats.type, "private"), or(eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId))),
  //   with: {
  //     dialogs: { where: eq(dialogs.userId, currentUserId) },
  //     lastMsg: true,
  //   },
  // })

  const result = await db
    .select({
      chat: chats,
      dialog: dialogs,
      message: messages,
      file: files,
    })
    .from(chats)
    .where(and(eq(chats.type, "private"), or(eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId))))
    .leftJoin(dialogs, and(eq(chats.id, dialogs.chatId), eq(dialogs.userId, currentUserId)))
    .leftJoin(messages, and(eq(chats.lastMsgId, messages.messageId), eq(messages.chatId, chats.id)))
    .leftJoin(files, eq(files.id, messages.fileId))

  // Create missing dialogs for chats that don't have them
  const chatsWithoutDialogs = result.filter((r) => !r.dialog).map((r) => r.chat)
  if (chatsWithoutDialogs.length > 0) {
    const newDialogs = await db.transaction(async (tx) => {
      const created: (typeof dialogs.$inferSelect)[] = []
      for (const chat of chatsWithoutDialogs) {
        const [dialog] = await tx
          .insert(dialogs)
          .values({
            chatId: chat.id,
            userId: currentUserId,
            peerUserId: chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId,
            date: new Date(),
          })
          .returning()
        if (dialog) created.push(dialog)
      }
      return created
    })

    // Add new dialogs to the result
    newDialogs.forEach((dialog) => {
      const chat = result.find((r) => r.chat.id === dialog.chatId)
      if (chat) {
        chat.dialog = dialog
      }
    })
  }

  const peerUsers = await db._query.users.findMany({
    where: inArray(
      users.id,
      [...new Set([...result.map((c) => c.chat.minUserId), ...result.map((c) => c.chat.maxUserId)])].filter(
        (id): id is number => id != null,
      ),
    ),
    with: {
      photo: true,
    },
  })
  // const peerUsers = await db
  //   .select()
  //   .from(users)
  //   .where(
  //     inArray(
  //       users.id,
  //       [...new Set([...result.map((c) => c.chat.minUserId), ...result.map((c) => c.chat.maxUserId)])].filter(
  //         (id): id is number => id != null,
  //       ),
  //     ),
  //   )

  const chatsEncoded = result
    .map((c) => c.chat)
    .filter((c): c is DbChat => c != null)
    .map((c) => encodeChatInfo(c, { currentUserId }))

  // Get unread counts for all chats
  const unreadCounts = await DialogsModel.getBatchUnreadCounts({
    userId: currentUserId,
    chatIds: result.map((c) => c.chat.id),
  })

  const dialogsEncoded = result
    .map((c) => c.dialog)
    .filter((d) => d != null)
    .map((d) => {
      let unreadCount = unreadCounts.find((uc) => uc.chatId === d.chatId)?.unreadCount ?? 0
      return encodeDialogInfo({
        ...d,
        unreadCount,
      })
    })

  const peerUsersEncoded = peerUsers.map((u) => encodeFullUserInfo(u))
  const messagesEncoded = result
    .map((c) =>
      c.message
        ? encodeMessageInfo(c.message, {
            currentUserId,
            peerId: getPeerId(c.chat, currentUserId),
            files: c.file ? [c.file] : null,
          })
        : null,
    )
    .filter((m): m is TMessageInfo => m != null)

  return {
    chats: chatsEncoded,
    dialogs: dialogsEncoded,
    peerUsers: peerUsersEncoded,
    messages: messagesEncoded,
  }
}

/** Only handles private chats */
const getPeerId = (chat: DbChat, currentUserId: number): TPeerInfo => {
  invariant(chat.minUserId != null && chat.maxUserId != null, "Private chat must have minUserId and maxUserId")
  return chat.minUserId === currentUserId ? { userId: chat.maxUserId } : { userId: chat.minUserId }
}
