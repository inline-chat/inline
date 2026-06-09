import type { GetUpdatesInput, GetUpdatesResult, InputPeer, Peer } from "@inline-chat/protocol/core"
import { GetUpdatesResult_ResultType } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { UpdateBoxInput } from "@in/server/db/models/updates"
import type { DbChat } from "@in/server/db/schema"
import { UpdateBucket as DbUpdateBucket } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { Sync } from "@in/server/modules/updates/sync"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { ModelError } from "@in/server/db/models/_errors"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getSpacePrivacyContext } from "@in/server/modules/privacy/spacePrivacy"
import { Log } from "@in/server/utils/log"

const MAX_TOTAL_LIMIT = 1000
const log = new Log("updates.getUpdates")

type BucketDescriptor =
  | {
      scope: "user"
      box: UpdateBoxInput
    }
  | {
      scope: "space"
      spaceId: number
      sanitizeUsers: boolean
      box: UpdateBoxInput
    }
  | {
      scope: "chat"
      chatId: number
      peer: Peer
      box: UpdateBoxInput
    }

export const getUpdates = async (input: GetUpdatesInput, context: FunctionContext): Promise<GetUpdatesResult> => {
  const startedAt = performance.now()
  const resolveStartedAt = performance.now()
  const descriptor = await resolveBucket(input.bucket, context)
  const resolveMs = elapsedMs(resolveStartedAt)

  const seqStartBigInt = input.startSeq ?? 0n
  if (seqStartBigInt < 0n) {
    throw RealtimeRpcError.BadRequest()
  }

  const seqStart = Number(seqStartBigInt)
  if (!Number.isSafeInteger(seqStart)) {
    throw RealtimeRpcError.BadRequest()
  }

  let seqEnd: number | undefined
  // proto3 scalar defaults to 0 when omitted; treat 0 as unset.
  const seqEndBigInt = input.seqEnd ?? 0n
  if (seqEndBigInt !== 0n) {
    if (seqEndBigInt < 0n) {
      throw RealtimeRpcError.BadRequest()
    }
    const seqEndNumber = Number(seqEndBigInt)
    if (!Number.isSafeInteger(seqEndNumber)) {
      throw RealtimeRpcError.BadRequest()
    }
    if (seqEndNumber < seqStart) {
      throw RealtimeRpcError.BadRequest()
    }
    seqEnd = seqEndNumber
  }

  const requestedLimit =
    input.totalLimit !== undefined && input.totalLimit > 0 ? Number(input.totalLimit) : MAX_TOTAL_LIMIT
  const totalLimit = Math.min(requestedLimit, MAX_TOTAL_LIMIT)
  const requestedPageLimit = input.limit !== undefined && input.limit > 0 ? Number(input.limit) : totalLimit
  const pageLimit = Math.min(requestedPageLimit, totalLimit)

  const fetchTiming = await timed(async () =>
    Sync.getUpdates({
      bucket: descriptor.box,
      seqStart,
      seqEnd,
      limit: pageLimit,
    })
  )
  const {
    updates: dbUpdates,
    latestSeq,
    latestDate,
  } = fetchTiming.value
  const fetchMs = fetchTiming.ms

  let pageSeq = latestSeq
  let pageDate = latestDate
  if (dbUpdates.length > 0) {
    const lastRecord = dbUpdates[dbUpdates.length - 1]!
    pageSeq = lastRecord.seq
    pageDate = lastRecord.date
  }

  const seqDifference = latestSeq - seqStart
  if (seqDifference > totalLimit) {
    logGetUpdatesTiming({
      scope: descriptor.scope,
      result: "too_long",
      totalMs: elapsedMs(startedAt),
      resolveMs,
      fetchMs,
      inflateMs: 0,
      sidecarsMs: 0,
      dbUpdates: dbUpdates.length,
      updates: 0,
      pageLimit,
      totalLimit,
      seqDifference,
    })
    return {
      updates: [],
      seq: BigInt(latestSeq),
      date: encodeOptionalDate(latestDate),
      final: false,
      resultType: GetUpdatesResult_ResultType.TOO_LONG,
    }
  }

  let inflatedUpdates: GetUpdatesResult["updates"] = []
  const inflateStartedAt = performance.now()

  switch (descriptor.scope) {
    case "chat": {
      const result = await Sync.processChatUpdates({
        chatId: descriptor.chatId,
        peerId: descriptor.peer,
        updates: dbUpdates,
        userId: context.currentUserId,
      })
      inflatedUpdates = result.updates
      break
    }

    case "space": {
      inflatedUpdates = Sync.inflateSpaceUpdates(dbUpdates, { sanitizeUsers: descriptor.sanitizeUsers })
      break
    }

    case "user": {
      inflatedUpdates = Sync.inflateUserUpdates(dbUpdates)
      break
    }
  }
  const inflateMs = elapsedMs(inflateStartedAt)

  // The server is authoritative for the bucket cursor. Deliver every update we
  // can inflate for this page, but advance the response cursor to the page
  // boundary even if some records were filtered or could not be represented.
  const updates = inflatedUpdates
  const filteredCount = dbUpdates.length - updates.length
  if (filteredCount > 0) {
    log.warn("getUpdates trusting page cursor after filtering updates", {
      scope: descriptor.scope,
      filtered: filteredCount,
      dbUpdates: dbUpdates.length,
      delivered: updates.length,
      startSeq: seqStart,
      pageSeq,
      latestSeq,
    })
  }
  const final = latestSeq <= pageSeq
  const sidecarsStartedAt = performance.now()
  const sidecars = descriptor.scope === "chat"
    ? await Sync.buildChatSidecarsForUpdates({
        chatId: descriptor.chatId,
        updates,
        userId: context.currentUserId,
      })
    : undefined
  const sidecarsMs = elapsedMs(sidecarsStartedAt)

  let resultType = updates.length === 0 ? GetUpdatesResult_ResultType.EMPTY : GetUpdatesResult_ResultType.SLICE

  logGetUpdatesTiming({
    scope: descriptor.scope,
    result: updates.length === 0 ? "empty" : "slice",
    totalMs: elapsedMs(startedAt),
    resolveMs,
    fetchMs,
    inflateMs,
    sidecarsMs,
    dbUpdates: dbUpdates.length,
    updates: updates.length,
    pageLimit,
    totalLimit,
    seqDifference,
  })

  return {
    updates,
    seq: BigInt(pageSeq),
    date: encodeOptionalDate(pageDate),
    final,
    resultType,
    sidecars: updates.length > 0 && hasSidecars(sidecars) ? sidecars : undefined,
  }
}

const elapsedMs = (startedAt: number): number =>
  Math.round((performance.now() - startedAt) * 10) / 10

const timed = async <T>(fn: () => Promise<T>): Promise<{ value: T; ms: number }> => {
  const startedAt = performance.now()
  const value = await fn()
  return {
    value,
    ms: elapsedMs(startedAt),
  }
}

type GetUpdatesTiming = {
  scope: BucketDescriptor["scope"]
  result: "too_long" | "empty" | "slice"
  totalMs: number
  resolveMs: number
  fetchMs: number
  inflateMs: number
  sidecarsMs: number
  dbUpdates: number
  updates: number
  pageLimit: number
  totalLimit: number
  seqDifference: number
}

const logGetUpdatesTiming = (timing: GetUpdatesTiming): void => {
  const message = "getUpdates timing"
  if (timing.totalMs >= 500) {
    log.warn(message, timing)
  } else {
    log.debug(message, timing)
  }
}

const encodeOptionalDate = (date: Date | null | undefined): bigint => {
  if (!date) {
    return 0n
  }
  return encodeDateStrict(date)
}

const hasSidecars = (sidecars: GetUpdatesResult["sidecars"]): boolean => {
  if (!sidecars) {
    return false
  }

  return (
    sidecars.users.length > 0 ||
    sidecars.chats.length > 0 ||
    sidecars.dialogs.length > 0 ||
    sidecars.spaces.length > 0
  )
}

const resolveBucket = async (
  bucket: GetUpdatesInput["bucket"],
  context: FunctionContext,
): Promise<BucketDescriptor> => {
  if (!bucket || bucket.type.oneofKind === undefined) {
    throw RealtimeRpcError.BadRequest()
  }

  switch (bucket.type.oneofKind) {
    case "user": {
      return {
        scope: "user",
        box: {
          type: DbUpdateBucket.User,
          userId: context.currentUserId,
        },
      }
    }

    case "space": {
      const spaceId = Number(bucket.type.space.spaceId)
      if (!Number.isSafeInteger(spaceId) || spaceId <= 0) {
        throw RealtimeRpcError.SpaceIdInvalid()
      }

      const privacy = await getSpacePrivacyContext(spaceId, context.currentUserId)

      return {
        scope: "space",
        spaceId,
        sanitizeUsers: privacy.isPublicSpace && !privacy.canManageMembers,
        box: {
          type: DbUpdateBucket.Space,
          spaceId,
        },
      }
    }

    case "chat": {
      const inputPeer = bucket.type.chat.peerId
      if (!inputPeer) {
        throw RealtimeRpcError.PeerIdInvalid()
      }

      const chat = await getChatOrThrow(inputPeer, context)
      await AccessGuards.ensureChatAccess(chat, context.currentUserId)

      const peer = Encoders.peerFromInputPeer({
        inputPeer,
        currentUserId: context.currentUserId,
      })

      return {
        scope: "chat",
        chatId: chat.id,
        peer,
        box: {
          type: DbUpdateBucket.Chat,
          chatId: chat.id,
        },
      }
    }
  }
}

const getChatOrThrow = async (inputPeer: InputPeer, context: FunctionContext): Promise<DbChat> => {
  try {
    return await ChatModel.getChatFromInputPeer(inputPeer, {
      currentUserId: context.currentUserId,
    })
  } catch (error) {
    if (
      error === ModelError.ChatInvalid ||
      (error instanceof ModelError && error.code === ModelError.Codes.CHAT_INVALID)
    ) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    throw error
  }
}
