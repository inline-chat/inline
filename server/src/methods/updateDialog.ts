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
import type { HandlerContext } from "@in/server/controllers/helpers"
import type { Peer, Update } from "@in/protocol/core"
import type { ServerUpdate } from "@in/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"

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
  { currentUserId, currentSessionId }: HandlerContext,
): Promise<Static<typeof Response>> => {
  const peerId: { userId: number } | { threadId: number } = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : input.peerThreadId
    ? { threadId: Number(input.peerThreadId) }
    : (input.peerId as unknown as { userId: number } | { threadId: number })

  if (!peerId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  const whereClause = and(
    eq(dialogs.userId, currentUserId),
    or(
      "userId" in peerId && peerId.userId ? eq(dialogs.peerUserId, peerId.userId) : sql`false`,
      "threadId" in peerId && peerId.threadId ? eq(dialogs.chatId, peerId.threadId) : sql`false`,
    ),
  )

  const outputPeer: Peer | null =
    "userId" in peerId && peerId.userId
      ? { type: { oneofKind: "user", user: { userId: BigInt(peerId.userId) } } }
      : "threadId" in peerId && peerId.threadId
        ? { type: { oneofKind: "chat", chat: { chatId: BigInt(peerId.threadId) } } }
        : null

  if (!outputPeer) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  let previousArchived: boolean | null | undefined
  let shouldPublishArchiveUpdate = false

  let dialog = await db.transaction(async (tx) => {
    const [existingDialog] = await tx
      .select({ archived: dialogs.archived })
      .from(dialogs)
      .where(whereClause)
      .limit(1)

    if (!existingDialog) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    previousArchived = existingDialog.archived

    const [updatedDialog] = await tx
      .update(dialogs)
      .set({ pinned: input.pinned ?? null, draft: input.draft ?? null, archived: input.archived ?? null })
      .where(whereClause)
      .returning()

    if (!updatedDialog) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    shouldPublishArchiveUpdate = input.archived !== undefined && input.archived !== previousArchived

    if (shouldPublishArchiveUpdate) {
      const userUpdate: ServerUpdate["update"] = {
        oneofKind: "userDialogArchived",
        userDialogArchived: {
          peerId: outputPeer,
          archived: input.archived ?? false,
        },
      }

      await UserBucketUpdates.enqueue({ userId: currentUserId, update: userUpdate }, { tx })
    }

    return updatedDialog
  })

  if (!dialog) {
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  if (shouldPublishArchiveUpdate) {
    const update: Update = {
      update: {
        oneofKind: "dialogArchived",
        dialogArchived: {
          peerId: outputPeer,
          archived: input.archived ?? false,
        },
      },
    }

    RealtimeUpdates.pushToUser(currentUserId, [update], { skipSessionId: currentSessionId })
  }

  // AI did this, check more
  const unreadCount = await DialogsModel.getUnreadCount(dialog.chatId, currentUserId)

  return { dialog: encodeDialogInfo({ ...dialog, unreadCount }) }
}
