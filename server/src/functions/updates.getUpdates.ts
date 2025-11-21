import type { GetUpdatesInput, GetUpdatesResult, InputPeer, Peer } from "@in/protocol/core"
import { GetUpdatesResult_ResultType } from "@in/protocol/core"
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

const MAX_UPDATES_PER_REQUEST = 50
const DEFAULT_TOTAL_LIMIT = 1000

type BucketDescriptor =
  | {
      scope: "user"
      box: UpdateBoxInput
    }
  | {
      scope: "space"
      spaceId: number
      box: UpdateBoxInput
    }
  | {
      scope: "chat"
      chatId: number
      peer: Peer
      box: UpdateBoxInput
    }

export const getUpdates = async (input: GetUpdatesInput, context: FunctionContext): Promise<GetUpdatesResult> => {
  const descriptor = await resolveBucket(input.bucket, context)

  const seqStartBigInt = input.startSeq ?? 0n
  if (seqStartBigInt < 0n) {
    throw RealtimeRpcError.BadRequest
  }

  const seqStart = Number(seqStartBigInt)
  if (!Number.isSafeInteger(seqStart)) {
    throw RealtimeRpcError.BadRequest
  }

  const totalLimit =
    input.totalLimit !== undefined && input.totalLimit > 0 ? Number(input.totalLimit) : DEFAULT_TOTAL_LIMIT

  const {
    updates: dbUpdates,
    latestSeq,
    latestDate,
  } = await Sync.getUpdates({
    bucket: descriptor.box,
    seqStart,
    limit: MAX_UPDATES_PER_REQUEST,
  })

  let sliceSeq = seqStart
  let sliceDate = latestDate
  if (dbUpdates.length > 0) {
    const lastRecord = dbUpdates[dbUpdates.length - 1]!
    sliceSeq = lastRecord.seq
    sliceDate = lastRecord.date
  }

  const seqDifference = latestSeq - seqStart
  if (seqDifference > totalLimit) {
    return {
      updates: [],
      seq: BigInt(latestSeq),
      date: encodeOptionalDate(latestDate),
      final: false,
      resultType: GetUpdatesResult_ResultType.TOO_LONG,
    }
  }

  let updates: GetUpdatesResult["updates"] = []

  switch (descriptor.scope) {
    case "chat": {
      const result = await Sync.processChatUpdates({
        chatId: descriptor.chatId,
        peerId: descriptor.peer,
        updates: dbUpdates,
        userId: context.currentUserId,
      })
      updates = result.updates
      break
    }

    case "space": {
      updates = Sync.inflateSpaceUpdates(dbUpdates)
      break
    }

    case "user": {
      updates = Sync.inflateUserUpdates(dbUpdates)
      break
    }
  }

  let deliveredSeqNumber = seqStart
  let deliveredDate = sliceDate
  if (updates.length > 0) {
    const lastDelivered = updates[updates.length - 1]
    deliveredSeqNumber = Number(lastDelivered?.seq ?? seqStart)
    deliveredDate = findDateForSeq(dbUpdates, deliveredSeqNumber) ?? sliceDate
  }
  const final = latestSeq <= deliveredSeqNumber

  let resultType = updates.length === 0 ? GetUpdatesResult_ResultType.EMPTY : GetUpdatesResult_ResultType.SLICE

  return {
    updates,
    seq: BigInt(deliveredSeqNumber),
    date: encodeOptionalDate(deliveredDate),
    final,
    resultType,
  }
}

const encodeOptionalDate = (date: Date | null | undefined): bigint => {
  if (!date) {
    return 0n
  }
  return encodeDateStrict(date)
}

const findDateForSeq = (dbUpdates: { seq: number; date: Date }[], seq: number): Date | null => {
  for (let i = dbUpdates.length - 1; i >= 0; i -= 1) {
    const record = dbUpdates[i]!
    if (record.seq === seq) {
      return record.date
    }
  }
  return null
}

const resolveBucket = async (
  bucket: GetUpdatesInput["bucket"],
  context: FunctionContext,
): Promise<BucketDescriptor> => {
  if (!bucket || bucket.type.oneofKind === undefined) {
    throw RealtimeRpcError.BadRequest
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
        throw RealtimeRpcError.SpaceIdInvalid
      }

      await AccessGuards.ensureSpaceMember(spaceId, context.currentUserId)

      return {
        scope: "space",
        spaceId,
        box: {
          type: DbUpdateBucket.Space,
          spaceId,
        },
      }
    }

    case "chat": {
      const inputPeer = bucket.type.chat.peerId
      if (!inputPeer) {
        throw RealtimeRpcError.PeerIdInvalid
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
      throw RealtimeRpcError.PeerIdInvalid
    }
    throw error
  }
}
