import { db } from "@in/server/db"
import { and, eq, inArray, not, or } from "drizzle-orm"
import { chats, dialogs, messages, spaces, users, type DbChat } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { Authorize } from "@in/server/utils/authorize"
import {
  encodeChatInfo,
  encodeDialogInfo,
  encodeMessageInfo,
  encodeUserInfo,
  TChatInfo,
  TDialogInfo,
  TMessageInfo,
  TPeerInfo,
  TUserInfo,
} from "../models"
import invariant from "tiny-invariant"

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
  // const result = await db.query.chats.findMany({
  //   where: and(eq(chats.type, "private"), or(eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId))),
  //   with: {
  //     dialogs: { where: eq(dialogs.userId, currentUserId) },
  //     lastMsg: true,
  //   },
  // })

  const result = await db
    .select()
    .from(chats)
    .where(and(eq(chats.type, "private"), or(eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId))))
    .leftJoin(dialogs, and(eq(chats.id, dialogs.chatId), eq(dialogs.userId, currentUserId)))
    .leftJoin(messages, and(eq(chats.lastMsgId, messages.messageId), eq(messages.chatId, chats.id)))

  const peerUsers = await db
    .select()
    .from(users)
    .where(
      inArray(
        users.id,
        [...new Set([...result.map((c) => c.chats.minUserId), ...result.map((c) => c.chats.maxUserId)])].filter(
          (id): id is number => id != null,
        ),
      ),
    )

  const chatsEncoded = result
    .map((c) => c.chats)
    .filter((c): c is DbChat => c != null)
    .map((c) => encodeChatInfo(c, { currentUserId }))

  const dialogsEncoded = result
    .map((c) => c.dialogs)
    .filter((d) => d != null)
    .map((d) => {
      return encodeDialogInfo(d)
    })
  const peerUsersEncoded = peerUsers.map((u) => encodeUserInfo(u))
  const messagesEncoded = result
    .map((c) =>
      c.messages ? encodeMessageInfo(c.messages, { currentUserId, peerId: getPeerId(c.chats, currentUserId) }) : null,
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
