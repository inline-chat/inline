import type { GetUpdatesStateInput } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { DbChat } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { decodeDate, encodeDate, encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"

type GetUpdatesStateFnResult = {
  date: bigint
}

export const getUpdatesState = async (
  input: GetUpdatesStateInput,
  context: FunctionContext,
): Promise<GetUpdatesStateFnResult> => {
  let userLocalDate = decodeDate(input.date)

  // check latest changes of chats from this user's dialogs for changes compared to date
  // get a list of dialogs for this user
  let { chats } = await ChatModel.getUserChats({
    userId: context.currentUserId,
    where: {
      lastUpdateAtGreaterThanEqual: userLocalDate,
    },
  })

  // Find latest update date for chats
  let latestChatUpdateTs = chats.reduce((max, chat) => {
    return Math.max(max, chat.lastUpdateDate?.getTime() ?? 0)
  }, 0)
  let latestChatUpdateDate = new Date(latestChatUpdateTs)
  let latestChatUpdateDateEncoded = encodeDateStrict(latestChatUpdateDate)

  // Find latest update date for spaces
  // let latestSpaceUpdateDate = spaces.reduce((max, space) => {
  //   return Math.max(max, space.lastUpdateDate?.getTime() ?? 0)
  // }, 0)

  // Publish updates
  for (let chat of chats) {
    if (!chat.lastUpdateDate) {
      continue
    }
    RealtimeUpdates.pushToUser(context.currentUserId, [
      {
        update: {
          oneofKind: "chatHasNewUpdates",
          chatHasNewUpdates: {
            chatId: BigInt(chat.id),
            // PTS should not be null here
            updateSeq: chat.updateSeq ?? 0,
          },
        },
      },
    ])
  }

  return {
    date: latestChatUpdateDateEncoded,
  }
}
