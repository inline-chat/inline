import {
  UpdatesPayload,
  type GetUpdatesStateInput,
  type GetUpdatesStateResult,
} from "@inline-chat/protocol/core"
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
import { UsersModel } from "@in/server/db/models/users"
import { db } from "@in/server/db"
import { UpdateBucket } from "@in/server/db/schema"

const log = new Log("updates.getUpdatesState")
const MAX_UPDATE_HINTS_PER_BATCH = 512
const MAX_UPDATE_HINT_BATCH_BYTES = 1024 * 1024
const MAX_CONCURRENT_CHAT_ACCESS_CHECKS = 16

export const getUpdatesState = async (
  input: GetUpdatesStateInput,
  context: FunctionContext,
): Promise<GetUpdatesStateResult> => {
  const startedAt = performance.now()
  if (input.date !== undefined && input.date <= 0n) {
    throw RealtimeRpcError.BadRequest()
  }

  const user = await UsersModel.getUserById(context.currentUserId)
  if (!user) {
    throw RealtimeRpcError.InternalError()
  }
  const latestUserUpdate = await db.query.updates.findFirst({
    columns: {
      seq: true,
    },
    where: {
      bucket: UpdateBucket.User,
      entityId: context.currentUserId,
    },
    orderBy: {
      seq: "desc",
    },
  })
  const userSeq = Math.max(user.updateSeq ?? 0, latestUserUpdate?.seq ?? 0)
  const nowEncoded = encodeDateStrict(new Date())

  // An absent date requests a fresh checkpoint. Snapshot RPCs seed the resource
  // buckets independently, so bootstrap must not discover or replay old work.
  if (input.date === undefined) {
    logGetUpdatesStateTiming({
      result: "checkpoint",
      totalMs: elapsedMs(startedAt),
      chats: 0,
      spaces: 0,
      pushed: 0,
    })
    return {
      date: nowEncoded,
      updatesFound: false,
      seq: userSeq,
    }
  }

  const userLocalDate = decodeDate(input.date)

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
      seq: userSeq,
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
    updatesToPush.push({
      update: {
        oneofKind: "spaceHasNewUpdates",
        spaceHasNewUpdates: {
          spaceId: BigInt(space.id),
          // Zero is the existing "fetch authoritatively" sentinel. A changed
          // bucket must never disappear merely because its cached counter is
          // temporarily absent or being repaired.
          updateSeq: space.updateSeq ?? 0,
        },
      },
    })
  }

  if (updatesToPush.length > 0) {
    pushBoundedUpdateHints(context.currentUserId, updatesToPush)
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
    seq: userSeq,
  }
}

const pushBoundedUpdateHints = (
  userId: number,
  updates: Parameters<typeof RealtimeUpdates.pushToUser>[1],
): void => {
  let offset = 0
  while (offset < updates.length) {
    let batch = updates.slice(offset, offset + MAX_UPDATE_HINTS_PER_BATCH)
    let encodedBytes = UpdatesPayload.toBinary({ updates: batch }).length
    while (encodedBytes > MAX_UPDATE_HINT_BATCH_BYTES && batch.length > 1) {
      batch = batch.slice(0, Math.ceil(batch.length / 2))
      encodedBytes = UpdatesPayload.toBinary({ updates: batch }).length
    }
    if (encodedBytes > MAX_UPDATE_HINT_BATCH_BYTES) {
      throw new RangeError("Realtime update hint exceeds the bounded batch size")
    }
    RealtimeUpdates.pushToUser(userId, batch)
    offset += batch.length
  }
}

type GetUpdatesStateTiming = {
  result: "checkpoint" | "empty" | "updates"
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
  const accessible = Array.from<DbChat | undefined>({ length: chats.length })
  let nextIndex = 0
  const workerCount = Math.min(chats.length, MAX_CONCURRENT_CHAT_ACCESS_CHECKS)

  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (nextIndex < chats.length) {
      const index = nextIndex
      nextIndex += 1
      const chat = chats[index]
      if (!chat) continue
      try {
        await AccessGuards.ensureChatAccess(chat, userId)
        accessible[index] = chat
      } catch (error) {
        if (isExpectedAccessError(error)) {
          continue
        }
        throw error
      }
    }
  }))

  return accessible.filter((chat): chat is DbChat => chat !== undefined)
}

const isExpectedAccessError = (error: unknown): boolean =>
  RealtimeRpcError.is(error, RealtimeRpcError.Code.PEER_ID_INVALID) ||
  RealtimeRpcError.is(error, RealtimeRpcError.Code.SPACE_ID_INVALID)
