import { db } from "@in/server/db"
import { and, eq, inArray, sql } from "drizzle-orm"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
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
} from "@in/server/models"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import * as schema from "@in/server/db/schema"
import { TInputId } from "@in/server/types/methods"

export const Input = Type.Object({
  spaceId: Type.Optional(TInputId),
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
  const spaceId = input?.spaceId ? Number(input.spaceId) : null
  if (spaceId && isNaN(spaceId)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  console.log("spaceId", spaceId)
  const currentUserId = context.currentUserId

  // Buckets for results
  let dialogs: schema.DbDialog[] = []
  let users: schema.DbUser[] = []
  let chats: schema.DbChat[] = []
  let messages: TMessageInfo[] = []

  const existingThreadDialogs = await db.query.dialogs.findMany({
    where: and(eq(schema.dialogs.userId, currentUserId), eq(schema.dialogs.spaceId, spaceId ?? sql`null`)),
    with: { chat: { with: { lastMsg: { with: { from: true } } } } },
    limit: MAX_LIMIT,
  })

  // Push all dialogs to the arrays
  existingThreadDialogs.forEach((d) => {
    dialogs.push(d)

    if (d.chat?.lastMsg) {
      messages.push(
        encodeMessageInfo(d.chat?.lastMsg, { currentUserId, peerId: peerIdFromChat(d.chat, { currentUserId }) }),
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
        lastMsg: { with: { from: true } },
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
      if (c.lastMsg) {
        messages.push(encodeMessageInfo(c.lastMsg, { currentUserId, peerId: peerIdFromChat(c, { currentUserId }) }))
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
            user: true,
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
      with: { chat: { with: { lastMsg: { with: { from: true } } } } },
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
          encodeMessageInfo(d.chat?.lastMsg, { currentUserId, peerId: peerIdFromChat(d.chat, { currentUserId }) }),
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

  let result = {
    dialogs: dialogs.map(encodeDialogInfo),
    chats: chats.map((d) => encodeChatInfo(d, { currentUserId })),
    messages: messages,
    users: users.map(encodeUserInfo),
  }

  console.log("get dialogs result", result)

  return result
}

import type { StaticEncode } from "@sinclair/typebox/type"

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
