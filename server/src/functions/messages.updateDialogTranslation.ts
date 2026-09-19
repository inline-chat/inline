import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { dialogs, users } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"

export async function updateDialogTranslation(
  input: { peerId: InputPeer; enabled: boolean; importLegacyEnabled?: boolean },
  context: FunctionContext,
): Promise<{ updates: Update[] }> {
  if (input.importLegacyEnabled && !input.enabled) throw RealtimeRpcError.BadRequest()
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)
  const peerId = encodeOutputPeerFromChat(chat, { currentUserId: context.currentUserId })
  const mutation = await db.transaction(async (tx) => {
    // Serialize the stored value and its durable sequence under the account owner.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, context.currentUserId)).for("update").limit(1)
    const [existing] = await tx.select().from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId))).limit(1)
    // Legacy devices contribute only enabled choices. A stored false can only
    // come from an explicit user action in a synced client, which must survive
    // late upgrades, retries, and delayed imports from other devices.
    const enabled = input.importLegacyEnabled && existing?.translationEnabled === false ? false : input.enabled
    const payload = { peerId, enabled }

    if (existing?.translationEnabled !== enabled) {
      await tx.insert(dialogs).values({
        chatId: chat.id,
        userId: context.currentUserId,
        peerUserId: chat.type === "private"
          ? (chat.minUserId === context.currentUserId ? chat.maxUserId : chat.minUserId)
          : null,
        spaceId: chat.spaceId,
        ...dialogOpenDefaultsForChat(chat),
        translationEnabled: enabled,
      }).onConflictDoUpdate({
        target: [dialogs.chatId, dialogs.userId],
        set: { translationEnabled: enabled },
      })
    }

    // Even a no-op needs an ordered result: replay persistence can delay this
    // response until after a newer preference has reached the requesting device.
    const queued = await UserBucketUpdates.enqueue({
      userId: context.currentUserId,
      update: { oneofKind: "userDialogTranslation", userDialogTranslation: payload },
    }, { tx })
    return { enabled, queued }
  })
  const { queued } = mutation

  const update: Update = {
    seq: queued.seq,
    date: encodeDateStrict(queued.date),
    update: { oneofKind: "dialogTranslation", dialogTranslation: { peerId, enabled: mutation.enabled } },
  }
  RealtimeUpdates.pushToUser(context.currentUserId, [update], { skipSessionId: context.currentSessionId })
  // Return the authoritative value even for an idempotent retry.
  return { updates: [update] }
}
