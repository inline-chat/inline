import type { InputPeer, Update } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Updates } from "@in/server/modules/updates/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"

type Input = {
  messageIds: bigint[]
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const deleteMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)
  await MessageModel.deleteMessages(input.messageIds, chatId)

  const update: Update = {
    update: {
      oneofKind: "deleteMessages",
      deleteMessages: {
        messageIds: input.messageIds.map((id) => BigInt(id)),
        peerId: Encoders.peerFromInputPeer({ inputPeer: input.peer, currentUserId: context.currentUserId }),
      },
    },
  }

  Updates.shared.pushUpdate([update], { peerId: input.peer, currentUserId: context.currentUserId })

  return { updates: [update] }
}
