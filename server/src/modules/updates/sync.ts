import type { Message, Peer, Update } from "@in/protocol/core"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { UpdatesModel, type UpdateBoxInput } from "@in/server/db/models/updates"
import { UpdateBucket, type DbUpdate } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log, LogLevel } from "@in/server/utils/log"

const log = new Log("Sync", LogLevel.TRACE)

export const Sync = {
  getUpdates: getUpdates,
  processChatUpdates: processChatUpdates,
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
}

// Get a list of updates from the database
async function getUpdates(input: GetUpdatesInput): Promise<GetUpdatesOutput> {
  const { bucket, seqStart } = input

  const list = await db.query.updates.findMany({
    where: {
      bucket: bucket.type,
      entityId:
        bucket.type === UpdateBucket.Chat
          ? bucket.chatId
          : bucket.type === UpdateBucket.User
          ? bucket.userId
          : bucket.type === UpdateBucket.Space
          ? bucket.spaceId
          : -1, // should never rich
      seq: {
        gt: seqStart,
      },
    },
    orderBy: {
      seq: "asc",
    },
    limit: input.limit,
  })

  return { updates: list }
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

      default:
        throw new Error(`Unknown update type: ${serverUpdate.update.oneofKind}`)
    }
  })

  return { updates: inflatedUpdates }
}
