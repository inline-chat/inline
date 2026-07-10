import type { GetUpdatesInput, GetUpdatesResult, InputPeer, Peer } from "@inline-chat/protocol/core"
import { GetUpdatesResult_ResultType } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { UpdateBoxInput } from "@in/server/db/models/updates"
import type { DbChat } from "@in/server/db/schema"
import { UpdateBucket as DbUpdateBucket } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { CORE_SYNC_SCHEMA_REVISION, Sync } from "@in/server/modules/updates/sync"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { ModelError } from "@in/server/db/models/_errors"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getSpacePrivacyContext } from "@in/server/modules/privacy/spacePrivacy"
import { Log } from "@in/server/utils/log"

const MAX_TOTAL_LIMIT = 1000
const log = new Log("updates.getUpdates")

type CompatibleGetUpdatesInput = Omit<GetUpdatesInput, "coreSyncSchemaRevision"> &
  Partial<Pick<GetUpdatesInput, "coreSyncSchemaRevision">>

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

export const getUpdates = async (input: CompatibleGetUpdatesInput, context: FunctionContext): Promise<GetUpdatesResult> => {
  const startedAt = performance.now()
  const resolveStartedAt = performance.now()
  const descriptor = await resolveBucket(input.bucket, context)
  const resolveMs = elapsedMs(resolveStartedAt)

  const clientSchemaRevision = input.coreSyncSchemaRevision ?? 0
  if (clientSchemaRevision !== 0 && clientSchemaRevision !== CORE_SYNC_SCHEMA_REVISION) {
    throw RealtimeRpcError.SyncSchemaIncompatible(clientSchemaRevision, CORE_SYNC_SCHEMA_REVISION)
  }

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
      skippedSequences: [],
      coreSyncSchemaRevision: CORE_SYNC_SCHEMA_REVISION,
    }
  }

  let inflatedUpdates: GetUpdatesResult["updates"] = []
  let skippedSequences: GetUpdatesResult["skippedSequences"] = []
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
      const page = Sync.inflateSpaceUpdatesPage(dbUpdates, { sanitizeUsers: descriptor.sanitizeUsers })
      inflatedUpdates = page.updates
      skippedSequences = page.skippedSequences
      break
    }

    case "user": {
      const page = Sync.inflateUserUpdatesPage(dbUpdates)
      inflatedUpdates = page.updates
      skippedSequences = page.skippedSequences
      break
    }
  }
  const inflateMs = elapsedMs(inflateStartedAt)

  const updates = inflatedUpdates
  if (clientSchemaRevision === 0 && updates.some(requiresCoreSyncSchemaRevision)) {
    throw RealtimeRpcError.SyncSchemaIncompatible(clientSchemaRevision, CORE_SYNC_SCHEMA_REVISION)
  }
  assertPageSequenceAccounting(dbUpdates, updates, skippedSequences)
  const final = latestSeq <= pageSeq
  const sidecarsStartedAt = performance.now()
  const sidecars =
    descriptor.scope === "chat"
      ? await Sync.buildChatSidecarsForUpdates({
          chatId: descriptor.chatId,
          updates,
          userId: context.currentUserId,
        })
      : descriptor.scope === "user"
        ? await Sync.buildUserSidecarsForUpdates({
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
    skippedSequences,
    coreSyncSchemaRevision: CORE_SYNC_SCHEMA_REVISION,
  }
}

const requiresCoreSyncSchemaRevision = (update: GetUpdatesResult["updates"][number]): boolean => {
  switch (update.update.oneofKind) {
    case "participantGroupAdd":
    case "participantGroupDelete":
    case "spaceSettings":
      return true
    case "newMessage":
    case "editMessage":
    case "updateMessageId":
    case "deleteMessages":
    case "updateComposeAction":
    case "updateUserStatus":
    case "messageAttachment":
    case "updateReaction":
    case "deleteReaction":
    case "participantAdd":
    case "participantDelete":
    case "newChat":
    case "deleteChat":
    case "spaceMemberAdd":
    case "spaceMemberDelete":
    case "joinSpace":
    case "updateReadMaxId":
    case "updateUserSettings":
    case "newMessageNotification":
    case "markAsUnread":
    case "chatSkipPts":
    case "chatHasNewUpdates":
    case "spaceHasNewUpdates":
    case "spaceMemberUpdate":
    case "chatVisibility":
    case "dialogArchived":
    case "chatInfo":
    case "pinnedMessages":
    case "chatMoved":
    case "dialogNotificationSettings":
    case "chatOpen":
    case "messageActionInvoked":
    case "messageActionAnswered":
    case "clearChatHistory":
    case "botPresence":
    case "dialogFollowMode":
    case "updatedUser":
    case "botChatSettingsRequested":
    case "botChatSettingsResolved":
    case "botChatSettingsItemInvoked":
    case "botChatSettingsItemAnswered":
      return false
    case undefined:
      throw new Error("Inflated lossless sync update has no payload")
    default:
      return assertNever(update.update)
  }
}

const assertNever = (value: never): never => {
  throw new Error(`Unhandled lossless sync update: ${JSON.stringify(value)}`)
}

const assertPageSequenceAccounting = (
  dbUpdates: Awaited<ReturnType<typeof Sync.getUpdates>>["updates"],
  updates: GetUpdatesResult["updates"],
  skippedSequences: GetUpdatesResult["skippedSequences"],
): void => {
  const accounted = new Set<number>()
  for (const update of updates) {
    const seq = Number(update.seq ?? 0)
    if (!Number.isSafeInteger(seq) || seq <= 0 || accounted.has(seq)) {
      throw new Error(`Invalid or duplicate delivered sync sequence: ${seq}`)
    }
    accounted.add(seq)
  }
  for (const skipped of skippedSequences) {
    const seq = Number(skipped.seq)
    if (!Number.isSafeInteger(seq) || seq <= 0 || accounted.has(seq)) {
      throw new Error(`Invalid or duplicate skipped sync sequence: ${seq}`)
    }
    accounted.add(seq)
  }
  for (const update of dbUpdates) {
    if (!accounted.has(update.seq)) {
      throw new Error(`Unclassified lossless sync sequence: ${update.seq}`)
    }
  }
  if (accounted.size !== dbUpdates.length) {
    throw new Error("Sync page accounting contains a sequence outside the database page")
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
    sidecars.spaces.length > 0 ||
    sidecars.userGroups.length > 0
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
