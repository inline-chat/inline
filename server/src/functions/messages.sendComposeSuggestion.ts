import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import type { FunctionContext } from "@in/server/functions/_types"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { InlineError } from "@in/server/types/errors"

/** A suggestion is a short next message, not a document. */
export const MAX_COMPOSE_SUGGESTION_CHARS = 500

type Input = {
  peer: InputPeer
  userId: number
  text: string
  afterMessageId?: bigint
}

/**
 * A bot's suggested next message for one participant's composer. Ephemeral like
 * compose actions: nothing is stored, and only `userId` receives it.
 */
export const sendComposeSuggestion = async (input: Input, context: FunctionContext): Promise<{}> => {
  const isBot = context.isBot ?? (await UsersModel.getUserById(context.currentUserId))?.bot === true
  if (!isBot) throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  if (input.userId === context.currentUserId) throw new InlineError(InlineError.ApiError.BAD_REQUEST)

  const text = input.text.trim()
  if (text.length > MAX_COMPOSE_SUGGESTION_CHARS) throw new InlineError(InlineError.ApiError.BAD_REQUEST)

  // Recipient projection is not authorization: the bot must have current
  // access to the chat, and the recipient must be one of its members.
  await ChatModel.getAuthorizedChatFromInputPeer(input.peer, context)
  const updateGroup = await getUpdateGroupFromInputPeer(input.peer, { currentUserId: context.currentUserId })
  if (!updateGroup.userIds.includes(input.userId)) throw new InlineError(InlineError.ApiError.BAD_REQUEST)

  const peerForRecipient: InputPeer = updateGroup.type === "dmUsers"
    ? { type: { oneofKind: "user", user: { userId: BigInt(context.currentUserId) } } }
    : input.peer

  const update: Update = {
    update: {
      oneofKind: "composeSuggestion",
      composeSuggestion: {
        userId: BigInt(context.currentUserId),
        peerId: encodePeerFromInputPeer({ inputPeer: peerForRecipient, currentUserId: input.userId }),
        text,
        afterMessageId: input.afterMessageId,
      },
    },
  }
  await RealtimeUpdates.pushToUser(input.userId, [update])
  return {}
}
