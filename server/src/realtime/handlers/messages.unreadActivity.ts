import type {
  GetUnreadActivityInput,
  GetUnreadActivityResult,
  InputPeer,
  ReadActivityInput,
  ReadActivityResult,
} from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { ChatModel } from "@in/server/db/models/chats"
import { ModelError } from "@in/server/db/models/_errors"
import { listUnreadActivity, readActivity as readActivityModule } from "@in/server/modules/activityItems"

async function resolveAccessibleChat(peer: InputPeer | undefined, handlerContext: HandlerContext) {
  if (!peer) throw RealtimeRpcError.PeerIdInvalid()
  return await ChatModel.getAuthorizedChatFromInputPeer(peer, { currentUserId: handlerContext.userId }).catch((error) => {
    if (error instanceof ModelError && error.code === ModelError.Codes.CHAT_INVALID) {
      if (peer.type.oneofKind === "chat") throw RealtimeRpcError.ChatIdInvalid()
      throw RealtimeRpcError.PeerIdInvalid()
    }
    throw error
  })
}

function messageId(value: bigint | undefined): number | undefined {
  if (value === undefined) return undefined
  const id = Number(value)
  if (!Number.isSafeInteger(id) || id < 0) throw RealtimeRpcError.BadRequest()
  return id
}

export const getUnreadActivity = async (
  input: GetUnreadActivityInput,
  handlerContext: HandlerContext,
): Promise<GetUnreadActivityResult> => {
  const chat = await resolveAccessibleChat(input.peerId, handlerContext)
  const result = await listUnreadActivity({
    userId: handlerContext.userId,
    chatId: chat.id,
    reactions: input.reactions,
    offsetId: messageId(input.offsetId),
    limit: input.limit,
  })
  return {
    messageIds: result.messageIds.map(BigInt),
    unreadMentionsCount: result.counts.mentions,
    unreadReactionsCount: result.counts.reactions,
    final: result.final,
  }
}

export const readActivity = async (
  input: ReadActivityInput,
  handlerContext: HandlerContext,
): Promise<ReadActivityResult> => {
  if (input.messageIds.length > 1000) throw RealtimeRpcError.BadRequest()
  const chat = await resolveAccessibleChat(input.peerId, handlerContext)
  // Changes reach every session, this one included, through the ordered user stream.
  await readActivityModule({
    userId: handlerContext.userId,
    chat,
    messageIds: input.messageIds.map((id) => messageId(id) ?? 0),
    allMentions: input.allMentions,
    allReactions: input.allReactions,
    maxId: messageId(input.maxId),
  })
  return {}
}
