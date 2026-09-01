import type { AcknowledgeMessagesInput, AcknowledgeMessagesResult, ChatAcknowledgement, Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { UpdatesModel } from "@in/server/db/models/updates"
import { chats, acknowledgements, messages, UpdateBucket } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { sendMessageToRealtimeUser } from "@in/server/realtime/message"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"

const log = new Log("functions.acknowledgeMessages")
const MAX_INT32 = 2_147_483_647

type CursorState = {
  maxId: number
  revision: number
  cleared: boolean
}

const encodeCursor = (chatId: number, userId: number, state: CursorState): ChatAcknowledgement => ({
  chatId: BigInt(chatId),
  userId: BigInt(userId),
  maxId: BigInt(state.maxId),
  revision: BigInt(state.revision),
  cleared: state.cleared,
})

const nextRevision = (updateSeq: number | null): number => {
  const current = updateSeq ?? 0
  if (!Number.isSafeInteger(current) || current < 0 || current >= MAX_INT32) {
    throw RealtimeRpcError.InternalError()
  }
  return current + 1
}

/** Explicit ACK state only: no read, notification, dialog, or reaction mutation. */
export async function acknowledgeMessages(input: AcknowledgeMessagesInput, context: FunctionContext): Promise<AcknowledgeMessagesResult> {
  if (!input.peerId) throw RealtimeRpcError.PeerIdInvalid()
  if (input.maxId <= 0n || input.maxId > BigInt(MAX_INT32)) throw RealtimeRpcError.BadRequest()
  if (input.expectedRevision < 0n || input.expectedRevision > BigInt(MAX_INT32)) throw RealtimeRpcError.BadRequest()
  const requestedMaxId = Number(input.maxId)
  const expectedRevision = Number(input.expectedRevision)
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const result = await db.transaction(async tx => {
    // One chat lock owns cursor intent order and durable sequence allocation.
    const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
    if (!lockedChat) throw RealtimeRpcError.ChatIdInvalid()
    // This uncached projection observes revocation that committed while we waited.
    const access = await getEffectiveChatAccessUserIds(tx, [chat.id], { userIds: [context.currentUserId] })
    if (!access.get(chat.id)?.has(context.currentUserId)) throw RealtimeRpcError.PeerIdInvalid()

    const [previous] = await tx.select({
      maxId: acknowledgements.maxId,
      revision: acknowledgements.revision,
      cleared: acknowledgements.cleared,
    }).from(acknowledgements)
      .where(and(eq(acknowledgements.chatId, chat.id), eq(acknowledgements.userId, context.currentUserId)))
      .limit(1)

    if (input.clear) {
      // Clear is compare-and-set against the marker the person actually saw.
      if (
        !previous
        || previous.cleared
        || previous.maxId !== requestedMaxId
        || previous.revision !== expectedRevision
      ) {
        return {
          acknowledgement: previous ? encodeCursor(chat.id, context.currentUserId, previous) : undefined,
          changed: false as const,
        }
      }

      const revision = nextRevision(lockedChat.updateSeq)
      const acknowledgement = encodeCursor(chat.id, context.currentUserId, {
        maxId: previous.maxId,
        revision,
        cleared: true,
      })
      await tx.update(acknowledgements)
        .set({ revision, cleared: true })
        .where(and(eq(acknowledgements.chatId, chat.id), eq(acknowledgements.userId, context.currentUserId)))
      const change = await UpdatesModel.insertUpdate(tx, {
        bucket: UpdateBucket.Chat,
        entity: lockedChat,
        update: { oneofKind: "acknowledgement", acknowledgement },
      })
      if (change.seq !== revision) throw RealtimeRpcError.InternalError()
      await tx.update(chats).set({ updateSeq: change.seq, lastUpdateDate: change.date }).where(eq(chats.id, chat.id))
      return { acknowledgement, changed: true as const, ...change }
    }

    // Validate an existing target even on no-op requests, while preserving deleted-target retry safety.
    const [target] = await tx.select({
      id: messages.messageId,
      fromId: messages.fromId,
      systemMessageEncrypted: messages.systemMessageEncrypted,
      systemMessageIv: messages.systemMessageIv,
      systemMessageTag: messages.systemMessageTag,
    }).from(messages)
      .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, requestedMaxId)))
      .for("key share")
      .limit(1)
    const isServiceTarget = target
      && (
        target.systemMessageEncrypted !== null
        || target.systemMessageIv !== null
        || target.systemMessageTag !== null
      )
    if (target && (target.fromId === context.currentUserId || isServiceTarget)) {
      throw RealtimeRpcError.BadRequest()
    }

    const advances = !previous || requestedMaxId > previous.maxId
    const reactivates = previous?.cleared === true
      && requestedMaxId === previous.maxId
      && expectedRevision === previous.revision
    if (!advances && !reactivates) {
      return {
        acknowledgement: previous ? encodeCursor(chat.id, context.currentUserId, previous) : undefined,
        changed: false as const,
      }
    }
    if (!target) throw RealtimeRpcError.BadRequest()

    const revision = nextRevision(lockedChat.updateSeq)
    const acknowledgement = encodeCursor(chat.id, context.currentUserId, {
      maxId: requestedMaxId,
      revision,
      cleared: false,
    })
    await tx.insert(acknowledgements).values({
      chatId: chat.id,
      userId: context.currentUserId,
      maxId: requestedMaxId,
      revision,
      cleared: false,
    }).onConflictDoUpdate({
      target: [acknowledgements.chatId, acknowledgements.userId],
      set: { maxId: requestedMaxId, revision, cleared: false },
    })
    const change = await UpdatesModel.insertUpdate(tx, {
      bucket: UpdateBucket.Chat,
      entity: lockedChat,
      update: { oneofKind: "acknowledgement", acknowledgement },
    })
    if (change.seq !== revision) throw RealtimeRpcError.InternalError()
    await tx.update(chats).set({ updateSeq: change.seq, lastUpdateDate: change.date }).where(eq(chats.id, chat.id))
    return { acknowledgement, changed: true as const, ...change }
  })

  const acknowledgement = result.acknowledgement
  if (!acknowledgement) return { updates: [] }

  const user = await (async () => {
    try {
      const [actor] = await UsersModel.getUsersWithPhotos([context.currentUserId])
      return actor ? encodeUser({ user: actor.user, photoFile: actor.photoFile, min: true }) : undefined
    } catch (error) {
      // The cursor and durable replay already committed. A missing profile
      // sidecar must not turn a successful ACK into a false RPC failure.
      log.warn("Failed to hydrate committed acknowledgement actor", {
        chatId: chat.id,
        userId: context.currentUserId,
        revision: acknowledgement.revision,
        error,
      })
      return undefined
    }
  })()
  const forViewer = (currentUserId: number): Update => ({
    ...(result.changed ? { seq: result.seq, date: encodeDateStrict(result.date) } : {}),
    update: { oneofKind: "acknowledgement", acknowledgement: {
      ...acknowledgement,
      user,
      peerId: encodeOutputPeerFromChat(chat, { currentUserId }),
    } },
  })

  if (result.changed) {
    try {
      const updateGroup = await getUpdateGroupFromInputPeer(input.peerId, context)
      await Promise.all(updateGroup.userIds.map(userId =>
        sendMessageToRealtimeUser(userId, {
          oneofKind: "update",
          update: { updates: [forViewer(userId)] },
        }, {
          skipSessionId: userId === context.currentUserId ? context.currentSessionId : undefined,
        })
      ))
    } catch (error) {
      // State and durable replay already committed; live fanout is best effort.
      log.warn("Failed to fan out committed acknowledgement update", {
        chatId: chat.id,
        userId: context.currentUserId,
        revision: acknowledgement.revision,
        error,
      })
    }
  }
  return { updates: [forViewer(context.currentUserId)] }
}
