import {
  type DialogNotificationSettings,
  type InputPeer,
  type Update,
} from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { ChatModel } from "@in/server/db/models/chats"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  encodeDialogNotificationSettings,
  isValidDialogNotificationMode,
} from "@in/server/modules/notifications/dialogNotificationSettings"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { RealtimeUpdates } from "@in/server/realtime/message"

type Input = {
  peerId: InputPeer
  notificationSettings?: DialogNotificationSettings
}

type Output = {
  updates: Update[]
}

const bytesEqual = (left: Uint8Array | null | undefined, right: Uint8Array | null): boolean => {
  if (!left && !right) {
    return true
  }

  if (!left || !right) {
    return false
  }

  if (left.length !== right.length) {
    return false
  }

  for (let i = 0; i < left.length; i += 1) {
    if (left[i] !== right[i]) {
      return false
    }
  }

  return true
}

export const updateDialogNotificationSettings = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const hasDialogSettings = input.notificationSettings !== undefined
  if (hasDialogSettings && !isValidDialogNotificationMode(input.notificationSettings?.mode)) {
    throw RealtimeRpcError.BadRequest()
  }

  const normalizedSettings = hasDialogSettings
    ? ({
        mode: input.notificationSettings!.mode,
      } satisfies DialogNotificationSettings)
    : undefined
  const nextBinary = encodeDialogNotificationSettings(normalizedSettings)
  const nextDbBinary = nextBinary ? Buffer.from(nextBinary) : null
  const peer = encodePeerFromInputPeer({ inputPeer: input.peerId, currentUserId: context.currentUserId })

  const didUpdate = await db.transaction(async (tx) => {
    const existing = await tx
      .select({
        id: dialogs.id,
        notificationSettings: dialogs.notificationSettings,
      })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId)))
      .limit(1)
      .then((rows) => rows[0])

    if (!existing) {
      if (!nextDbBinary) {
        return false
      }

      const peerUserId =
        chat.type === "private"
          ? chat.minUserId === context.currentUserId
            ? chat.maxUserId
            : chat.minUserId
          : null

      await tx.insert(dialogs).values({
        chatId: chat.id,
        userId: context.currentUserId,
        peerUserId: peerUserId ?? null,
        spaceId: chat.type === "thread" ? chat.spaceId : null,
        notificationSettings: nextDbBinary,
      })
    } else if (bytesEqual(existing.notificationSettings, nextDbBinary)) {
      return false
    } else {
      await tx
        .update(dialogs)
        .set({
          notificationSettings: nextDbBinary,
        })
        .where(eq(dialogs.id, existing.id))
    }

    const userUpdate: ServerUpdate["update"] = {
      oneofKind: "userDialogNotificationSettings",
      userDialogNotificationSettings: {
        peerId: peer,
        notificationSettings: normalizedSettings,
      },
    }

    await UserBucketUpdates.enqueue(
      {
        userId: context.currentUserId,
        update: userUpdate,
      },
      { tx },
    )

    return true
  })

  if (!didUpdate) {
    return { updates: [] }
  }

  const realtimeUpdate: Update = {
    update: {
      oneofKind: "dialogNotificationSettings",
      dialogNotificationSettings: {
        peerId: peer,
        notificationSettings: normalizedSettings,
      },
    },
  }

  RealtimeUpdates.pushToUser(context.currentUserId, [realtimeUpdate], {
    skipSessionId: context.currentSessionId,
  })

  return {
    updates: [realtimeUpdate],
  }
}
