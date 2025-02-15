import { db } from "@in/server/db"
import { Optional, Type, type Static } from "@sinclair/typebox"
import { presenceManager } from "@in/server/ws/presence"
import { encodeDialogInfo, TDialogInfo, TOptional } from "@in/server/api-types"
import { Log } from "@in/server/utils/log"
import { dialogs } from "../db/schema"
import { normalizeId, TInputId } from "../types/methods"
import { InlineError } from "../types/errors"
import { and, eq, or, sql } from "drizzle-orm"
import { DialogsModel } from "@in/server/db/models/dialogs"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  pinned: Optional(Type.Boolean()),
  peerId: Optional(TInputId),
  peerUserId: Optional(TInputId),
  peerThreadId: Optional(TInputId),
  draft: Optional(Type.String()),
  archived: Optional(Type.Boolean()),
})

export const Response = Type.Object({
  dialog: TDialogInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  const peerId: { userId: number } | { threadId: number } = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : input.peerThreadId
    ? { threadId: Number(input.peerThreadId) }
    : (input.peerId as unknown as { userId: number } | { threadId: number })

  if (!peerId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  let [dialog] = await db
    .update(dialogs)
    .set({ pinned: input.pinned ?? null, draft: input.draft ?? null, archived: input.archived ?? null })
    .where(
      and(
        eq(dialogs.userId, currentUserId),
        or(
          "userId" in peerId && peerId.userId ? eq(dialogs.peerUserId, peerId.userId) : sql`false`,
          "threadId" in peerId && peerId.threadId ? eq(dialogs.chatId, peerId.threadId) : sql`false`,
        ),
      ),
    )
    .returning()

  if (!dialog) {
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  // AI did this, check more
  const unreadCount = await DialogsModel.getUnreadCount(dialog.chatId, currentUserId)

  return { dialog: encodeDialogInfo({ ...dialog, unreadCount }) }
}
