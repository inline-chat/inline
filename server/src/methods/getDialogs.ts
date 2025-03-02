import { db } from "@in/server/db"
import { and, eq, inArray, sql } from "drizzle-orm"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
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
} from "@in/server/api-types"
import type { HandlerContext } from "@in/server/controllers/helpers"
import * as schema from "@in/server/db/schema"
import { normalizeId, TInputId } from "@in/server/types/methods"

export const Input = Type.Object({
  spaceId: TInputId,
})

export const Response = Type.Object({
  dialogs: Type.Array(TDialogInfo),
  chats: Type.Array(TChatInfo),

  /** Last messages for each dialog */
  messages: Type.Array(TMessageInfo),

  /** Users that are senders of last messages */
  users: Type.Array(TUserInfo),

  // TODO: Pagination
})

// This API is not paginated and mostly as a placeholder for future specialized methods
// but until then we don't want to fuck our server with heavy queries
const MAX_LIMIT = 100

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = normalizeId(input.spaceId)
  if (spaceId && isNaN(spaceId)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const currentUserId = context.currentUserId

  // Buckets for results
  let dialogs: schema.DbDialog[] = []
  let users: schema.DbUserWithPhoto[] = []
  let chats: schema.DbChat[] = []
  let messages: TMessageInfo[] = []

  const existingThreadDialogs = await db.query.dialogs.findMany({
    where: and(eq(schema.dialogs.userId, currentUserId), eq(schema.dialogs.spaceId, spaceId)),
    with: { chat: { with: { lastMsg: { with: { from: true, file: true } } } } },
    limit: MAX_LIMIT,
  })

  // Push all dialogs to the arrays
  existingThreadDialogs.forEach((d) => {
    dialogs.push(d)

    if (d.chat?.lastMsg) {
      messages.push(
        encodeMessageInfo(d.chat?.lastMsg, {
          currentUserId,
          peerId: peerIdFromChat(d.chat, { currentUserId }),
          files: d.chat?.lastMsg?.file ? [d.chat?.lastMsg?.file] : null,
        }),
      )
    }

    if (d.chat) {
      chats.push(d.chat)
    }

    // TODO: Deduplicate users
    if (d.chat?.lastMsg?.from) {
      users.push(d.chat?.lastMsg?.from)
    }
  })

  // Find private dialogs for members of this space
  if (spaceId) {
    // Check for thread public chats that are not in dialogs
    const publicChats = await db.query.chats.findMany({
      where: and(
        eq(schema.chats.spaceId, spaceId),
        eq(schema.chats.type, "thread"),
        eq(schema.chats.publicThread, true),
      ),
      with: {
        dialogs: {
          where: eq(schema.dialogs.userId, currentUserId),
        },
        lastMsg: { with: { from: true, file: true } },
      },
    })

    // Make dialogs for each public chat that doesn't have one yet
    let result = await db.transaction(async (tx) => {
      const newDialogs: schema.DbDialog[] = []
      for (const c of publicChats) {
        if (c.dialogs.length === 0) {
          const newDialog = await tx
            .insert(schema.dialogs)
            .values({
              chatId: c.id,
              userId: currentUserId,
              spaceId: spaceId,
            })
            .returning()
          if (newDialog[0]) {
            newDialogs.push(newDialog[0])
          }
        }
      }
      return newDialogs
    })

    // Push newly created dialogs to the arrays
    result.forEach((d) => {
      dialogs.push(d)
    })

    // Push last messages and chats of public chats
    publicChats.forEach((c) => {
      if (c.dialogs[0]) {
        dialogs.push(c.dialogs[0])
      }
      if (c.lastMsg) {
        messages.push(
          encodeMessageInfo(c.lastMsg, {
            currentUserId,
            peerId: peerIdFromChat(c, { currentUserId }),
            files: c.lastMsg?.file ? [c.lastMsg?.file] : null,
          }),
        )
        if (c.lastMsg.from) {
          users.push(c.lastMsg.from)
        }
      }

      if (c) {
        chats.push(c)
      }
    })

    // Find members of this space
    const space = await db.query.spaces.findFirst({
      where: eq(schema.spaces.id, spaceId),
      with: {
        members: {
          with: {
            user: {
              with: {
                photo: true,
              },
            },
          },
          limit: MAX_LIMIT,
        },
      },
    })

    const privateDialogs = await db.query.dialogs.findMany({
      where: and(
        eq(schema.dialogs.userId, currentUserId),
        inArray(schema.dialogs.peerUserId, space?.members.map((m) => m.user.id) ?? []),
      ),
      with: { chat: { with: { lastMsg: { with: { from: true, file: true } } } } },
      limit: MAX_LIMIT,
    })

    // Push all private dialogs to the arrays
    privateDialogs.forEach((d) => {
      dialogs.push(d)

      // TODO: Deduplicate users
      // if (d.chat?.lastMsg?.from) {
      //   users.push(d.chat?.lastMsg?.from)
      // }

      if (d.chat?.lastMsg) {
        messages.push(
          encodeMessageInfo(d.chat?.lastMsg, {
            currentUserId,
            peerId: peerIdFromChat(d.chat, { currentUserId }),
            files: d.chat?.lastMsg?.file ? [d.chat?.lastMsg?.file] : null,
          }),
        )
        if (d.chat?.lastMsg.from) {
          users.push(d.chat?.lastMsg.from)
        }
      }
      if (d.chat) {
        chats.push(d.chat)
      }
    })

    // Push users
    space?.members.forEach((m) => {
      users.push(m.user)
    })
  }

  // Deduplicate result arrays by id
  dialogs = dialogs.filter((d, index, self) => index === self.findIndex((t) => t.id === d.id))
  chats = chats.filter((c, index, self) => index === self.findIndex((t) => t.id === c.id))
  messages = messages.filter((m, index, self) => index === self.findIndex((t) => t.id === m.id))
  users = users.filter((u, index, self) => index === self.findIndex((t) => t.id === u.id))

  // Get unread counts for all dialogs
  const dialogsUnreads = await DialogsModel.getBatchUnreadCounts({
    userId: context.currentUserId,
    chatIds: dialogs.map((d) => d.chatId),
  })

  // Merge unread counts with dialog info
  const dialogsEncoded = dialogs.map((dialog) => {
    const unreadCount = dialogsUnreads.find((uc) => uc.chatId === dialog.chatId)?.unreadCount ?? 0
    return encodeDialogInfo({ ...dialog, unreadCount })
  })

  let result = {
    dialogs: dialogsEncoded,
    chats: chats.map((d) => encodeChatInfo(d, { currentUserId })),
    messages: messages,
    users: users.map(encodeFullUserInfo),
  }

  return result
}

import type { StaticEncode } from "@sinclair/typebox/type"
import { DialogsModel } from "@in/server/db/models/dialogs"

function peerIdFromChat(chat: schema.DbChat, context: { currentUserId: number }): StaticEncode<typeof TPeerInfo> {
  if (chat.type === "private") {
    if (chat.minUserId === context.currentUserId) {
      return { userId: chat.minUserId }
    } else if (chat.maxUserId === context.currentUserId) {
      return { userId: chat.maxUserId }
    } else {
      Log.shared.error("Unknown peerId", { chatId: chat.id, currentUserId: context.currentUserId })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
  }
  return { threadId: chat.id }
}
