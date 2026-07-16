import type { Chat, InputPeer, Update } from "@inline-chat/protocol/core"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { ChatMetadataUpdate } from "@in/server/modules/chatMetadataUpdates"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"

export const pushChatMetadataUpdates = async ({
  currentUserId,
  chatUpdates,
}: {
  currentUserId: number
  chatUpdates: ChatMetadataUpdate[]
}): Promise<{ selfUpdates: Update[] }> => {
  const selfUpdates: Update[] = []

  for (const chatUpdate of chatUpdates) {
    const inputPeer: InputPeer = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chatUpdate.chat.id) },
      },
    }
    const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })
    const chatsByUserId = await Encoders.chatForUsers(chatUpdate.chat, updateGroup.userIds)

    for (const userId of updateGroup.userIds) {
      const chat = chatsByUserId.get(userId)
      if (!chat) {
        continue
      }
      const update = buildChatMetadataUpdate({
        chat,
        update: chatUpdate.update,
      })

      RealtimeUpdates.pushToUser(userId, [update])
      if (userId === currentUserId) {
        selfUpdates.push(update)
      }
    }
  }

  return { selfUpdates }
}

function buildChatMetadataUpdate(input: { chat: Chat; update: UpdateSeqAndDate }): Update {
  return {
    seq: input.update.seq,
    date: encodeDateStrict(input.update.date),
    update: {
      oneofKind: "newChat",
      newChat: {
        chat: input.chat,
      },
    },
  }
}
