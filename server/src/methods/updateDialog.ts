import { db } from "@in/server/db"
import { Optional, Type, type Static } from "@sinclair/typebox"
import { encodeDialogInfo, TDialogInfo } from "@in/server/api-types"
import { chats, dialogs, users } from "../db/schema"
import { TInputId } from "../types/methods"
import { InlineError } from "../types/errors"
import { and, eq, or, sql } from "drizzle-orm"
import { DialogsModel } from "@in/server/db/models/dialogs"
import type { HandlerContext } from "@in/server/controllers/helpers"
import type { Peer, Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import {
  emitChatListOpenUpdates,
  getChatById,
  isLinkedSubthread,
  promoteLinkedSubthreadDialogsToChatList,
} from "@in/server/modules/subthreads"
import { dialogOpenDefaultsForChat, dialogOpenFieldsForOpen, nextDialogOrder } from "@in/server/modules/dialogOpen"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"

const TDialogOrder = Type.String({ minLength: 1, maxLength: 128, pattern: "^[0-9A-Za-z]+$" })

export const Input = Type.Object({
  pinned: Optional(Type.Boolean()),
  peerId: Optional(TInputId),
  peerUserId: Optional(TInputId),
  peerThreadId: Optional(TInputId),
  /** @deprecated Current clients keep compose drafts locally. */
  draft: Optional(Type.String()),
  archived: Optional(Type.Boolean()),
  order: Optional(TDialogOrder),
  pinnedOrder: Optional(TDialogOrder),
})

export const Response = Type.Object({
  dialog: TDialogInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId, currentSessionId }: HandlerContext,
): Promise<Static<typeof Response>> => {
  if (input.order !== undefined && !FractionalIndex.isValid(input.order)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  if (input.pinnedOrder !== undefined && !FractionalIndex.isValid(input.pinnedOrder)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

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
  let shouldPromoteToChatList = false

  let dialog = await db.transaction(async (tx) => {
    // Protect the chat lifetime before taking the user owner: participant writers
    // lock chats before allocating user updates, and INSERT needs the chat FK lock.
    const chat = input.archived !== undefined && "threadId" in peerId
      ? (await tx.select().from(chats).where(eq(chats.id, peerId.threadId)).for("key share").limit(1))[0]
      : undefined
    // Serialize archive state reads and pin/open allocation before touching dialogs.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, currentUserId)).for("no key update").limit(1)

    const stateFields = {
      archived: dialogs.archived,
      chatListHidden: dialogs.chatListHidden,
      chatId: dialogs.chatId,
      open: dialogs.open,
      order: dialogs.order,
      pinnedOrder: dialogs.pinnedOrder,
    }
    let [existingDialog] = await tx
      .select(stateFields)
      .from(dialogs)
      .where(whereClause)
      .limit(1)

    if (!existingDialog) {
      if (input.archived === undefined || !("threadId" in peerId)) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }

      // Invitations grant access before the invitee's first dialog is materialized.
      // Archive only needs a personal preference row; it must not change membership or follow/open choices.
      if (!chat || chat.type !== "thread") {
        throw new InlineError(InlineError.ApiError.PEER_INVALID)
      }
      try {
        await AccessGuards.ensureChatAccess(chat, currentUserId, tx)
      } catch (error) {
        if (
          RealtimeRpcError.is(error, RealtimeRpcError.Code.PEER_ID_INVALID)
          || RealtimeRpcError.is(error, RealtimeRpcError.Code.SPACE_ID_INVALID)
        ) {
          throw new InlineError(InlineError.ApiError.PEER_INVALID, { cause: error })
        }
        throw error
      }

      const [createdDialog] = await tx
        .insert(dialogs)
        .values({
          chatId: chat.id,
          userId: currentUserId,
          spaceId: chat.spaceId,
          ...dialogOpenDefaultsForChat(chat),
          ...(isLinkedSubthread(chat) ? { chatListHidden: true } : {}),
        })
        .onConflictDoNothing({ target: [dialogs.chatId, dialogs.userId] })
        .returning(stateFields)
      existingDialog = createdDialog ?? (await tx.select(stateFields).from(dialogs).where(whereClause).limit(1))[0]
      if (!existingDialog) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }
    }

    previousArchived = existingDialog.archived
    const shouldPromoteForPin = input.pinned === true && existingDialog.chatListHidden === true
    const shouldPromoteForUnarchive =
      input.archived === false && existingDialog.archived === true && existingDialog.chatListHidden === true
    shouldPromoteToChatList = shouldPromoteForPin || shouldPromoteForUnarchive

    const updateSet: Partial<typeof dialogs.$inferInsert> = {}
    if (input.pinned !== undefined) updateSet.pinned = input.pinned
    if (input.draft !== undefined) updateSet.draft = input.draft
    if (input.archived !== undefined) updateSet.archived = input.archived
    if (input.pinned === true) {
      const order = existingDialog.order ?? input.order ?? (await nextDialogOrder(tx, currentUserId))
      const pinnedOrder =
        existingDialog.pinnedOrder ?? input.pinnedOrder ?? (await nextDialogOrder(tx, currentUserId, "pinned"))
      Object.assign(updateSet, dialogOpenFieldsForOpen(existingDialog, order))
      updateSet.pinnedOrder = pinnedOrder
    }
    if (input.pinned === false && existingDialog.open === true && !existingDialog.order) {
      updateSet.order = input.order ?? (await nextDialogOrder(tx, currentUserId))
    }

    const updatedDialog =
      Object.keys(updateSet).length > 0
        ? (await tx.update(dialogs).set(updateSet).where(whereClause).returning())[0]
        : (await tx.select().from(dialogs).where(whereClause).limit(1))[0]

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

  if (shouldPromoteToChatList && dialog.chatId) {
    const chat = await getChatById(dialog.chatId)
    if (chat && isLinkedSubthread(chat)) {
      const { activatedDialogs } = await promoteLinkedSubthreadDialogsToChatList({
        chat,
        userIds: [currentUserId],
      })
      await emitChatListOpenUpdates({
        chat,
        dialogs: activatedDialogs,
      })

      const promotedDialog = activatedDialogs.find((candidate) => candidate.userId === currentUserId)
      if (promotedDialog) {
        dialog = promotedDialog
      }
    }
  }

  // AI did this, check more
  const unreadCount = await DialogsModel.getUnreadCount(dialog.chatId, currentUserId)

  return { dialog: encodeDialogInfo({ ...dialog, unreadCount }) }
}
