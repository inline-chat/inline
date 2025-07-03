import type { GetUpdatesStateInput } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { DbChat } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { decodeDate, encodeDate, encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"

type GetUpdatesStateFnResult = {
  userPts: number
  date: bigint
}

export const getUpdatesState = async (
  input: GetUpdatesStateInput,
  context: FunctionContext,
): Promise<GetUpdatesStateFnResult> => {
  let userLocalDate = decodeDate(input.date)

  // return latest state
  let newDate = new Date()
  let newTimetamp = encodeDateStrict(newDate)

  // check latest changes of chats from this user's dialogs for changes compared to date
  // get a list of dialogs for this user
  let { chats } = await ChatModel.getUserChats({
    userId: context.currentUserId,
    where: {
      lastUpdateAtGreaterThanEqual: userLocalDate,
    },
  })

  // Publish updates
  for (let chat of chats) {
    RealtimeUpdates.pushToUser(context.currentUserId, [
      {
        update: {
          oneofKind: "chatHasNewUpdates",
          chatHasNewUpdates: {
            chatId: BigInt(chat.id),
            // PTS should not be null here
            pts: chat.pts ?? 0,
          },
        },
      },
    ])
  }

  return {
    date: newTimetamp,

    // TODO: fetch latest PTS for the user
    userPts: 0,
  }
}
