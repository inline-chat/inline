import { db } from "@in/server/db"
import { and, eq, inArray, isNull, or, sql } from "drizzle-orm"
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
const MAX_LIMIT = 200

// --- Helper Functions ---
function dedupeById<T extends { id: number }>(arr: T[]): T[] {
  return arr.filter((item, index, self) => index === self.findIndex((t) => t.id === item.id))
}

function pushIfExists<T>(arr: T[], item: T | undefined | null) {
  if (item) arr.push(item)
}

function pushMessageAndUser(
  messages: TMessageInfo[],
  users: schema.DbUserWithPhoto[],
  msg: any,
  currentUserId: number,
  peerId: any,
) {
  if (msg) {
    messages.push(
      encodeMessageInfo(msg, {
        currentUserId,
        peerId,
        files: msg.file ? [msg.file] : null,
      }),
    )
    if (msg.from) users.push(msg.from)
  }
}

async function createMissingDialogsForPublicChats(publicChats: any[], currentUserId: number, spaceId: number) {
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
        if (newDialog[0]) newDialogs.push(newDialog[0])
      }
    }
    return newDialogs
  })
}
// --- End Helper Functions ---

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

  // --- 1. Existing Thread Dialogs ---
  const existingThreadDialogs = await db._query.dialogs.findMany({
    where: and(eq(schema.dialogs.userId, currentUserId), eq(schema.dialogs.spaceId, spaceId)),
    with: { chat: { with: { lastMsg: { with: { from: true, file: true } } } } },
    limit: MAX_LIMIT,
  })
  existingThreadDialogs.forEach((d) => {
    // 🎯 IMPORTANT IMPORTANT IMPORTANT
    // We need to check if the chat is a private thread and if the user is a participant
    // If so, we need to add the chat to the results
    // Otherwise, we need to skip it
    // 🎯 IMPORTANT IMPORTANT IMPORTANT
    // TODO: This is a hack to filter out private threads that the user is not a participant of
    // We need to find a better way to do this
    if (d.chat?.type === "thread" && d.chat?.publicThread === false) {
      return
    }

    dialogs.push(d)
    if (d.chat) chats.push(d.chat)
    pushMessageAndUser(messages, users, d.chat?.lastMsg, currentUserId, peerIdFromChat(d.chat, { currentUserId }))
  })

  // --- 2. Public Chats and Private Dialogs in Space ---
  if (spaceId) {
    // 2a. Public Chats
    const publicChats = await db._query.chats.findMany({
      where: and(
        eq(schema.chats.spaceId, spaceId),
        eq(schema.chats.type, "thread"),
        eq(schema.chats.publicThread, true),
      ),
      with: {
        dialogs: { where: eq(schema.dialogs.userId, currentUserId) },
        lastMsg: { with: { from: true, file: true } },
      },
    })

    // 2a. Private Threads (where user is a participant) - single SQL call
    const privateThreadChats = await db
      .select({
        chat: schema.chats,
        dialog: schema.dialogs,
        lastMsg: schema.messages,
        lastMsgFrom: schema.users,
        lastMsgFile: schema.files,
      })
      .from(schema.chats)
      .innerJoin(
        schema.chatParticipants,
        and(eq(schema.chatParticipants.chatId, schema.chats.id), eq(schema.chatParticipants.userId, currentUserId)),
      )
      .leftJoin(
        schema.dialogs,
        and(eq(schema.dialogs.chatId, schema.chats.id), eq(schema.dialogs.userId, currentUserId)),
      )
      .leftJoin(
        schema.messages,
        and(eq(schema.messages.messageId, schema.chats.lastMsgId), eq(schema.messages.chatId, schema.chats.id)),
      )
      .leftJoin(schema.users, eq(schema.users.id, schema.messages.fromId))
      .leftJoin(schema.files, eq(schema.files.id, schema.messages.fileId))
      .where(
        and(
          eq(schema.chats.spaceId, spaceId),
          eq(schema.chats.type, "thread"),
          eq(schema.chats.publicThread, false),
          eq(schema.chatParticipants.userId, currentUserId),
        ),
      )

    // Transform the result to match the previous structure
    const privateThreadChatsTransformed = privateThreadChats.map((row) => ({
      ...row.chat,
      dialogs: row.dialog ? [row.dialog] : [],
      lastMsg: row.lastMsg
        ? {
            ...row.lastMsg,
            from: row.lastMsgFrom || undefined,
            file: row.lastMsgFile ? row.lastMsgFile : undefined,
          }
        : undefined,
    }))

    // Create missing dialogs for public chats
    const newDialogs = await createMissingDialogsForPublicChats(publicChats, currentUserId, spaceId)
    newDialogs.forEach((d) => dialogs.push(d))
    publicChats.forEach((c) => {
      if (c.dialogs[0]) dialogs.push(c.dialogs[0])
      pushMessageAndUser(messages, users, c.lastMsg, currentUserId, peerIdFromChat(c, { currentUserId }))
      chats.push(c)
    })

    // Add privateThreadChatsTransformed to results
    privateThreadChatsTransformed.forEach((c) => {
      // Add chat
      chats.push(c)
      // Add dialog(s)
      c.dialogs.forEach((d) => dialogs.push(d))
      // Add last message and user if present
      if (c.lastMsg) {
        pushMessageAndUser(messages, users, c.lastMsg, currentUserId, peerIdFromChat(c, { currentUserId }))
      }
    })

    // 2b. Space Members
    const space = await db._query.spaces.findFirst({
      where: eq(schema.spaces.id, spaceId),
      with: {
        members: {
          with: { user: { with: { photo: true } } },
          limit: MAX_LIMIT,
        },
      },
    })
    // 2c. Private Dialogs with Space Members
    const privateDialogs = await db._query.dialogs.findMany({
      where: and(
        eq(schema.dialogs.userId, currentUserId),
        // spaceid = nil
        isNull(schema.dialogs.spaceId),
        inArray(
          schema.dialogs.peerUserId,
          space?.members.map((m: schema.DbMember & { user: schema.DbUserWithPhoto }) => m.user.id) ?? [],
        ),
      ),
      with: { chat: { with: { lastMsg: { with: { from: true, file: true } } } } },
      limit: MAX_LIMIT,
    })
    privateDialogs.forEach((d) => {
      dialogs.push(d)
      pushMessageAndUser(messages, users, d.chat?.lastMsg, currentUserId, peerIdFromChat(d.chat, { currentUserId }))
      if (d.chat) chats.push(d.chat)
    })

    // Create private chats and dialogs for members that don't have them
    if (space?.members) {
      const memberIds = space.members.map((m) => m.user.id)
      const existingPrivateChats = await db._query.chats.findMany({
        where: and(
          eq(schema.chats.type, "private"),
          or(
            and(eq(schema.chats.minUserId, currentUserId), inArray(schema.chats.maxUserId, memberIds)),
            and(eq(schema.chats.maxUserId, currentUserId), inArray(schema.chats.minUserId, memberIds)),
          ),
        ),
      })

      const existingChatMemberIds = new Set(
        existingPrivateChats.map((c) => (c.minUserId === currentUserId ? c.maxUserId : c.minUserId)),
      )

      const membersWithoutChats = space.members
        .filter((m) => m.user.id !== currentUserId)
        .filter((m) => !existingChatMemberIds.has(m.user.id))

      if (membersWithoutChats.length > 0) {
        // Create new private chats
        const newChats = await db.transaction(async (tx) => {
          const created: schema.DbChat[] = []
          for (const member of membersWithoutChats) {
            const [minUserId, maxUserId] = [
              Math.min(currentUserId, member.user.id),
              Math.max(currentUserId, member.user.id),
            ]
            const [chat] = await tx
              .insert(schema.chats)
              .values({
                type: "private",
                minUserId,
                maxUserId,
                date: new Date(),
              })
              .returning()
            if (chat) created.push(chat)
          }
          return created
        })

        // Create dialogs for new chats
        const newDialogs = await db.transaction(async (tx) => {
          const created: schema.DbDialog[] = []
          for (const chat of newChats) {
            const [dialog] = await tx
              .insert(schema.dialogs)
              .values({
                chatId: chat.id,
                peerUserId: chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId,
                userId: currentUserId,
                date: new Date(),
              })
              .returning()
            if (dialog) created.push(dialog)
          }
          return created
        })

        // Add new chats and dialogs to results
        newChats.forEach((c) => {
          chats.push(c)
          // No last message for new chats
          pushMessageAndUser(messages, users, null, currentUserId, peerIdFromChat(c, { currentUserId }))
        })
        newDialogs.forEach((d) => dialogs.push(d))
      }
    }

    // Add all space members as users
    space?.members.forEach((m) => users.push(m.user))
  }

  // --- 3. Ensure Dialogs Exist for All Chats ---
  // Find chats that do not have a dialog for the current user
  const chatIdsWithDialog = new Set(dialogs.map((d) => d.chatId))
  const missingDialogsChats = chats.filter((c) => !chatIdsWithDialog.has(c.id))

  if (missingDialogsChats.length > 0) {
    // Create missing dialogs in a single transaction
    const newDialogs = await db.transaction(async (tx) => {
      const created: schema.DbDialog[] = []
      for (const chat of missingDialogsChats) {
        // Only create if not already present (extra safety)
        if (!chatIdsWithDialog.has(chat.id)) {
          const values: any = {
            chatId: chat.id,
            userId: currentUserId,
          }
          // For thread chats, set spaceId
          if (chat.type === "thread") {
            values.spaceId = spaceId
          }
          const inserted = await tx.insert(schema.dialogs).values(values).returning()
          if (inserted[0]) created.push(inserted[0])
        }
      }
      return created
    })
    newDialogs.forEach((d) => dialogs.push(d))
  }

  // --- 4. Deduplicate Results ---
  dialogs = dedupeById(dialogs)
  chats = dedupeById(chats)
  // IDs are local to the thread, so we don't need to deduplicate
  //messages = dedupeById(messages)
  messages = messages
  users = dedupeById(users)

  // --- 5. Unread Counts ---
  const dialogsUnreads = await DialogsModel.getBatchUnreadCounts({
    userId: context.currentUserId,
    chatIds: dialogs.map((d) => d.chatId),
  })
  const dialogsEncoded = dialogs.map((dialog) => {
    const unreadCount = dialogsUnreads.find((uc) => uc.chatId === dialog.chatId)?.unreadCount ?? 0
    return encodeDialogInfo({ ...dialog, unreadCount })
  })

  // --- 6. Final Result ---
  let finalResult = {
    dialogs: dialogsEncoded,
    chats: chats.map((d) => encodeChatInfo(d, { currentUserId })),
    messages: messages,
    users: users.map(encodeFullUserInfo),
  }

  return finalResult
}

import type { StaticEncode } from "@sinclair/typebox/type"
import { DialogsModel } from "@in/server/db/models/dialogs"

/**
 * For private chats, we need the peer that represents the other user and not the current user
 * For thread chats, we need the threadId
 */
function peerIdFromChat(chat: schema.DbChat, context: { currentUserId: number }): StaticEncode<typeof TPeerInfo> {
  if (chat.type === "private") {
    if (chat.minUserId === null || chat.maxUserId === null) {
      Log.shared.error("Private chat has no minUserId or maxUserId", { chatId: chat.id })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    if (chat.minUserId === context.currentUserId) {
      return { userId: chat.maxUserId }
    } else if (chat.maxUserId === context.currentUserId) {
      return { userId: chat.minUserId }
    } else {
      Log.shared.error("Unknown peerId", { chatId: chat.id, currentUserId: context.currentUserId })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
  }
  return { threadId: chat.id }
}
