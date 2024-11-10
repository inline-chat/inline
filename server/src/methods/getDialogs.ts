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

const MAX_LIMIT = 100

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = validateSpaceId(input?.spaceId)
  const currentUserId = context.currentUserId

  let { dialogs, users, chats, messages } = await fetchExistingDialogs(currentUserId, spaceId)

  if (spaceId) {
    const publicChats = await fetchPublicChats(spaceId, currentUserId)
    const newDialogs = await createDialogsForPublicChats(publicChats, currentUserId, spaceId)
    dialogs.push(...newDialogs)
    const { messages: newMessages, chats: newChats } = extractMessagesAndChats(publicChats)
    messages.push(...newMessages)
    chats.push(...newChats)

    const spaceMembers = await fetchSpaceMembers(spaceId)
    const privateDialogs = await fetchPrivateDialogs(currentUserId, spaceMembers)
    dialogs.push(...privateDialogs)
    const { messages: privateMessages, chats: privateChats } = extractMessagesAndChats(privateDialogs)
    messages.push(...privateMessages)
    chats.push(...privateChats)
    users.push(...spaceMembers.map((m) => m.user))
  }

  const deduplicatedResults = deduplicateResults(dialogs, chats, messages, users)

  console.log("pre encode", deduplicatedResults)

  let result = {
    dialogs: deduplicatedResults.dialogs.map(encodeDialogInfo),
    chats: deduplicatedResults.chats.map((d) => encodeChatInfo(d, { currentUserId })),
    messages: deduplicatedResults.messages.map((m) => encodeMessageInfo(m, { currentUserId })),
    users: deduplicatedResults.users.map(encodeUserInfo),
  }

  console.log("result", result)

  return result
}

const validateSpaceId = (spaceIdInput: any): number | null => {
  const spaceId = spaceIdInput ? Number(spaceIdInput) : null
  if (spaceId && isNaN(spaceId)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  console.log("spaceId", spaceId)
  return spaceId
}

const fetchExistingDialogs = async (
  currentUserId: number,
  spaceId: number | null,
): Promise<{
  dialogs: schema.DbDialog[]
  users: schema.DbUser[]
  chats: schema.DbChat[]
  messages: schema.DbMessage[]
}> => {
  const existingThreadDialogs = await db.query.dialogs.findMany({
    where: and(eq(schema.dialogs.userId, currentUserId), eq(schema.dialogs.spaceId, spaceId ?? sql`null`)),
    with: { chat: { with: { lastMsg: { with: { from: true } } } } },
    limit: MAX_LIMIT,
  })

  const dialogs: schema.DbDialog[] = []
  const users: schema.DbUser[] = []
  const chats: schema.DbChat[] = []
  const messages: schema.DbMessage[] = []

  existingThreadDialogs.forEach((d) => {
    dialogs.push(d)
    if (d.chat?.lastMsg) {
      messages.push(d.chat?.lastMsg)
    }
    if (d.chat) {
      chats.push(d.chat)
    }
  })

  return { dialogs, users, chats, messages }
}

const fetchPublicChats = async (spaceId: number, currentUserId: number): Promise<schema.DbChat[]> => {
  return await db.query.chats.findMany({
    where: and(eq(schema.chats.spaceId, spaceId), eq(schema.chats.type, "thread"), eq(schema.chats.publicThread, true)),
    with: {
      dialogs: {
        where: eq(schema.dialogs.userId, currentUserId),
      },
      lastMsg: { with: { from: true } },
    },
  })
}

const createDialogsForPublicChats = async (
  publicChats: schema.DbChat[],
  currentUserId: number,
  spaceId: number,
): Promise<schema.DbDialog[]> => {
  return await db.transaction(async (tx) => {
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
}

const extractMessagesAndChats = (
  items: (schema.DbChat | schema.DbDialog)[],
): { messages: schema.DbMessage[]; chats: schema.DbChat[] } => {
  const messages: schema.DbMessage[] = []
  const chats: schema.DbChat[] = []
  items.forEach((item) => {
    if ("lastMsg" in item && item.lastMsg) {
      messages.push(item.lastMsg)
    }
    if ("chat" in item && item.chat) {
      chats.push(item.chat)
    }
  })
  return { messages, chats }
}

const fetchSpaceMembers = async (spaceId: number): Promise<schema.DbUser[]> => {
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
  return space?.members || []
}

const fetchPrivateDialogs = async (
  currentUserId: number,
  spaceMembers: schema.DbMember[],
): Promise<schema.DbDialog[]> => {
  return await db.query.dialogs.findMany({
    where: and(
      eq(schema.dialogs.userId, currentUserId),
      inArray(
        schema.dialogs.peerUserId,
        spaceMembers.map((m) => m.user.id),
      ),
    ),
    with: { chat: { with: { lastMsg: { with: { from: true } } } } },
    limit: MAX_LIMIT,
  })
}

const deduplicateResults = (
  dialogs: schema.DbDialog[],
  chats: schema.DbChat[],
  messages: schema.DbMessage[],
  users: schema.DbUser[],
): { dialogs: schema.DbDialog[]; chats: schema.DbChat[]; messages: schema.DbMessage[]; users: schema.DbUser[] } => {
  return {
    dialogs: dialogs.filter((d, index, self) => index === self.findIndex((t) => t.id === d.id)),
    chats: chats.filter((c, index, self) => index === self.findIndex((t) => t.id === c.id)),
    messages: messages.filter((m, index, self) => index === self.findIndex((t) => t.messageId === m.messageId)),
    users: users.filter((u, index, self) => index === self.findIndex((t) => t.id === u.id)),
  }
}
