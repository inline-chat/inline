import type { InputPeer, Peer, Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { dialogs } from "@in/server/db/schema/dialogs"
import { members } from "@in/server/db/schema/members"
import { Log, LogLevel } from "@in/server/utils/log"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq } from "drizzle-orm"
import { ModelError } from "@in/server/db/models/_errors"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

const log = new Log("functions.deleteChat")
/**
 * Deletes a chat (thread).
 * - Space threads: admin/owner or the thread creator.
 * - Home threads: thread creator only.
 * Also deletes participants and dialogs for the chat.
 */
export async function deleteChat(input: { peer: InputPeer }, context: FunctionContext): Promise<{}> {
  const { peer } = input
  const { currentUserId } = context

  try {
    // Get chat
    const chat = await ChatModel.getChatFromInputPeer(peer, { currentUserId })

    if (chat.type !== "thread") {
      log.error("Chat is not a thread", { chatId: chat.id })
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
    }

    const isCreator = chat.createdBy === currentUserId
    const trimmedTitle = chat.title?.trim() ?? ""
    const hasTitle = trimmedTitle.length > 0
    const hasMessages = chat.lastMsgId != null && chat.lastMsgId !== 0

    // Temporary: allow any participant to delete empty untitled threads until rollout is complete.
    const canParticipantDeleteEmptyThread = !hasTitle && !hasMessages

    if (chat.spaceId) {
      // Check user role in space
      const member = await db._query.members.findFirst({
        where: and(eq(members.spaceId, chat.spaceId), eq(members.userId, currentUserId)),
      })
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
            const participant = await db._query.chatParticipants.findFirst({
              where: and(
                eq(chatParticipants.chatId, chat.id),
                eq(chatParticipants.userId, currentUserId),
              ),
            })
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
        const participant = await db._query.chatParticipants.findFirst({
          where: and(
            eq(chatParticipants.chatId, chat.id),
            eq(chatParticipants.userId, currentUserId),
          ),
        })
        if (!participant) {
          log.error("User is not a participant for home thread", { userId: currentUserId, chatId: chat.id })
          throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
        }
      } else {
        log.error("User is not creator for home thread", { userId: currentUserId, chatId: chat.id })
        throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
      }
    }

    let persistedUpdate: UpdateSeqAndDate | undefined
    let recipientIds: number[] = []
    let peerId: Peer | undefined

    // Delete chat, participants, dialogs in a transaction
    try {
      await db.transaction(async (tx) => {
        const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
        if (!lockedChat) {
          throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat not found", 404)
        }

        peerId = Encoders.peerFromChat(lockedChat, { currentUserId })

        if (lockedChat.publicThread) {
          const rows = await tx
            .select({ userId: members.userId })
            .from(members)
            .where(and(eq(members.spaceId, lockedChat.spaceId!), eq(members.canAccessPublicChats, true)))
          recipientIds = rows.map((row) => row.userId)
        } else {
          const rows = await tx
            .select({ userId: chatParticipants.userId })
            .from(chatParticipants)
            .where(eq(chatParticipants.chatId, lockedChat.id))
          recipientIds = rows.map((row) => row.userId)
        }

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

        await UserBucketUpdates.enqueueMany(
          recipientIds.map((userId) => ({
            userId,
            update: {
              oneofKind: "userChatParticipantDelete",
              userChatParticipantDelete: {
                chatId: BigInt(lockedChat.id),
              },
            },
          })),
          { tx },
        )

        await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, chat.id))
        await tx.delete(dialogs).where(eq(dialogs.chatId, chat.id))
        await tx.delete(chats).where(eq(chats.id, chat.id))
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
      }

      log.info("Deleted chat and related data", { chatId: chat.id })
      return {}
    } catch (err) {
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
