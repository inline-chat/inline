import { chatSubtreeIds, syncChatAccess } from "@in/server/modules/authorization/chatAccessSync"
import type { InputPeer, Peer, Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { chats, chatParticipants, type DbChat } from "@in/server/db/schema/chats"
import { dialogs } from "@in/server/db/schema/dialogs"
import { messages } from "@in/server/db/schema/messages"
import { translations } from "@in/server/db/schema/translations"
import { getSubthreadParentMessageRef } from "@in/server/modules/subthreads"
import { members } from "@in/server/db/schema/members"
import { Log } from "@in/server/utils/log"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq } from "drizzle-orm"
import { ModelError } from "@in/server/db/models/_errors"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { deleteBacklinkMessages, getBacklinkMessagesForSourceChat } from "@in/server/modules/threadGraph"
import {
  getRootChatIdsForAccessEvents,
  getEffectiveChatAccessUserIds,
} from "@in/server/modules/authorization/chatAccessProjection"
import { deleteSubthreadParentPlacement } from "@in/server/functions/messages.deleteMessage"
import { invalidateGridTranscriptionForHistory } from "@in/server/modules/grid/transcription/state"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"

const log = new Log("functions.deleteChat")
/**
 * Deletes a chat (thread).
 * - Space threads: admin/owner or the thread creator.
 * - Home threads: thread creator only.
 * Creator authority only counts while the creator still has access to the thread.
 * Threads with children must have their child threads deleted first.
 * Also deletes participants and dialogs for the chat.
 */
export async function deleteChat(input: { peer: InputPeer }, context: FunctionContext): Promise<{}> {
  return deleteChatWithOptions(input, context)
}

type DeleteChatOptions = {
  requireEmptyUntitledAfterClose?: boolean
}

async function deleteChatWithOptions(
  input: { peer: InputPeer },
  context: FunctionContext,
  options: DeleteChatOptions = {},
): Promise<{}> {
  const { peer } = input
  const { currentUserId } = context

  try {
    // Get chat
    const chat = await ChatModel.getChatFromInputPeerUnchecked(peer, { currentUserId })

    await ensureDeleteAllowed(chat, currentUserId)

    let persistedUpdate: UpdateSeqAndDate | undefined
    let accessUpdates: { userId: number; chatId: number; update: UpdateSeqAndDate }[] = []
    let recipientIds: number[] = []
    let peerId: Peer | undefined
    const backlinkMessages = await getBacklinkMessagesForSourceChat({ chatId: chat.id })
    // Delete chat, participants, dialogs in a transaction
    try {
      const didDelete = await db.transaction(async (tx) => {
        // Placement deletion uses the same parent -> child order as message
        // deletion. Lock before resolving the placement again under the child lock.
        const placement = await getSubthreadParentMessageRef(chat.id, tx)
        if (placement) {
          await tx.select({ id: chats.id }).from(chats).where(eq(chats.id, placement.parentChatId)).for("update")
        }
        const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
        if (!lockedChat) {
          throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat not found", 404)
        }

        // The preflight snapshot may have waited behind a writer. Recheck the
        // same policy on current rows before relying on creator/empty authority.
        await ensureDeleteAllowed(lockedChat, currentUserId, tx)

        if (options.requireEmptyUntitledAfterClose) {
          const [message] = await tx
            .select({ messageId: messages.messageId })
            .from(messages)
            .where(eq(messages.chatId, lockedChat.id))
            .limit(1)
          const [currentDialog] = await tx
            .select({ open: dialogs.open, pinned: dialogs.pinned })
            .from(dialogs)
            .where(and(eq(dialogs.chatId, lockedChat.id), eq(dialogs.userId, currentUserId)))
            .limit(1)

          const canDeleteClosedDraft =
            lockedChat.type === "thread" &&
            lockedChat.createdBy === currentUserId &&
            lockedChat.isUntitled === true &&
            (lockedChat.lastMsgId == null || lockedChat.lastMsgId === 0) &&
            message == null &&
            currentDialog?.open === false &&
            currentDialog.pinned !== true

          if (!canDeleteClosedDraft) {
            return false
          }
        }

        // FOR UPDATE also fences the FK key-share lock taken by concurrent
        // child insertion: children committed before this lock are visible here.
        const [child] = await tx.select({ id: chats.id }).from(chats)
          .where(eq(chats.parentChatId, lockedChat.id)).limit(1)
        if (child) {
          if (options.requireEmptyUntitledAfterClose) return false
          throw new RealtimeRpcError(
            RealtimeRpcError.Code.BAD_REQUEST,
            "Delete child threads before deleting this thread",
            400,
          )
        }

        const currentPlacement = await getSubthreadParentMessageRef(chat.id, tx)
        if (currentPlacement && currentPlacement.parentChatId !== placement?.parentChatId) {
          throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Thread placement changed; try again", 400)
        }
        await deleteSubthreadParentPlacement(chat.id, context, tx)
        await invalidateGridTranscriptionForHistory(tx, { chatIds: [lockedChat.id], reason: "chat_deleted" })

        peerId = Encoders.peerFromChat(lockedChat, { currentUserId })
        const recipientAccess = await getEffectiveChatAccessUserIds(tx, [lockedChat.id])
        recipientIds = Array.from(recipientAccess.get(lockedChat.id) ?? [])

        const accessEventChatIds = await getRootChatIdsForAccessEvents(tx, [lockedChat.id])
        const accessBefore = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)
        const accessRecipients = accessEventChatIds.flatMap((affectedChatId) =>
          Array.from(accessBefore.get(affectedChatId) ?? []).map((userId) => ({
            userId,
            chatId: affectedChatId,
          })),
        )
        const chatServerUpdatePayload: ServerUpdate["update"] = {
          oneofKind: "deleteChat",
          deleteChat: {
            chatId: BigInt(lockedChat.id),
          },
        }

        const update = await UpdatesModel.insertUpdate(tx, {
          update: chatServerUpdatePayload,
          bucket: UpdateBucket.Chat,
          entity: lockedChat,
        })

        persistedUpdate = update

        const persistedAccessUpdates = await UserBucketUpdates.enqueueMany(
          accessRecipients.map((recipient) => ({
            userId: recipient.userId,
            update: {
              oneofKind: "userRemovedFromChat" as const,
              userRemovedFromChat: {
                chatId: BigInt(recipient.chatId),
              },
            },
          })),
          { tx },
        )
        accessUpdates = accessRecipients.map((recipient, index) => ({
          ...recipient,
          update: persistedAccessUpdates[index]!,
        }))

        await syncChatAccess(tx, { kind: "chats", chatIds: await chatSubtreeIds(tx, [chat.id]) })
        await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, chat.id))
        await tx.delete(dialogs).where(eq(dialogs.chatId, chat.id))
        await tx.delete(translations).where(eq(translations.chatId, chat.id))
        await tx.delete(chats).where(eq(chats.id, chat.id))

        return true
      })

      if (!didDelete) {
        log.debug("Skipped conditional empty thread deletion", { chatId: chat.id, currentUserId })
        return {}
      }

      if (persistedUpdate && peerId) {
        const update: Update = {
          seq: persistedUpdate.seq,
          date: encodeDateStrict(persistedUpdate.date),
          update: {
            oneofKind: "deleteChat",
            deleteChat: {
              peerId: peerId,
            },
          },
        }

        recipientIds.forEach((userId) => {
          RealtimeUpdates.pushToUser(userId, [update])
        })

        accessUpdates.forEach((accessUpdate) => {
          RealtimeUpdates.pushToUser(accessUpdate.userId, [{
            seq: accessUpdate.update.seq,
            date: encodeDateStrict(accessUpdate.update.date),
            update: {
              oneofKind: "userRemovedFromChat",
              userRemovedFromChat: { chatId: BigInt(accessUpdate.chatId) },
            },
          }])
        })
      }

      await deleteBacklinkMessages(backlinkMessages, { currentUserId }).catch((error) => {
        log.error("Failed to delete backlink messages for deleted chat", {
          chatId: chat.id,
          currentUserId,
          error,
        })
      })

      log.info("Deleted chat and related data", { chatId: chat.id })
      return {}
    } catch (err) {
      if (err instanceof RealtimeRpcError) throw err
      log.error("Failed to delete chat", { chatId: chat.id, error: err })
      throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to delete chat", 500)
    }
  } catch (err) {
    if (err instanceof ModelError && err.code === ModelError.Codes.CHAT_INVALID) {
      throw RealtimeRpcError.ChatIdInvalid()
    }
    throw err
  }
}

async function ensureDeleteAllowed(
  chat: DbChat,
  currentUserId: number,
  query: Pick<typeof db, "select"> | Pick<Transaction, "select"> = db,
): Promise<void> {
  if (chat.type !== "thread") {
    log.error("Chat is not a thread", { chatId: chat.id })
    throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
  }

  // A creator removed from the Space or the thread keeps `createdBy`, so creator
  // authority only counts while they still have current access (Space membership
  // for Space threads, a participant grant for home threads).
  const isCreator =
    chat.createdBy === currentUserId && (await AccessGuards.hasChatAccess(chat, currentUserId, query))
  const trimmedTitle = chat.title?.trim() ?? ""
  const hasTitle = trimmedTitle.length > 0
  const hasMessages = chat.lastMsgId != null && chat.lastMsgId !== 0
  const isUntitled = chat.isUntitled === true || !hasTitle

  // Temporary: allow any participant to delete empty untitled threads until rollout is complete.
  const canParticipantDeleteEmptyThread = isUntitled && !hasMessages

  if (chat.spaceId) {
    // Check user role in space
    const [member] = await query.select().from(members)
      .where(and(eq(members.spaceId, chat.spaceId), eq(members.userId, currentUserId))).limit(1)
    if (!member) {
      log.error("User is not a member of space", { userId: currentUserId, spaceId: chat.spaceId })
      throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
    }

    const canDelete = member.role === "admin" || member.role === "owner" || isCreator
    if (!canDelete) {
      if (canParticipantDeleteEmptyThread) {
        if (chat.publicThread) {
          if (member.canAccessPublicChats) {
            // allow delete
          } else {
            log.error("User cannot access public chats in space", {
              userId: currentUserId,
              spaceId: chat.spaceId,
              chatId: chat.id,
            })
            throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
          }
        } else {
          const [participant] = await query.select().from(chatParticipants).where(and(
            eq(chatParticipants.chatId, chat.id),
            eq(chatParticipants.userId, currentUserId),
          )).limit(1)
          if (!participant) {
            log.error("User is not a participant in private thread", {
              userId: currentUserId,
              spaceId: chat.spaceId,
              chatId: chat.id,
            })
            throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
          }
        }
      } else {
        log.error("User is not admin/owner or creator in space", {
          userId: currentUserId,
          spaceId: chat.spaceId,
          chatId: chat.id,
        })
        throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
      }
    }
  } else if (!isCreator) {
    if (canParticipantDeleteEmptyThread) {
      const [participant] = await query.select().from(chatParticipants).where(and(
        eq(chatParticipants.chatId, chat.id),
        eq(chatParticipants.userId, currentUserId),
      )).limit(1)
      if (!participant) {
        log.error("User is not a participant for home thread", { userId: currentUserId, chatId: chat.id })
        throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
      }
    } else {
      log.error("User is not creator for home thread", { userId: currentUserId, chatId: chat.id })
      throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
    }
  }
}

export async function deleteEmptyUntitledThreadAfterClose(chatId: number, context: FunctionContext): Promise<{}> {
  return deleteChatWithOptions(
    {
      peer: {
        type: {
          oneofKind: "chat",
          chat: { chatId: BigInt(chatId) },
        },
      },
    },
    context,
    { requireEmptyUntitledAfterClose: true },
  )
}

export function queueEmptyUntitledThreadDeletionAfterClose(chatId: number, context: FunctionContext): void {
  queueMicrotask(() => {
    void deleteEmptyUntitledThreadAfterClose(chatId, context).catch((error) => {
      log.error("Failed background deletion of empty untitled thread", {
        chatId,
        currentUserId: context.currentUserId,
        error,
      })
    })
  })
}
