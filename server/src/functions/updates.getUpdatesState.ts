import type { GetUpdatesStateInput, GetUpdatesStateResult } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { DbChat } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { decodeDate, encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"

const log = new Log("updates.getUpdatesState")
const INITIAL_STATE_LOOKBACK_MS = 5 * 24 * 60 * 60 * 1000

export const getUpdatesState = async (
  input: GetUpdatesStateInput,
  context: FunctionContext,
): Promise<GetUpdatesStateResult> => {
  const startedAt = performance.now()
  const nowEncoded = encodeDateStrict(new Date())

  // If client sends 0 (uninitialized), scan a bounded recent window instead of
  // returning "now". Unknown local state should trigger repair hints, but not an
  // unbounded all-history scan.
  let userLocalDate = input.date === 0n
    ? new Date(Date.now() - INITIAL_STATE_LOOKBACK_MS)
    : decodeDate(input.date)

  // check latest changes of chats from this user's dialogs for changes compared to date
  // get a list of dialogs for this user
  const chatsStartedAt = performance.now()
  let { chats } = await ChatModel.getUserChats({
    userId: context.currentUserId,
    where: {
      lastUpdateAtGreaterThanEqual: userLocalDate,
    },
  })
  chats = await filterAccessibleChats(chats, context.currentUserId)
  const chatsMs = elapsedMs(chatsStartedAt)

  // Get spaces that have been updated
  const spacesStartedAt = performance.now()
  let spaces = await SpaceModel.getSpacesAfterUpdateDate({
    userId: context.currentUserId,
    lastUpdateDateGreaterThanEqual: userLocalDate,
  })
  const spacesMs = elapsedMs(spacesStartedAt)

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
    logGetUpdatesStateTiming({
      result: "empty",
      totalMs: elapsedMs(startedAt),
      chatsMs,
      spacesMs,
      chats: chats.length,
      spaces: spaces.length,
      pushed: 0,
    })
    return {
      date: nowEncoded > input.date ? nowEncoded : input.date,
      updatesFound: false,
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

  logGetUpdatesStateTiming({
    result: "updates",
    totalMs: elapsedMs(startedAt),
    chatsMs,
    spacesMs,
    chats: chats.length,
    spaces: spaces.length,
    pushed: updatesToPush.length,
  })

  return {
    date: latestUpdateDateEncoded,
    updatesFound: true,
  }
}

type GetUpdatesStateTiming = {
  result: "empty" | "updates"
  totalMs: number
  chatsMs?: number
  spacesMs?: number
  chats: number
  spaces: number
  pushed: number
}

const elapsedMs = (startedAt: number): number =>
  Math.round((performance.now() - startedAt) * 10) / 10

const logGetUpdatesStateTiming = (timing: GetUpdatesStateTiming): void => {
  const message = "getUpdatesState timing"
  if (timing.totalMs >= 500) {
    log.warn(message, timing)
  } else {
    log.debug(message, timing)
  }
}

const filterAccessibleChats = async (chats: DbChat[], userId: number): Promise<DbChat[]> => {
  const accessible: DbChat[] = []

  for (const chat of chats) {
    try {
      await AccessGuards.ensureChatAccess(chat, userId)
      accessible.push(chat)
    } catch (error) {
      if (isExpectedAccessError(error)) {
        continue
      }
      throw error
    }
  }

  return accessible
}

const isExpectedAccessError = (error: unknown): boolean =>
  RealtimeRpcError.is(error, RealtimeRpcError.Code.PEER_ID_INVALID) ||
  RealtimeRpcError.is(error, RealtimeRpcError.Code.SPACE_ID_INVALID)
