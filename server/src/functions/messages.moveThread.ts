import { db } from "@in/server/db"
import { chats, chatParticipants, dialogs, members, type DbChat } from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { and, eq, inArray, sql } from "drizzle-orm"
import type { Update } from "@inline-chat/protocol/core"
import { getUpdateGroup, type UpdateGroup } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import type { FunctionContext } from "@in/server/functions/_types"

const log = new Log("functions.moveThread")

type MoveThreadInput = {
  chatId: number
  // If undefined/null, move to home.
  spaceId?: number | null
}

export async function moveThread(
  input: MoveThreadInput,
  context: FunctionContext,
): Promise<{ chat: DbChat }> {
  const chatId = Number(input.chatId)
  if (!Number.isSafeInteger(chatId) || chatId <= 0) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  const targetSpaceId = input.spaceId === undefined || input.spaceId === null ? null : Number(input.spaceId)
  if (targetSpaceId !== null && (!Number.isSafeInteger(targetSpaceId) || targetSpaceId <= 0)) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Space ID is invalid", 400)
  }

  let updatedChat: DbChat | undefined
  let updatePayload: ServerUpdate["update"] | undefined

  try {
    const result = await db.transaction(async (tx): Promise<{ chat: DbChat; updatePayload?: ServerUpdate["update"] }> => {
      const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)

      if (!chat) {
        throw RealtimeRpcError.ChatIdInvalid()
      }

      if (chat.type !== "thread") {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
      }

      // v1: only private threads.
      // Future: allow moving public threads out of a space (likely converting members to participants).
      if (chat.publicThread) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Only private threads can be moved", 400)
      }

      const currentSpaceId = chat.spaceId ?? null

      // v1: only home <-> space moves. Cross-space later.
      if (currentSpaceId !== null && targetSpaceId !== null && currentSpaceId !== targetSpaceId) {
        throw new RealtimeRpcError(
          RealtimeRpcError.Code.BAD_REQUEST,
          "Cross-space thread moves are not supported yet",
          400,
        )
      }

      if (currentSpaceId === targetSpaceId) {
        // No-op.
        return { chat }
      }

      const isCreator = chat.createdBy !== null && chat.createdBy === context.currentUserId

      // Authorization:
      // - creator can always move (subject to participant/membership rules below)
      // - space admins/owners can move threads in/out of that space
      if (targetSpaceId !== null) {
        // Moving into a space: require admin/owner in target OR creator.
        const [member] = await tx
          .select({ role: members.role })
          .from(members)
          .where(and(eq(members.spaceId, targetSpaceId), eq(members.userId, context.currentUserId)))
          .limit(1)

        const isAdminOrOwner = member?.role === "admin" || member?.role === "owner"
        if (!isCreator && !isAdminOrOwner) {
          throw RealtimeRpcError.SpaceAdminRequired()
        }
      } else {
        // Moving to home: if coming from a space, require admin/owner in that space OR creator.
        if (currentSpaceId !== null) {
          const [member] = await tx
            .select({ role: members.role })
            .from(members)
            .where(and(eq(members.spaceId, currentSpaceId), eq(members.userId, context.currentUserId)))
            .limit(1)

          const isAdminOrOwner = member?.role === "admin" || member?.role === "owner"
          if (!isCreator && !isAdminOrOwner) {
            throw RealtimeRpcError.SpaceAdminRequired()
          }
        }
      }

      const participantRows = await tx
        .select({ userId: chatParticipants.userId })
        .from(chatParticipants)
        .where(eq(chatParticipants.chatId, chat.id))

      const participantIds = participantRows.map((r) => r.userId)
      if (participantIds.length === 0) {
        // Private threads should always have participants.
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Thread has no participants", 400)
      }

      if (targetSpaceId !== null) {
        // v1: simplest rule. All participants must be members of the target space.
        //
        // Future: allow external participants in space threads.
        const memberRows = await tx
          .select({ userId: members.userId })
          .from(members)
          .where(and(eq(members.spaceId, targetSpaceId), inArray(members.userId, participantIds)))

        if (memberRows.length !== participantIds.length) {
          throw new RealtimeRpcError(
            RealtimeRpcError.Code.BAD_REQUEST,
            "All participants must be space members",
            400,
          )
        }
      }

      let nextThreadNumber: number | null = null
      if (targetSpaceId !== null) {
        const maxThreadNumber: number = await tx
          .select({ maxThreadNumber: sql<number>`MAX(${chats.threadNumber})` })
          .from(chats)
          .where(eq(chats.spaceId, targetSpaceId))
          .then((result) => result[0]?.maxThreadNumber ?? 0)

        nextThreadNumber = maxThreadNumber + 1

        // v1: keep space title uniqueness behavior consistent with createChat.
        // Home threads are intentionally not unique.
        const trimmedTitle = chat.title?.trim()
        if (trimmedTitle) {
          const titleLower = trimmedTitle.toLowerCase()
          const duplicate = await tx
            .select({ id: chats.id })
            .from(chats)
            .where(
              and(
                eq(chats.type, "thread"),
                eq(chats.spaceId, targetSpaceId),
                // exclude self
                sql`${chats.id} <> ${chat.id}`,
                sql`lower(trim(${chats.title})) = ${titleLower}`,
              ),
            )
            .limit(1)

          if (duplicate.length > 0) {
            throw new RealtimeRpcError(
              RealtimeRpcError.Code.BAD_REQUEST,
              "A thread with that name already exists",
              400,
            )
          }
        }
      }

      updatePayload = {
        oneofKind: "chatMoved",
        chatMoved: {
          chatId: BigInt(chat.id),
          ...(currentSpaceId !== null ? { oldSpaceId: BigInt(currentSpaceId) } : {}),
          ...(targetSpaceId !== null ? { newSpaceId: BigInt(targetSpaceId) } : {}),
        },
      }

      const update = await UpdatesModel.insertUpdate(tx, {
        update: updatePayload,
        bucket: UpdateBucket.Chat,
        entity: chat,
      })

      const [chatRecord] = await tx
        .update(chats)
        .set({
          spaceId: targetSpaceId,
          threadNumber: targetSpaceId !== null ? nextThreadNumber : null,
          updateSeq: update.seq,
          lastUpdateDate: update.date,
        })
        .where(eq(chats.id, chat.id))
        .returning()

      if (!chatRecord) {
        throw RealtimeRpcError.InternalError()
      }

      // Ensure dialogs exist for all participants and reflect the new location (home vs space).
      // NOTE: Today we do not support external participants in space threads; when we do, this will
      // need to decide whether to create dialogs for non-members and how they should appear.
      await tx
        .insert(dialogs)
        .values(
          participantIds.map((userId) => ({
            chatId: chat.id,
            userId,
            spaceId: targetSpaceId,
            peerUserId: null,
            date: new Date(),
          })),
        )
        .onConflictDoUpdate({
          target: [dialogs.chatId, dialogs.userId],
          set: { spaceId: targetSpaceId },
        })

      return { chat: chatRecord, updatePayload }
    })

    updatedChat = result.chat
    updatePayload = result.updatePayload
  } catch (error) {
    log.error("Failed to move thread", { chatId, targetSpaceId, error })
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to move thread", 500)
  }

  if (!updatedChat) {
    throw RealtimeRpcError.InternalError()
  }

  if (updatePayload && updatePayload.oneofKind === "chatMoved") {
    await pushUpdates({
      chat: updatedChat,
      updatePayload,
      currentUserId: context.currentUserId,
    })
  }

  return { chat: updatedChat }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

const pushUpdates = async ({
  chat,
  updatePayload,
  currentUserId,
}: {
  chat: DbChat
  updatePayload: ServerUpdate["update"]
  currentUserId: number
}): Promise<{ updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chat.id }, { currentUserId })

  if (updatePayload.oneofKind !== "chatMoved") {
    return { updateGroup }
  }

  updateGroup.userIds.forEach((userId) => {
    const update: Update = {
      update: {
        oneofKind: "chatMoved",
        chatMoved: {
          chat: Encoders.chat(chat, { encodingForUserId: userId }),
          ...(updatePayload.chatMoved.oldSpaceId !== undefined ? { oldSpaceId: updatePayload.chatMoved.oldSpaceId } : {}),
          ...(updatePayload.chatMoved.newSpaceId !== undefined ? { newSpaceId: updatePayload.chatMoved.newSpaceId } : {}),
        },
      },
    }
    RealtimeUpdates.pushToUser(userId, [update])
  })

  return { updateGroup }
}
