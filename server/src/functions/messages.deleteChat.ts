import type { InputPeer, Peer, Update } from "@in/protocol/core"
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
import type { ServerUpdate } from "@in/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

const log = new Log("functions.deleteChat")
/**
 * Deletes a chat (space thread) if the user is an admin/owner of the space.
 * Also deletes participants and dialogs for the chat.
 */
export async function deleteChat(input: { peer: InputPeer }, context: FunctionContext): Promise<{}> {
  const { peer } = input
  const { currentUserId } = context

  try {
    // Get chat
    const chat = await ChatModel.getChatFromInputPeer(peer, { currentUserId })

    if (!chat.spaceId || chat.type !== "thread") {
      log.error("Chat is not a space thread", { chatId: chat.id })
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a space thread", 400)
    }

    // Check user role in space
    const member = await db._query.members.findFirst({
      where: and(eq(members.spaceId, chat.spaceId), eq(members.userId, currentUserId)),
    })
    if (!member || (member.role !== "admin" && member.role !== "owner")) {
      log.error("User is not admin/owner in space", { userId: currentUserId, spaceId: chat.spaceId })
      throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
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

        for (const userId of recipientIds) {
          const userServerUpdatePayload: ServerUpdate["update"] = {
            oneofKind: "userChatParticipantDelete",
            userChatParticipantDelete: {
              chatId: BigInt(lockedChat.id),
            },
          }
          await UserBucketUpdates.enqueue(
            {
              userId,
              update: userServerUpdatePayload,
            },
            { tx },
          )
        }

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
