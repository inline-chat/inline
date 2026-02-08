import type { GetUpdatesStateInput } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Encoders } from "@in/server/realtime/encoders/encoders"
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
  const nowEncoded = encodeDateStrict(new Date())

  // Safeguard: If client sends 0 (uninitialized), just return current date
  // to avoid pushing all updates ever.
  if (input.date === 0n) {
    return {
      date: nowEncoded,
    }
  }

  let userLocalDate = decodeDate(input.date)

  // check latest changes of chats from this user's dialogs for changes compared to date
  // get a list of dialogs for this user
  let { chats } = await ChatModel.getUserChats({
    userId: context.currentUserId,
    where: {
      lastUpdateAtGreaterThanEqual: userLocalDate,
    },
  })

  // Get spaces that have been updated
  let spaces = await SpaceModel.getSpacesAfterUpdateDate({
    userId: context.currentUserId,
    lastUpdateDateGreaterThanEqual: userLocalDate,
  })

  // Find latest update date for chats
  let latestChatUpdateTs = chats.reduce((max, chat) => {
    return Math.max(max, chat.lastUpdateDate?.getTime() ?? 0)
  }, 0)

  // Find latest update date for spaces
  let latestSpaceUpdateTs = spaces.reduce((max, space) => {
    return Math.max(max, space.lastUpdateDate?.getTime() ?? 0)
  }, 0)

  let latestUpdateTs = Math.max(latestChatUpdateTs, latestSpaceUpdateTs)
  // If there are no updates, advance the cursor to (at least) "now" to avoid
  // repeatedly re-scanning from an old date on every reconnect.
  if (latestUpdateTs === 0) {
    return {
      date: nowEncoded > input.date ? nowEncoded : input.date,
    }
  }
  let latestUpdateDate = new Date(latestUpdateTs)
  let latestUpdateDateEncoded = encodeDateStrict(latestUpdateDate)

  const updatesToPush: Parameters<typeof RealtimeUpdates.pushToUser>[1] = []

  // Publish updates for chats
  for (let chat of chats) {
    if (!chat.lastUpdateDate) {
      continue
    }

    updatesToPush.push({
      update: {
        oneofKind: "chatHasNewUpdates",
        chatHasNewUpdates: {
          chatId: BigInt(chat.id),
          // PTS should not be null here
          updateSeq: chat.updateSeq ?? 0,
          peerId: Encoders.peerFromChat(chat, {
            currentUserId: context.currentUserId,
          }),
        },
      },
    })
  }

  // Publish updates for spaces
  for (let space of spaces) {
    if (!space.lastUpdateDate) {
      continue
    }
    if (typeof space.updateSeq !== "number") {
      continue
    }
    updatesToPush.push({
      update: {
        oneofKind: "spaceHasNewUpdates",
        spaceHasNewUpdates: {
          spaceId: BigInt(space.id),
          updateSeq: space.updateSeq,
        },
      },
    })
  }

  if (updatesToPush.length > 0) {
    RealtimeUpdates.pushToUser(context.currentUserId, updatesToPush)
  }

  return {
    date: latestUpdateDateEncoded,
  }
}
