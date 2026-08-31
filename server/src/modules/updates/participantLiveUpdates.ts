import type { Update } from "@inline-chat/protocol/core"
import { getUpdateGroup } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"

/** Replay carries sidecars without synthesizing an unsequenced newChat action
 * that would incorrectly open recipients' inboxes. Also used after a failed
 * post-commit removal projection; only this exact Chat bucket is requested. */
export async function pushChatCatchupHintsBestEffort(input: {
  chatId: number
  currentUserId: number
  updateSeq: number
}): Promise<void> {
  try {
    const group = await getUpdateGroup({ threadId: input.chatId }, { currentUserId: input.currentUserId })
    const hint: Update = { update: {
      oneofKind: "chatHasNewUpdates",
      chatHasNewUpdates: {
        chatId: BigInt(input.chatId),
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(input.chatId) } } },
        updateSeq: input.updateSeq,
      },
    } }
    await Promise.all(group.userIds.map((userId) => RealtimeUpdates.pushToUser(userId, [hint])))
  } catch (error) {
    Log.shared.warn("Failed to push targeted participant catch-up hint", {
      chatId: input.chatId,
      updateSeq: input.updateSeq,
      error,
    })
  }
}

/** User access events are already persisted. An unrelated recipient's socket
 * failure must not prevent this user's authoritative grant/removal delivery. */
export async function pushParticipantUserUpdateBestEffort(userId: number, update: Update): Promise<void> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await RealtimeUpdates.pushToUser(userId, [update])
      return
    } catch {
      if (attempt === 1) {
        Log.shared.warn("Participant access delivery failed; durable user replay retained", { userId, seq: update.seq })
      }
    }
  }
}
