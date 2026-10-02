import type { InputPeer, Peer, Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import type { DbChat } from "@in/server/db/schema"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { dialogs } from "@in/server/db/schema/dialogs"
import { messages } from "@in/server/db/schema/messages"
import { members } from "@in/server/db/schema/members"
import { users } from "@in/server/db/schema/users"
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
  lockChatAndAncestors,
} from "@in/server/modules/authorization/chatAccessProjection"
import {
  prepareSubthreadParentPlacementDeletion,
  pushSubthreadParentPlacementDeletion,
} from "@in/server/functions/messages.deleteMessage"

const log = new Log("functions.deleteChat")
/**
 * Deletes a chat (thread).
 * - Space threads: admin/owner or the thread creator.
 * - Home threads: thread creator only.
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
    const chat = await ChatModel.getChatFromInputPeer(peer, { currentUserId })

    if (chat.type !== "thread") {
      log.error("Chat is not a thread", { chatId: chat.id })
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
    }

    let persistedUpdate: UpdateSeqAndDate | undefined
    let accessUpdates: { userId: number; chatId: number; update: UpdateSeqAndDate }[] = []
    let recipientIds: number[] = []
    let peerId: Peer | undefined
    let placementDeletion: Awaited<ReturnType<typeof prepareSubthreadParentPlacementDeletion>>
    const backlinkMessages = await getBacklinkMessagesForSourceChat({ chatId: chat.id })
    // Delete chat, participants, dialogs in a transaction
    try {
      const didDelete = await db.transaction(async (tx) => {
        // Keep dialog FK KEY SHARE compatible until recipient frontiers own
        // their users; the DELETE below takes its natural exclusive row lock.
        const lockedChat = await lockChatAndAncestors(tx, chat.id, "no key update")
        if (!lockedChat) {
          throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat not found", 404)
        }

        await ensureChatDeletionAllowed(tx, lockedChat, currentUserId)

        const [child] = await tx
          .select({ id: chats.id })
          .from(chats)
          .where(eq(chats.parentChatId, lockedChat.id))
          .limit(1)
        if (child) {
          if (options.requireEmptyUntitledAfterClose) return false
          throw new RealtimeRpcError(
            RealtimeRpcError.Code.BAD_REQUEST,
            "Delete child chats before deleting their parent",
            400,
          )
        }

        const accessEventChatIds = await getRootChatIdsForAccessEvents(tx, [lockedChat.id])
        const accessBefore = await getEffectiveChatAccessUserIds(tx, accessEventChatIds)
        const accessRecipients = accessEventChatIds.flatMap((affectedChatId) =>
          Array.from(accessBefore.get(affectedChatId) ?? []).map((userId) => ({
            userId,
            chatId: affectedChatId,
          })),
        )

        if (options.requireEmptyUntitledAfterClose) {
          // Reopen and pin writers own users before their dialogs. Take every
          // frontier owner in that same order before deciding to discard a draft;
          // linked children still need their creator even without access events.
          const ownerIds = Array.from(new Set([currentUserId, ...accessRecipients.map(({ userId }) => userId)]))
            .sort((a, b) => a - b)
          for (const userId of ownerIds) {
            await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("no key update").limit(1)
          }
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

        placementDeletion = await prepareSubthreadParentPlacementDeletion(tx, lockedChat.id)

        peerId = Encoders.peerFromChat(lockedChat, { currentUserId })
        const recipientAccess = await getEffectiveChatAccessUserIds(tx, [lockedChat.id])
        recipientIds = Array.from(recipientAccess.get(lockedChat.id) ?? [])

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

        await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, chat.id))
        await tx.delete(dialogs).where(eq(dialogs.chatId, chat.id))
        await tx.delete(chats).where(eq(chats.id, chat.id))

        return true
      })

      if (!didDelete) {
        log.debug("Skipped conditional empty thread deletion", { chatId: chat.id, currentUserId })
        return {}
      }

      await pushSubthreadParentPlacementDeletion(placementDeletion, context).catch((error) => {
        // The ordinary parent delete update is already durable; live fanout
        // failure must not turn successful deletion into a failed RPC.
        log.warn("Failed to publish deleted subthread placement", { chatId: chat.id, error })
      })

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
      log.error("Failed to delete chat", { chatId: chat.id, error: err })
      if (err instanceof RealtimeRpcError) throw err
      throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to delete chat", 500)
    }
  } catch (err) {
    if (err instanceof ModelError && err.code === ModelError.Codes.CHAT_INVALID) {
      throw RealtimeRpcError.ChatIdInvalid()
    }
    throw err
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

async function ensureChatDeletionAllowed(tx: Transaction, chat: DbChat, currentUserId: number): Promise<void> {
  if (chat.type !== "thread") throw RealtimeRpcError.BadRequest()
  const isCreator = chat.createdBy === currentUserId
  const member = chat.spaceId === null ? undefined : await tx._query.members.findFirst({
    where: and(eq(members.spaceId, chat.spaceId), eq(members.userId, currentUserId)),
  })
  if (chat.spaceId !== null && !member) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
  }
  if (isCreator || member?.role === "admin" || member?.role === "owner") return

  // Retain the existing temporary empty-draft policy, using current state
  // under the mutation lock rather than the request's preflight snapshot.
  const isUntitled = chat.isUntitled === true || !chat.title?.trim()
  if (!isUntitled || (chat.lastMsgId != null && chat.lastMsgId !== 0)) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
  }
  const [message] = await tx.select({ id: messages.globalId }).from(messages).where(eq(messages.chatId, chat.id)).limit(1)
  if (message) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
  }
  if (chat.publicThread === true && chat.spaceId !== null) {
    if (member?.canAccessPublicChats) return
  } else {
    const participant = await tx._query.chatParticipants.findFirst({
      where: and(eq(chatParticipants.chatId, chat.id), eq(chatParticipants.userId, currentUserId)),
    })
    if (participant) return
  }
  throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
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
