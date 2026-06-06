import type {
  Chat as ProtocolChat,
  Message,
  MessageAttachment,
  Peer,
  Space as ProtocolSpace,
  Update,
  UpdateSidecars,
  User,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import { UpdatesModel, type UpdateBoxInput, type DecryptedUpdate } from "@in/server/db/models/updates"
import { UpdateBucket, chats, messageAttachments, spaces, type DbUpdate } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeMessageAttachment } from "@in/server/realtime/encoders/encodeMessageAttachment"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log, LogLevel } from "@in/server/utils/log"
import { eq, inArray } from "drizzle-orm"
import { getMessageRepliesMap } from "@in/server/modules/subthreads"

const log = new Log("Sync", LogLevel.DEBUG)

export const Sync = {
  getUpdates: getUpdates,
  processChatUpdates: processChatUpdates,
  buildChatSidecarsForUpdates: buildChatSidecarsForUpdates,
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
  if (updates.length === 0) {
    return { updates: [] }
  }

  // Decrypt
  const decryptedUpdates = updates.map((dbUpdate) => UpdatesModel.decrypt(dbUpdate))

  // Find attached nodes (later we'll support for types)
  let messageIds: Set<bigint> = new Set()
  let attachmentIds: Set<number> = new Set()
  let needsChat = false
  let needsNewChatUser = false

  // Loop through updates to find message ids we need to fetch
  for (const update of decryptedUpdates) {
    let serverUpdate = update.payload.update
    if (serverUpdate.oneofKind === "newMessage") {
      messageIds.add(serverUpdate.newMessage.msgId)
    } else if (serverUpdate.oneofKind === "editMessage") {
      messageIds.add(serverUpdate.editMessage.msgId)
    } else if (serverUpdate.oneofKind === "messageAttachment") {
      attachmentIds.add(Number(serverUpdate.messageAttachment.attachmentId))
    } else if (serverUpdate.oneofKind === "newChat") {
      needsChat = true
      needsNewChatUser = true
    } else if (serverUpdate.oneofKind === "chatMoved") {
      needsChat = true
    }
  }

  let chatRecord: typeof chats.$inferSelect | undefined
  let peerUserId: number | undefined
  let peerUser: User | undefined
  if (needsChat) {
    const [chat] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
    if (!chat) {
      log.warn("Failed to find chat for chat update", { chatId })
    } else {
      chatRecord = chat

      if (chat.type === "private" && chat.minUserId && chat.maxUserId) {
        const otherUserId = chat.minUserId === userId ? chat.maxUserId : chat.minUserId
        if (otherUserId && otherUserId !== userId) {
          peerUserId = otherUserId
        }
      }
    }
  }
  if (needsNewChatUser && peerUserId !== undefined) {
    const [row] = await UsersModel.getUsersWithPhotos([peerUserId])
    if (row) {
      peerUser = Encoders.user({ user: row.user, photoFile: row.photoFile, min: true })
    }
  }

  // Fetch from db
  const dbMessages = await MessageModel.getMessagesByIds(chatId, Array.from(messageIds))
  const dbAttachments = attachmentIds.size > 0
    ? (
        await Promise.all(
          Array.from(attachmentIds).map((attachmentId) =>
            db._query.messageAttachments.findFirst({
              where: eq(messageAttachments.id, attachmentId),
              with: {
                externalTask: true,
                linkEmbed: {
                  with: {
                    photo: {
                      with: {
                        photoSizes: {
                          with: {
                            file: true,
                          },
                        },
                      },
                    },
                    video: {
                      with: {
                        file: true,
                        photo: {
                          with: {
                            photoSizes: {
                              with: {
                                file: true,
                              },
                            },
                          },
                        },
                      },
                    },
                    document: {
                      with: {
                        file: true,
                        photo: {
                          with: {
                            photoSizes: {
                              with: {
                                file: true,
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            }),
          ),
        )
      ).filter((attachment) => attachment !== undefined)
    : []
  const repliesMap = await getMessageRepliesMap({
    parentChatId: chatId,
    parentMessageIds: dbMessages.map((message) => message.messageId),
    userId,
  })
  // Store encoded messages in a map
  const msgs = new Map<bigint, Message>()
  for (const message of dbMessages) {
    const encoded = Encoders.fullMessage({
      message,
      encodingForUserId: userId,
      encodingForPeer: { peer: peerId },
      replies: repliesMap.get(message.messageId),
    })
    msgs.set(encoded.id, encoded)
  }

  const attachments = new Map(
    MessageModel.processAttachments(dbAttachments)
      .map((attachment) => [Number(attachment.id), encodeMessageAttachment(attachment)] as const)
      .filter((entry): entry is readonly [number, NonNullable<ReturnType<typeof encodeMessageAttachment>>] => entry[1] !== null),
  )

  // Encode updates
  const inflatedUpdates: Update[] = []
  for (const update of decryptedUpdates) {
    const serverUpdate = update.payload

    switch (serverUpdate.update.oneofKind) {
      case "newMessage": {
        const message = msgs.get(serverUpdate.update.newMessage.msgId)
        if (!message) {
          log.warn("Skipping newMessage update due to missing message", {
            chatId,
            msgId: String(serverUpdate.update.newMessage.msgId),
            seq: update.seq,
          })
          break
        }

        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "newMessage",
            newMessage: {
              message,
            },
          },
        })
        break
      }

      case "editMessage": {
        const message = msgs.get(serverUpdate.update.editMessage.msgId)
        if (!message) {
          log.warn("Skipping editMessage update due to missing message", {
            chatId,
            msgId: String(serverUpdate.update.editMessage.msgId),
            seq: update.seq,
          })
          break
        }

        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "editMessage",
            editMessage: {
              message,
            },
          },
        })
        break
      }

      case "messageAttachment": {
        const attachmentId = serverUpdate.update.messageAttachment.attachmentId
        const attachment: MessageAttachment =
          attachments.get(Number(attachmentId)) ?? {
            id: attachmentId,
            attachment: { oneofKind: undefined },
          }

        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "messageAttachment",
            messageAttachment: {
              messageId: serverUpdate.update.messageAttachment.msgId,
              chatId: serverUpdate.update.messageAttachment.chatId,
              peerId,
              attachment,
            },
          },
        })
        break
      }

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

      case "clearChatHistory":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "clearChatHistory",
            clearChatHistory: {
              target: {
                oneofKind: "peerId",
                peerId,
              },
              beforeDate: serverUpdate.update.clearChatHistory.beforeDate,
              deleteReplyThreads: serverUpdate.update.clearChatHistory.deleteReplyThreads,
              deletedChatIds: serverUpdate.update.clearChatHistory.deletedChatIds,
              orphanedChatIds: serverUpdate.update.clearChatHistory.orphanedChatIds,
              detachedChatIds: serverUpdate.update.clearChatHistory.detachedChatIds,
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

      case "participantAdd":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "participantAdd",
            participantAdd: {
              chatId: serverUpdate.update.participantAdd.chatId,
              participant: serverUpdate.update.participantAdd.participant,
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
              user: peerUser,
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
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "chatSkipPts",
            chatSkipPts: {
              chatId: BigInt(chatId),
            },
          },
        })
        break
    }
  }

  return { updates: inflatedUpdates }
}

const emptySidecars = (): UpdateSidecars => ({
  users: [],
  chats: [],
  dialogs: [],
  spaces: [],
})

type ChatSidecarsForUpdatesInput = {
  chatId: number
  updates: Update[]
  userId: number
}

async function buildChatSidecarsForUpdates(input: ChatSidecarsForUpdatesInput): Promise<UpdateSidecars> {
  const users = new Map<string, User>()
  const chatMap = new Map<string, ProtocolChat>()
  const spaceMap = new Map<string, ProtocolSpace>()
  const userIds = new Set<number>()
  const chatIds = new Set<number>()
  const spaceIds = new Set<number>()

  if (input.updates.length === 0) {
    return emptySidecars()
  }

  const [primaryChat] = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1)
  if (!primaryChat) {
    log.warn("Failed to find chat for delivered update sidecars", { chatId: input.chatId })
  } else {
    collectChatSidecarRefs(primaryChat, input.userId, { chatIds, userIds, spaceIds })
  }

  for (const update of input.updates) {
    switch (update.update.oneofKind) {
      case "newMessage":
        collectMessageSidecarRefs(update.update.newMessage.message, { chatIds, userIds, spaceIds })
        break

      case "editMessage":
        collectMessageSidecarRefs(update.update.editMessage.message, { chatIds, userIds, spaceIds })
        break

      case "newChat":
        collectProtocolChatSidecarRefs(update.update.newChat.chat, { chatIds, userIds, spaceIds })
        break

      case "chatMoved":
        collectProtocolChatSidecarRefs(update.update.chatMoved.chat, { chatIds, userIds, spaceIds })
        break

      default:
        break
    }
  }

  const chatRows = await getSidecarChats(primaryChat, chatIds)
  for (const chat of chatRows) {
    collectChatSidecarRefs(chat, input.userId, { chatIds, userIds, spaceIds })
    const encoded = Encoders.chat(chat, { encodingForUserId: input.userId })
    chatMap.set(String(encoded.id), encoded)
  }

  if (userIds.size > 0) {
    const rows = await UsersModel.getUsersWithPhotos(Array.from(userIds))
    for (const row of rows) {
      const encoded = Encoders.user({ user: row.user, photoFile: row.photoFile, min: true })
      users.set(String(encoded.id), encoded)
    }
  }

  if (spaceIds.size > 0) {
    const rows = await db.select().from(spaces).where(inArray(spaces.id, Array.from(spaceIds)))
    for (const row of rows) {
      const encoded = Encoders.space(row, { encodingForUserId: input.userId })
      spaceMap.set(String(encoded.id), encoded)
    }
  }

  return {
    users: Array.from(users.values()),
    chats: Array.from(chatMap.values()),
    dialogs: [],
    spaces: Array.from(spaceMap.values()),
  }
}

type ChatSidecarRefs = {
  chatIds: Set<number>
  userIds: Set<number>
  spaceIds: Set<number>
}

function collectChatSidecarRefs(
  chat: typeof chats.$inferSelect,
  userId: number,
  refs: ChatSidecarRefs,
) {
  refs.chatIds.add(chat.id)

  if (chat.spaceId) {
    refs.spaceIds.add(chat.spaceId)
  }
  if (chat.parentChatId) {
    refs.chatIds.add(chat.parentChatId)
  }
  if (chat.createdBy) {
    refs.userIds.add(chat.createdBy)
  }

  if (chat.type !== "private" || !chat.minUserId || !chat.maxUserId) {
    return
  }

  const otherUserId = chat.minUserId === userId ? chat.maxUserId : chat.minUserId
  if (otherUserId && otherUserId !== userId) {
    refs.userIds.add(otherUserId)
  }
}

function collectProtocolChatSidecarRefs(chat: ProtocolChat | undefined, refs: ChatSidecarRefs) {
  if (!chat) {
    return
  }

  addSafeId(refs.chatIds, chat.id)
  addSafeId(refs.chatIds, chat.parentChatId)
  addSafeId(refs.spaceIds, chat.spaceId)
  addSafeId(refs.userIds, chat.createdBy)

  if (chat.peerId?.type.oneofKind === "user") {
    addSafeId(refs.userIds, chat.peerId.type.user.userId)
  }
}

function collectMessageSidecarRefs(message: Message | undefined, refs: ChatSidecarRefs) {
  if (!message) {
    return
  }

  addSafeId(refs.userIds, message.fromId)
  addSafeId(refs.chatIds, message.chatId)

  switch (message.peerId?.type.oneofKind) {
    case "user":
      addSafeId(refs.userIds, message.peerId.type.user.userId)
      break
    case "chat":
      addSafeId(refs.chatIds, message.peerId.type.chat.chatId)
      break
    case undefined:
      break
  }

  if (!message.fwdFrom) {
    return
  }

  addSafeId(refs.userIds, message.fwdFrom.fromId)
  if (message.fwdFrom.fromPeerId?.type.oneofKind === "user") {
    addSafeId(refs.userIds, message.fwdFrom.fromPeerId.type.user.userId)
  }
  // Forwarded chat ids are message metadata. Do not include full forwarded-chat
  // sidecars here unless access is verified; old clients can materialize a
  // minimal local placeholder during catch-up if needed.
}

function addSafeId(ids: Set<number>, id: bigint | number | undefined) {
  if (id === undefined) {
    return
  }

  const value = typeof id === "bigint" ? Number(id) : id
  if (Number.isSafeInteger(value) && value > 0) {
    ids.add(value)
  }
}

async function getSidecarChats(
  primaryChat: typeof chats.$inferSelect | undefined,
  chatIds: Set<number>,
): Promise<(typeof chats.$inferSelect)[]> {
  const rows: (typeof chats.$inferSelect)[] = []
  const seen = new Set<number>()

  if (primaryChat) {
    rows.push(primaryChat)
    seen.add(primaryChat.id)
  }

  while (true) {
    const missingIds = Array.from(chatIds).filter((chatId) => !seen.has(chatId))
    if (missingIds.length === 0) {
      return sortChatsForSidecars(rows)
    }

    const fetched = await db.select().from(chats).where(inArray(chats.id, missingIds))
    if (fetched.length === 0) {
      return sortChatsForSidecars(rows)
    }

    for (const chat of fetched) {
      if (seen.has(chat.id)) {
        continue
      }
      rows.push(chat)
      seen.add(chat.id)
      if (chat.parentChatId) {
        chatIds.add(chat.parentChatId)
      }
    }
  }
}

function sortChatsForSidecars(rows: (typeof chats.$inferSelect)[]): (typeof chats.$inferSelect)[] {
  const byId = new Map(rows.map((chat) => [chat.id, chat]))
  const sorted: (typeof chats.$inferSelect)[] = []
  const visiting = new Set<number>()
  const visited = new Set<number>()

  const visit = (chat: typeof chats.$inferSelect) => {
    if (visited.has(chat.id)) {
      return
    }
    if (visiting.has(chat.id)) {
      return
    }

    visiting.add(chat.id)
    const parent = chat.parentChatId ? byId.get(chat.parentChatId) : undefined
    if (parent) {
      visit(parent)
    }
    visiting.delete(chat.id)
    visited.add(chat.id)
    sorted.push(chat)
  }

  for (const chat of rows) {
    visit(chat)
  }

  return sorted
}

function inflateSpaceUpdates(dbUpdates: DbUpdate[], options?: { sanitizeUsers?: boolean }): Update[] {
  return dbUpdates
    .map((dbUpdate) => {
      const decrypted = UpdatesModel.decrypt(dbUpdate)
      return convertSpaceUpdate(decrypted, options)
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

function convertSpaceUpdate(update: DecryptedUpdate, options?: { sanitizeUsers?: boolean }): Update | null {
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
    const user = options?.sanitizeUsers ? sanitizeUser(payload.spaceMemberAdd.user) : payload.spaceMemberAdd.user
    return {
      seq,
      date,
      update: {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: {
          member: payload.spaceMemberAdd.member,
          user,
        },
      },
    }
  }

  if (payload.oneofKind === "spaceClearHistory") {
    return {
      seq,
      date,
      update: {
        oneofKind: "clearChatHistory",
        clearChatHistory: {
          target: {
            oneofKind: "spaceId",
            spaceId: payload.spaceClearHistory.spaceId,
          },
          beforeDate: payload.spaceClearHistory.beforeDate,
          deleteReplyThreads: payload.spaceClearHistory.deleteReplyThreads,
          deletedChatIds: payload.spaceClearHistory.deletedChatIds,
          orphanedChatIds: payload.spaceClearHistory.orphanedChatIds,
          detachedChatIds: payload.spaceClearHistory.detachedChatIds,
        },
      },
    }
  }

  log.warn("Unhandled space update", { type: payload.oneofKind })
  return null
}

function sanitizeUser(user: User | undefined): User | undefined {
  if (!user) {
    return undefined
  }

  return {
    id: user.id,
    firstName: user.firstName,
    lastName: user.lastName,
    username: user.username,
    min: true,
    bot: user.bot,
    profilePhoto: user.profilePhoto,
  }
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

    case "userChatParticipantAdd":
      return {
        seq,
        date,
        update: {
          oneofKind: "participantAdd",
          participantAdd: {
            chatId: payload.userChatParticipantAdd.chatId,
            participant: payload.userChatParticipantAdd.participant,
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

    case "userDialogFollowMode":
      return {
        seq,
        date,
        update: {
          oneofKind: "dialogFollowMode",
          dialogFollowMode: {
            peerId: payload.userDialogFollowMode.peerId,
            followMode: payload.userDialogFollowMode.followMode,
          },
        },
      }

    case "userChatOpen":
      return {
        seq,
        date,
        update: {
          oneofKind: "chatOpen",
          chatOpen: {
            chat: payload.userChatOpen.chat,
            dialog: payload.userChatOpen.dialog,
            user: payload.userChatOpen.user,
          },
        },
      }

    case "userMessageActionInvoked":
      return {
        seq,
        date,
        update: {
          oneofKind: "messageActionInvoked",
          messageActionInvoked: {
            interactionId: BigInt(seq),
            chatId: payload.userMessageActionInvoked.chatId,
            messageId: payload.userMessageActionInvoked.messageId,
            actorUserId: payload.userMessageActionInvoked.actorUserId,
            actionId: payload.userMessageActionInvoked.actionId,
            data: payload.userMessageActionInvoked.data,
          },
        },
      }

    case "userMessageActionAnswered":
      return {
        seq,
        date,
        update: {
          oneofKind: "messageActionAnswered",
          messageActionAnswered: {
            interactionId: payload.userMessageActionAnswered.interactionId,
            ui: payload.userMessageActionAnswered.ui,
          },
        },
      }

    default:
      log.warn("Unhandled user update", { type: payload.oneofKind })
      return null
  }
}
