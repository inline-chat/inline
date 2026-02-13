import type { Message, Peer, Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import { UpdatesModel, type UpdateBoxInput, type DecryptedUpdate } from "@in/server/db/models/updates"
import { UpdateBucket, chats, type DbUpdate, type DbUser, type DbFile } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log, LogLevel } from "@in/server/utils/log"
import { eq } from "drizzle-orm"

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
  let needsChat = false

  // Loop through updates to find message ids we need to fetch
  for (const update of decryptedUpdates) {
    let serverUpdate = update.payload.update
    if (serverUpdate.oneofKind === "newMessage") {
      messageIds.add(serverUpdate.newMessage.msgId)
    } else if (serverUpdate.oneofKind === "editMessage") {
      messageIds.add(serverUpdate.editMessage.msgId)
    } else if (serverUpdate.oneofKind === "newChat") {
      needsChat = true
    } else if (serverUpdate.oneofKind === "chatMoved") {
      needsChat = true
    }
  }

  let chatRecord: typeof chats.$inferSelect | undefined
  let otherUser: { user: DbUser; photoFile?: DbFile } | undefined
  if (needsChat) {
    const [chat] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
    if (!chat) {
      log.warn("Failed to find chat for newChat update", { chatId })
    } else {
      chatRecord = chat

      if (chat.type === "private" && chat.minUserId && chat.maxUserId) {
        const otherUserId = chat.minUserId === userId ? chat.maxUserId : chat.minUserId
        if (otherUserId && otherUserId !== userId) {
          const users = await UsersModel.getUsersWithPhotos([otherUserId])
          if (users[0]) {
            otherUser = users[0]
          }
        }
      }
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
  const inflatedUpdates: Update[] = []
  for (const update of decryptedUpdates) {
    const serverUpdate = update.payload

    switch (serverUpdate.update.oneofKind) {
      case "newMessage":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "newMessage",
            newMessage: {
              message: msgs.get(serverUpdate.update.newMessage.msgId),
            },
          },
        })
        break

      case "editMessage":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "editMessage",
            editMessage: {
              message: msgs.get(serverUpdate.update.editMessage.msgId),
            },
          },
        })
        break

      case "deleteMessages":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "deleteMessages",
            deleteMessages: {
              messageIds: serverUpdate.update.deleteMessages.msgIds,
              peerId: peerId,
            },
          },
        })
        break

      case "participantDelete":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "participantDelete",
            participantDelete: {
              chatId: serverUpdate.update.participantDelete.chatId,
              userId: serverUpdate.update.participantDelete.userId,
            },
          },
        })
        break

      case "chatVisibility":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "chatVisibility",
            chatVisibility: {
              chatId: serverUpdate.update.chatVisibility.chatId,
              isPublic: serverUpdate.update.chatVisibility.isPublic,
            },
          },
        })
        break

      case "deleteChat":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "deleteChat",
            deleteChat: {
              peerId: peerId,
            },
          },
        })
        break

      case "newChat":
        if (!chatRecord) {
          log.warn("Skipping newChat update due to missing chat record", { chatId })
          break
        }
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "newChat",
            newChat: {
              chat: Encoders.chat(chatRecord, { encodingForUserId: userId }),
              user: otherUser ? Encoders.user({ user: otherUser.user, photoFile: otherUser.photoFile }) : undefined,
            },
          },
        })
        break

      case "chatMoved":
        if (!chatRecord) {
          log.warn("Skipping chatMoved update due to missing chat record", { chatId })
          break
        }
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "chatMoved",
            chatMoved: {
              chat: Encoders.chat(chatRecord, { encodingForUserId: userId }),
              oldSpaceId: serverUpdate.update.chatMoved.oldSpaceId,
              newSpaceId: serverUpdate.update.chatMoved.newSpaceId,
            },
          },
        })
        break

      case "chatInfo":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "chatInfo",
            chatInfo: {
              chatId: serverUpdate.update.chatInfo.chatId,
              title: serverUpdate.update.chatInfo.title,
              emoji: serverUpdate.update.chatInfo.emoji,
            },
          },
        })
        break

      case "pinnedMessages":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "pinnedMessages",
            pinnedMessages: {
              peerId: peerId,
              messageIds: serverUpdate.update.pinnedMessages.messageIds,
            },
          },
        })
        break

      default:
        log.warn("Unhandled chat update", { type: serverUpdate.update.oneofKind })
        break
    }
  }

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

  if (payload.oneofKind === "spaceMemberAdd") {
    return {
      seq,
      date,
      update: {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: {
          member: payload.spaceMemberAdd.member,
          user: payload.spaceMemberAdd.user,
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

    case "userDialogArchived":
      return {
        seq,
        date,
        update: {
          oneofKind: "dialogArchived",
          dialogArchived: {
            peerId: payload.userDialogArchived.peerId,
            archived: payload.userDialogArchived.archived,
          },
        },
      }

    case "userJoinSpace":
      return {
        seq,
        date,
        update: {
          oneofKind: "joinSpace",
          joinSpace: {
            space: payload.userJoinSpace.space,
            member: payload.userJoinSpace.member,
          },
        },
      }

    case "userReadMaxId":
      return {
        seq,
        date,
        update: {
          oneofKind: "updateReadMaxId",
          updateReadMaxId: {
            peerId: payload.userReadMaxId.peerId,
            readMaxId: payload.userReadMaxId.readMaxId,
            unreadCount: payload.userReadMaxId.unreadCount,
          },
        },
      }

    case "userMarkAsUnread":
      return {
        seq,
        date,
        update: {
          oneofKind: "markAsUnread",
          markAsUnread: {
            peerId: payload.userMarkAsUnread.peerId,
            unreadMark: payload.userMarkAsUnread.unreadMark,
          },
        },
      }

    case "userDialogNotificationSettings":
      return {
        seq,
        date,
        update: {
          oneofKind: "dialogNotificationSettings",
          dialogNotificationSettings: {
            peerId: payload.userDialogNotificationSettings.peerId,
            notificationSettings: payload.userDialogNotificationSettings.notificationSettings,
          },
        },
      }

    default:
      log.warn("Unhandled user update", { type: payload.oneofKind })
      return null
  }
}
