import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { dialogs } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"
import { isLinkedSubthread } from "@in/server/modules/subthreads"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { sql } from "drizzle-orm"

type Input = {
  peerId: InputPeer
  maxId?: bigint
}

type Output = {
  updates: Update[]
}

export const collapseHistory = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  if (
    input.maxId !== undefined &&
    (input.maxId <= 0n || chat.lastMsgId === null || input.maxId > BigInt(chat.lastMsgId))
  ) {
    throw RealtimeRpcError.BadRequest()
  }

  const requestedMaxId = input.maxId === undefined ? null : Number(input.maxId)
  const peer = encodePeerFromInputPeer({ inputPeer: input.peerId, currentUserId: context.currentUserId })
  const peerUserId =
    chat.type === "private"
      ? chat.minUserId === context.currentUserId
        ? chat.maxUserId
        : chat.minUserId
      : null

  const effectiveMaxId = await db.transaction(async (tx) => {
    const [dialog] = await tx
      .insert(dialogs)
      .values({
        chatId: chat.id,
        userId: context.currentUserId,
        peerUserId: peerUserId ?? null,
        spaceId: chat.type === "thread" ? chat.spaceId : null,
        collapsedMaxId: requestedMaxId,
        ...dialogOpenDefaultsForChat(chat),
        ...(isLinkedSubthread(chat) ? { chatListHidden: true } : {}),
      })
      .onConflictDoUpdate({
        target: [dialogs.chatId, dialogs.userId],
        set: {
          collapsedMaxId:
            requestedMaxId === null
              ? null
              : sql`GREATEST(COALESCE(${dialogs.collapsedMaxId}, 0), ${requestedMaxId})`,
        },
      })
      .returning({ collapsedMaxId: dialogs.collapsedMaxId })

    if (!dialog) {
      throw RealtimeRpcError.InternalError()
    }

    const maxId = dialog.collapsedMaxId === null ? undefined : BigInt(dialog.collapsedMaxId)
    const userUpdate: ServerUpdate["update"] = {
      oneofKind: "userDialogCollapsedMaxId",
      userDialogCollapsedMaxId: {
        peerId: peer,
        maxId,
      },
    }

    await UserBucketUpdates.enqueue(
      {
        userId: context.currentUserId,
        update: userUpdate,
      },
      { tx },
    )

    return maxId
  })

  const update: Update = {
    update: {
      oneofKind: "dialogCollapsedMaxId",
      dialogCollapsedMaxId: {
        peerId: peer,
        maxId: effectiveMaxId,
      },
    },
  }

  RealtimeUpdates.pushToUser(context.currentUserId, [update], {
    skipSessionId: context.currentSessionId,
  })

  return { updates: [update] }
}
