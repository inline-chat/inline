import { chats, dialogs } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { encodeChatSpaces, encodeViewerDialogs } from "@in/server/modules/chatList/chatListSidecars"
import {
  discoverCommonChatsPage,
  nextOffsetFor,
  parseCommonChatsRequest,
} from "@in/server/modules/chatList/pagedChatList"
import { withHistoryReadSnapshot } from "@in/server/modules/message/historySnapshot"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { GetCommonChatsInput, GetCommonChatsResult } from "@inline-chat/protocol/core"
import { and, eq, inArray } from "drizzle-orm"

/**
 * Threads the viewer shares with another user, latest activity first. Shared
 * means both hold an explicit grant and both currently have access. An unknown
 * or deleted user has none, so the list is empty rather than an error.
 */
export async function getCommonChats(
  input: Partial<GetCommonChatsInput>,
  context: FunctionContext,
): Promise<GetCommonChatsResult> {
  const viewerUserId = context.currentUserId
  const request = parseCommonChatsRequest(input, viewerUserId)
  return withHistoryReadSnapshot(async (tx) => {
    const rows = await discoverCommonChatsPage(tx, viewerUserId, request)
    const page = rows.slice(0, request.limit)
    const nextOffset = rows.length > request.limit ? nextOffsetFor({ order: "recent" }, page[page.length - 1]!) : undefined
    if (page.length === 0) return { chats: [], dialogs: [], spaces: [], nextOffset }

    const pageIds = page.map((row) => row.chatId)
    const position = new Map(pageIds.map((chatId, index) => [chatId, index]))
    const inPageOrder = (a: number, b: number) => position.get(a)! - position.get(b)!

    const chatRows = (await tx.select().from(chats).where(inArray(chats.id, pageIds)))
      .sort((a, b) => inPageOrder(a.id, b.id))
    const dialogRows = (await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.userId, viewerUserId), inArray(dialogs.chatId, pageIds))))
      .sort((a, b) => inPageOrder(a.chatId, b.chatId))

    return {
      chats: await Encoders.chatsForUser(chatRows, { encodingForUserId: viewerUserId, tx }),
      dialogs: await encodeViewerDialogs(tx, viewerUserId, dialogRows),
      spaces: await encodeChatSpaces(tx, viewerUserId, chatRows),
      nextOffset,
    }
  })
}
