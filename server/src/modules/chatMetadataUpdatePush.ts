import type { InputPeer, Update } from "@inline-chat/protocol/core"
import type { DbChat } from "@in/server/db/schema"
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

    updateGroup.userIds.forEach((userId) => {
      const update = buildChatMetadataUpdate({
        chat: chatUpdate.chat,
        update: chatUpdate.update,
        userId,
      })

      RealtimeUpdates.pushToUser(userId, [update])
      if (userId === currentUserId) {
        selfUpdates.push(update)
      }
    })
  }

  return { selfUpdates }
}

function buildChatMetadataUpdate(input: { chat: DbChat; update: UpdateSeqAndDate; userId: number }): Update {
  return {
    seq: input.update.seq,
    date: encodeDateStrict(input.update.date),
    update: {
      oneofKind: "newChat",
      newChat: {
        chat: Encoders.chat(input.chat, { encodingForUserId: input.userId }),
      },
    },
  }
}
