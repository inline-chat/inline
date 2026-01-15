import type { Message, Peer, Update } from "@in/protocol/core"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { UpdatesModel, type UpdateBoxInput, type DecryptedUpdate } from "@in/server/db/models/updates"
import { UpdateBucket, type DbUpdate } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log, LogLevel } from "@in/server/utils/log"

const log = new Log("Sync", LogLevel.TRACE)

export const Sync = {
  getUpdates: getUpdates,
  processChatUpdates: processChatUpdates,
  inflateSpaceUpdates: inflateSpaceUpdates,
  inflateUserUpdates: inflateUserUpdates,
}

type GetUpdatesInput = {
  /** box to get updates from */
  bucket: UpdateBoxInput

  /** pts to start from (exclusive) */
  seqStart: number

  /** optional inclusive upper bound for slicing */
  seqEnd?: number

  /** limit of updates to get */
  limit: number
}

type GetUpdatesOutput = {
  updates: DbUpdate[]
  latestSeq: number
  latestDate: Date | null
}

// Get a list of updates from the database
async function getUpdates(input: GetUpdatesInput): Promise<GetUpdatesOutput> {
  const { bucket, seqStart, seqEnd } = input
  const entityId = getEntityId(bucket)

  const seqFilter = seqEnd !== undefined ? { gt: seqStart, lte: seqEnd } : { gt: seqStart }

  const list = await db.query.updates.findMany({
    where: {
      bucket: bucket.type,
      entityId,
      seq: seqFilter,
    },
    orderBy: {
      seq: "asc",
    },
    limit: input.limit,
  })

  const latestWhere = seqEnd !== undefined
    ? { bucket: bucket.type, entityId, seq: { lte: seqEnd } }
    : { bucket: bucket.type, entityId }

  const latest = await db.query.updates.findFirst({
    where: latestWhere,
    orderBy: {
      seq: "desc",
    },
  })

  return {
    updates: list,
    latestSeq: latest?.seq ?? seqStart,
    latestDate: latest?.date ?? null,
  }
}

const getEntityId = (bucket: UpdateBoxInput): number => {
  switch (bucket.type) {
    case UpdateBucket.Chat:
      return bucket.chatId
    case UpdateBucket.Space:
      return bucket.spaceId
    case UpdateBucket.User:
      return bucket.userId
    default:
      return -1
  }
}

type ProcessChatUpdatesInput = {
  /** Chat ID to process updates for */
  chatId: number

  /** Peer ID of the chat for the user to process updates for */
  peerId: Peer

  /** Database updates to process */
  updates: DbUpdate[]

  /** User ID to process updates for */
  userId: number
}

type ProcessChatUpdatesOutput = {
  /** Processed updates for one user */
  updates: Update[]
}

/**
 * Decrypt, fetch attached nodes, decrypt, encode to updates.
 */
async function processChatUpdates(input: ProcessChatUpdatesInput): Promise<ProcessChatUpdatesOutput> {
  const { chatId, updates, userId, peerId } = input

  // Decrypt
  const decryptedUpdates = updates.map((dbUpdate) => UpdatesModel.decrypt(dbUpdate))

  // Find attached nodes (later we'll support for types)
  let messageIds: Set<bigint> = new Set()

  // Loop through updates to find message ids we need to fetch
  for (const update of decryptedUpdates) {
    let serverUpdate = update.payload.update
    if (serverUpdate.oneofKind === "newMessage") {
      messageIds.add(serverUpdate.newMessage.msgId)
    } else if (serverUpdate.oneofKind === "editMessage") {
      messageIds.add(serverUpdate.editMessage.msgId)
    }
  }

  // Fetch from db
  const dbMessages = await MessageModel.getMessagesByIds(chatId, Array.from(messageIds))

  // Store encoded messages in a map
  const msgs = new Map<bigint, Message>()
  for (const message of dbMessages) {
    const encoded = Encoders.fullMessage({
      message,
      encodingForUserId: userId,
      encodingForPeer: { peer: peerId },
    })
    msgs.set(encoded.id, encoded)
  }

  // Encode updates
  const inflatedUpdates: Update[] = decryptedUpdates.map((update): Update => {
    const serverUpdate = update.payload

    switch (serverUpdate.update.oneofKind) {
      case "newMessage":
        return {
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "newMessage",
            newMessage: {
              message: msgs.get(serverUpdate.update.newMessage.msgId),
            },
          },
        }

      case "editMessage":
        return {
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "editMessage",
            editMessage: {
              message: msgs.get(serverUpdate.update.editMessage.msgId),
            },
          },
        }

      case "deleteMessages":
        return {
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "deleteMessages",
            deleteMessages: {
              messageIds: serverUpdate.update.deleteMessages.msgIds,
              peerId: peerId,
            },
          },
        }

      case "participantDelete":
        return {
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "participantDelete",
            participantDelete: {
              chatId: serverUpdate.update.participantDelete.chatId,
              userId: serverUpdate.update.participantDelete.userId,
            },
          },
        }

      case "chatVisibility":
        return {
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "chatVisibility",
            chatVisibility: {
              chatId: serverUpdate.update.chatVisibility.chatId,
              isPublic: serverUpdate.update.chatVisibility.isPublic,
            },
          },
        }

      default:
        throw new Error(`Unknown update type: ${serverUpdate.update.oneofKind}`)
    }
  })

  return { updates: inflatedUpdates }
}

function inflateSpaceUpdates(dbUpdates: DbUpdate[]): Update[] {
  return dbUpdates
    .map((dbUpdate) => {
      const decrypted = UpdatesModel.decrypt(dbUpdate)
      return convertSpaceUpdate(decrypted)
    })
    .filter((update): update is Update => Boolean(update))
}

function inflateUserUpdates(dbUpdates: DbUpdate[]): Update[] {
  return dbUpdates
    .map((dbUpdate) => {
      const decrypted = UpdatesModel.decrypt(dbUpdate)
      return convertUserUpdate(decrypted, dbUpdate.entityId)
    })
    .filter((update): update is Update => Boolean(update))
}

function convertSpaceUpdate(update: DecryptedUpdate): Update | null {
  const seq = update.seq
  const date = encodeDateStrict(update.date)
  const payload = update.payload.update

  if (payload.oneofKind === "spaceRemoveMember") {
    return {
      seq,
      date,
      update: {
        oneofKind: "spaceMemberDelete",
        spaceMemberDelete: {
          spaceId: payload.spaceRemoveMember.spaceId,
          userId: payload.spaceRemoveMember.userId,
        },
      },
    }
  }

  if (payload.oneofKind === "spaceMemberUpdate") {
    return {
      seq,
      date,
      update: {
        oneofKind: "spaceMemberUpdate",
        spaceMemberUpdate: {
          member: payload.spaceMemberUpdate.member,
        },
      },
    }
  }

  log.warn("Unhandled space update", { type: payload.oneofKind })
  return null
}

function convertUserUpdate(decrypted: DecryptedUpdate, userId: number): Update | null {
  const seq = decrypted.seq
  const date = encodeDateStrict(decrypted.date)
  const payload = decrypted.payload.update

  switch (payload.oneofKind) {
    case "userSpaceMemberDelete":
      return {
        seq,
        date,
        update: {
          oneofKind: "spaceMemberDelete",
          spaceMemberDelete: {
            spaceId: payload.userSpaceMemberDelete.spaceId,
            userId: BigInt(userId),
          },
        },
      }

    case "userChatParticipantDelete":
      return {
        seq,
        date,
        update: {
          oneofKind: "participantDelete",
          participantDelete: {
            chatId: payload.userChatParticipantDelete.chatId,
            userId: BigInt(userId),
          },
        },
      }

    default:
      log.warn("Unhandled user update", { type: payload.oneofKind })
      return null
  }
}
