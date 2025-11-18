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
  const { bucket, seqStart } = input
  const entityId = getEntityId(bucket)

  const list = await db.query.updates.findMany({
    where: {
      bucket: bucket.type,
      entityId,
      seq: {
        gt: seqStart,
      },
    },
    orderBy: {
      seq: "asc",
    },
    limit: input.limit,
  })

  const latest = await db.query.updates.findFirst({
    where: {
      bucket: bucket.type,
      entityId,
    },
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
      return convertUserUpdate(decrypted)
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

  log.warn("Unhandled space update", { type: payload.oneofKind })
  return null
}

function convertUserUpdate(decrypted: DecryptedUpdate): Update | null {
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
            userId: payload.userSpaceMemberDelete.userId,
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
            userId: payload.userChatParticipantDelete.userId,
          },
        },
      }

    default:
      log.warn("Unhandled user update", { type: payload.oneofKind })
      return null
  }
}
