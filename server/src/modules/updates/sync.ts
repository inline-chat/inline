import { getSignedMediaFileProxyUrl } from "@in/server/modules/files/path"
import type {
  Chat as ProtocolChat,
  Message,
  MessageAttachment,
  Peer,
  Space as ProtocolSpace,
  Update,
  UpdateSidecars,
  SyncSkippedSequence,
  User,
  UserGroup as ProtocolUserGroup,
  Dialog,
} from "@inline-chat/protocol/core"
import { SyncSkippedSequence_Reason } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import { UpdatesModel, type UpdateBoxInput, type DecryptedUpdate } from "@in/server/db/models/updates"
import {
  UpdateBucket,
  chatParticipantGroups,
  chatParticipants,
  chats,
  dialogs,
  members,
  messageAttachments,
  spaces,
  updates as updatesTable,
  userGroupMembers,
  userGroups,
  userNotDeleted,
  users as usersTable,
  type DbUpdate,
} from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeMessageAttachment } from "@in/server/realtime/encoders/encodeMessageAttachment"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log, LogLevel } from "@in/server/utils/log"
import { and, asc, desc, eq, gt, inArray, isNull, lte, or } from "drizzle-orm"
import { getMessageThreadProjectionsMap } from "@in/server/modules/subthreads"
import { BoundedLogAggregator } from "@in/server/utils/logging/boundedLogAggregator"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"

const log = new Log("Sync", LogLevel.DEBUG)
const missingMessageLogs = new BoundedLogAggregator(15 * 60 * 1000, 1_024)
const malformedUserReplayLogs = new BoundedLogAggregator(15 * 60 * 1000, 1_024)

const logMissingMessage = (
  updateKind: "newMessage" | "editMessage",
  details: { chatId: number; msgId: bigint; seq: number },
) => {
  const decision = missingMessageLogs.record(`${updateKind}:${details.chatId}`)
  if (!decision.emit) return

  log.warn("Skipping updates whose messages are no longer available", {
    updateKind,
    chatId: details.chatId,
    sampleMsgId: String(details.msgId),
    sampleSeq: details.seq,
    suppressedCount: decision.suppressedCount,
  })
}

export const Sync = {
  getUpdates: getUpdates,
  processChatUpdates: processChatUpdates,
  buildChatSidecarsForUpdates: buildChatSidecarsForUpdates,
  buildSpaceSidecarsForUpdates: buildSpaceSidecarsForUpdates,
  buildUserSidecarsForUpdates: buildUserSidecarsForUpdates,
  inflateSpaceUpdates: inflateSpaceUpdates,
  inflateUserUpdates: inflateUserUpdates,
  inflateSpaceUpdatesPage: inflateSpaceUpdatesPage,
  inflateUserUpdatesPage: inflateUserUpdatesPage,
  prepareUserUpdatesPage,
}

export type InflatedUpdatesPage = {
  updates: Update[]
  skippedSequences: SyncSkippedSequence[]
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

  const pageWhere = and(
    eq(updatesTable.bucket, bucket.type),
    eq(updatesTable.entityId, entityId),
    gt(updatesTable.seq, seqStart),
    seqEnd !== undefined ? lte(updatesTable.seq, seqEnd) : undefined,
  )
  const latestWhere = and(
    eq(updatesTable.bucket, bucket.type),
    eq(updatesTable.entityId, entityId),
    seqEnd !== undefined ? lte(updatesTable.seq, seqEnd) : undefined,
  )

  return db.transaction(
    async (tx) => {
      const list = await tx
        .select()
        .from(updatesTable)
        .where(pageWhere)
        .orderBy(asc(updatesTable.seq))
        .limit(input.limit)

      const [latest] = await tx
        .select()
        .from(updatesTable)
        .where(latestWhere)
        .orderBy(desc(updatesTable.seq))
        .limit(1)

      // Retention can remove every journal row. The owning entity is the
      // durable tail, read in the same snapshot as the page, not the journal.
      const entityTable = bucket.type === UpdateBucket.Chat
        ? chats
        : bucket.type === UpdateBucket.Space ? spaces : usersTable
      const [entity] = await tx
        .select({ seq: entityTable.updateSeq, date: entityTable.lastUpdateDate })
        .from(entityTable)
        .where(eq(entityTable.id, entityId))
        .limit(1)
      const entitySeq = entity?.seq ?? 0
      const boundedEntitySeq = seqEnd === undefined ? entitySeq : Math.min(entitySeq, seqEnd)
      const latestSeq = Math.max(latest?.seq ?? 0, boundedEntitySeq, seqStart)
      const latestDate = latest?.seq === latestSeq
        ? latest.date
        : entitySeq === latestSeq ? entity?.date ?? null : null

      return {
        updates: list,
        latestSeq,
        latestDate,
      }
    },
    { isolationLevel: "repeatable read", accessMode: "read only" },
  )
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
      return assertNever(bucket)
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
  const attachmentIds: number[] = []
  const attachmentMessageIds = new Map<number, Set<number>>()
  const participantUserIds = new Set<number>()
  const participantGroupIds = new Set<number>()
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
      const attachmentId = safePositiveId(serverUpdate.messageAttachment.attachmentId)
      const messageId = safePositiveId(serverUpdate.messageAttachment.msgId)
      if (serverUpdate.messageAttachment.chatId === BigInt(chatId) && attachmentId !== undefined && messageId !== undefined) {
        attachmentIds.push(attachmentId)
        const expectedMessageIds = attachmentMessageIds.get(attachmentId) ?? new Set<number>()
        expectedMessageIds.add(messageId)
        attachmentMessageIds.set(attachmentId, expectedMessageIds)
      }
    } else if (serverUpdate.oneofKind === "participantAdd") {
      if (serverUpdate.participantAdd.chatId === BigInt(chatId)) {
        addSafeId(participantUserIds, serverUpdate.participantAdd.participant?.userId)
      }
    } else if (serverUpdate.oneofKind === "participantGroupAdd") {
      if (serverUpdate.participantGroupAdd.chatId === BigInt(chatId)) {
        addSafeId(participantGroupIds, serverUpdate.participantGroupAdd.groupParticipant?.groupId)
      }
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
  const encodedChat = chatRecord
    ? await Encoders.chatForUser(chatRecord, { encodingForUserId: userId })
    : undefined

  const validParticipantUserIds = new Set<number>()
  if (participantUserIds.size > 0) {
    const rows = await db
      .select({ userId: chatParticipants.userId })
      .from(chatParticipants)
      .innerJoin(chats, eq(chats.id, chatParticipants.chatId))
      .innerJoin(usersTable, eq(usersTable.id, chatParticipants.userId))
      .leftJoin(members, and(eq(members.userId, chatParticipants.userId), eq(members.spaceId, chats.spaceId)))
      .where(and(
        eq(chatParticipants.chatId, chatId),
        inArray(chatParticipants.userId, Array.from(participantUserIds)),
        userNotDeleted(),
        or(
          isNull(chats.spaceId),
          and(
            eq(members.userId, chatParticipants.userId),
            or(eq(chats.publicThread, false), isNull(chats.publicThread), eq(members.canAccessPublicChats, true), isNull(members.canAccessPublicChats)),
          ),
        ),
      ))
    for (const row of rows) validParticipantUserIds.add(row.userId)
  }

  const validParticipantGroupIds = new Set<number>()
  if (participantGroupIds.size > 0) {
    const rows = await db
      .select({ groupId: chatParticipantGroups.groupId })
      .from(chatParticipantGroups)
      .innerJoin(chats, eq(chats.id, chatParticipantGroups.chatId))
      .innerJoin(
        userGroups,
        and(eq(userGroups.id, chatParticipantGroups.groupId), eq(userGroups.spaceId, chats.spaceId)),
      )
      .where(and(
        eq(chatParticipantGroups.chatId, chatId),
        inArray(chatParticipantGroups.groupId, Array.from(participantGroupIds)),
        or(eq(chats.publicThread, false), isNull(chats.publicThread)),
      ))
    for (const row of rows) validParticipantGroupIds.add(row.groupId)
  }

  // Fetch from db
  const dbMessages = await MessageModel.getMessagesByIds(chatId, Array.from(messageIds))
  const uniqueAttachmentIds = Array.from(new Set(attachmentIds))
  const fetchedAttachments = uniqueAttachmentIds.length > 0
    ? await db._query.messageAttachments.findMany({
        where: inArray(messageAttachments.id, uniqueAttachmentIds),
        with: {
          externalTask: true,
          message: true,
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
      })
    : []
  const fetchedAttachmentById = new Map(fetchedAttachments.map((attachment) => [Number(attachment.id), attachment]))
  const dbAttachments = uniqueAttachmentIds.flatMap((attachmentId) => {
    const attachment = fetchedAttachmentById.get(attachmentId)
    const expectedMessageIds = attachmentMessageIds.get(attachmentId)
    return attachment?.message?.chatId === chatId && expectedMessageIds?.has(attachment.message.messageId)
      ? [attachment]
      : []
  })
  const threadProjections = await getMessageThreadProjectionsMap({
    parentChatId: chatId,
    parentMessageIds: dbMessages.map((message) => message.messageId),
    userId,
  })
  // Store encoded messages in a map
  const msgs = new Map<bigint, Message>()
  for (const message of dbMessages) {
    const threadProjection = threadProjections.get(message.messageId)
    const encoded = Encoders.fullMessage({
      message,
      encodingForUserId: userId,
      encodingForPeer: { peer: peerId },
      replies: threadProjection?.replies,
      subthread: threadProjection?.subthread,
    })
    msgs.set(encoded.id, encoded)
  }

  const attachments = new Map<number, MessageAttachment>()
  const corruptAttachmentIds = new Set<number>()
  for (const dbAttachment of dbAttachments) {
    try {
      const [processed] = MessageModel.processAttachments([dbAttachment])
      if (!processed) continue
      const encoded = encodeMessageAttachment(processed)
      if (encoded) attachments.set(Number(dbAttachment.id), encoded)
    } catch {
      const attachmentId = Number(dbAttachment.id)
      corruptAttachmentIds.add(attachmentId)
      log.warn("Skipping corrupt message attachment during replay", {
        chatId,
        attachmentId,
      })
    }
  }

  // Encode updates
  const inflatedUpdates: Update[] = []
  for (const update of decryptedUpdates) {
    const serverUpdate = update.payload

    switch (serverUpdate.update.oneofKind) {
      case "acknowledgement":
        if (Number(serverUpdate.update.acknowledgement.chatId) !== chatId) {
          log.warn("Skipping acknowledgement assigned to the wrong chat bucket", {
            bucketChatId: chatId,
            acknowledgementChatId: String(serverUpdate.update.acknowledgement.chatId),
            seq: update.seq,
          })
          inflatedUpdates.push(chatSkipPts(update, chatId))
          break
        }
        inflatedUpdates.push({ seq: update.seq, date: encodeDateStrict(update.date), update: {
          oneofKind: "acknowledgement", acknowledgement: { ...serverUpdate.update.acknowledgement, peerId },
        } })
        break

      case "newMessage": {
        const message = msgs.get(serverUpdate.update.newMessage.msgId)
        if (!message) {
          logMissingMessage("newMessage", {
            chatId,
            msgId: serverUpdate.update.newMessage.msgId,
            seq: update.seq,
          })
          inflatedUpdates.push(chatSkipPts(update, chatId))
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
          logMissingMessage("editMessage", {
            chatId,
            msgId: serverUpdate.update.editMessage.msgId,
            seq: update.seq,
          })
          inflatedUpdates.push(chatSkipPts(update, chatId))
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
        const payload = serverUpdate.update.messageAttachment
        const attachmentId = safePositiveId(payload.attachmentId)
        const messageId = safePositiveId(payload.msgId)
        if (payload.chatId !== BigInt(chatId) || attachmentId === undefined || messageId === undefined) {
          log.warn("Skipping malformed message attachment replay reference", {
            bucketChatId: chatId,
            payloadChatId: String(payload.chatId),
            messageId: String(payload.msgId),
            attachmentId: String(payload.attachmentId),
            seq: update.seq,
          })
          inflatedUpdates.push(chatSkipPts(update, chatId))
          break
        }

        const storedAttachment = fetchedAttachmentById.get(attachmentId)
        if (
          storedAttachment !== undefined &&
          (storedAttachment.message?.chatId !== chatId || storedAttachment.message.messageId !== messageId)
        ) {
          log.warn("Skipping message attachment replay reference with mismatched ownership", {
            bucketChatId: chatId,
            payloadMessageId: messageId,
            attachmentId,
            ownerChatId: storedAttachment.message?.chatId,
            ownerMessageId: storedAttachment.message?.messageId,
            seq: update.seq,
          })
          inflatedUpdates.push(chatSkipPts(update, chatId))
          break
        }
        if (corruptAttachmentIds.has(attachmentId)) {
          inflatedUpdates.push(chatSkipPts(update, chatId))
          break
        }

        const attachment: MessageAttachment =
          attachments.get(attachmentId) ?? {
            id: payload.attachmentId,
            attachment: { oneofKind: undefined },
          }

        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "messageAttachment",
            messageAttachment: {
              messageId: payload.msgId,
              chatId: payload.chatId,
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
        const participantUserId = safePositiveId(serverUpdate.update.participantAdd.participant?.userId)
        if (
          serverUpdate.update.participantAdd.chatId !== BigInt(chatId) ||
          participantUserId === undefined ||
          !validParticipantUserIds.has(participantUserId)
        ) {
          log.warn("Skipping malformed participantAdd replay reference", {
            bucketChatId: chatId,
            payloadChatId: String(serverUpdate.update.participantAdd.chatId),
            participantUserId: String(serverUpdate.update.participantAdd.participant?.userId ?? 0),
            seq: update.seq,
          })
          inflatedUpdates.push(chatSkipPts(update, chatId))
          break
        }
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

      case "participantGroupDelete":
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "participantGroupDelete",
            participantGroupDelete: {
              chatId: serverUpdate.update.participantGroupDelete.chatId,
              groupId: serverUpdate.update.participantGroupDelete.groupId,
            },
          },
        })
        break

      case "participantGroupAdd":
        const participantGroupId = safePositiveId(
          serverUpdate.update.participantGroupAdd.groupParticipant?.groupId,
        )
        if (
          serverUpdate.update.participantGroupAdd.chatId !== BigInt(chatId) ||
          participantGroupId === undefined ||
          !validParticipantGroupIds.has(participantGroupId)
        ) {
          log.warn("Skipping malformed participantGroupAdd replay reference", {
            bucketChatId: chatId,
            payloadChatId: String(serverUpdate.update.participantGroupAdd.chatId),
            participantGroupId: String(serverUpdate.update.participantGroupAdd.groupParticipant?.groupId ?? 0),
            seq: update.seq,
          })
          inflatedUpdates.push(chatSkipPts(update, chatId))
          break
        }
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "participantGroupAdd",
            participantGroupAdd: {
              chatId: serverUpdate.update.participantGroupAdd.chatId,
              groupParticipant: serverUpdate.update.participantGroupAdd.groupParticipant,
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
          inflatedUpdates.push(chatSkipPts(update, chatId))
          break
        }
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "newChat",
            newChat: {
              chat: encodedChat,
              user:
                serverUpdate.update.newChat.idOnlyUserForId === BigInt(userId) && peerUser
                  ? { id: peerUser.id, min: true }
                  : peerUser,
            },
          },
        })
        break

      case "chatMoved":
        if (!chatRecord) {
          log.warn("Skipping chatMoved update due to missing chat record", { chatId })
          inflatedUpdates.push(chatSkipPts(update, chatId))
          break
        }
        inflatedUpdates.push({
          seq: update.seq,
          date: encodeDateStrict(update.date),
          update: {
            oneofKind: "chatMoved",
            chatMoved: {
              chat: encodedChat,
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
              agentContext: serverUpdate.update.chatInfo.agentContext,
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

      case "spaceRemoveMember":
      case "spaceMemberUpdate":
      case "spaceMemberAdd":
      case "spaceClearHistory":
      case "spaceProfile":
      case "spaceSettings":
      case "userSpaceMemberDelete":
      case "userChatParticipantDelete":
      case "userChatParticipantAdd":
      case "userDialogArchived":
      case "userJoinSpace":
      case "userReadMaxId":
      case "userMarkAsUnread":
      case "userDialogNotificationSettings":
      case "userChatOpen":
      case "userMessageActionInvoked":
      case "userMessageActionAnswered":
      case "userDialogTranslation":
      case "userDialogFollowMode":
      case "userDialogCollapsedMaxId":
      case "updatedUser":
      case "userChatParticipantGroupAdd":
      case "userChatParticipantGroupDelete":
      case "userAddedToChat":
      case "userRemovedFromChat":
      case "userChatPermissions":
      case "userSettings":
      case "userDialogFolder":
      case "reaction":
      case "reactionDeleted":
        inflatedUpdates.push(chatSkipPts(update, chatId))
        break
      case undefined:
        log.warn("Skipping unknown durable chat update", { chatId, seq: update.seq })
        inflatedUpdates.push(chatSkipPts(update, chatId))
        break
      default:
        assertNever(serverUpdate.update)
    }
  }

  return { updates: inflatedUpdates }
}

const chatSkipPts = (update: DecryptedUpdate, chatId: number): Update => ({
  seq: update.seq,
  date: encodeDateStrict(update.date),
  update: {
    oneofKind: "chatSkipPts",
    chatSkipPts: {
      chatId: BigInt(chatId),
    },
  },
})

const assertNever = (value: never): never => {
  throw new Error(`Unhandled lossless sync update: ${JSON.stringify(value)}`)
}

const emptySidecars = (): UpdateSidecars => ({
  users: [],
  chats: [],
  dialogs: [],
  spaces: [],
  userGroups: [],
})

type SpaceSidecarsForUpdatesInput = {
  spaceId: number
  updates: Update[]
  userId: number
}

async function buildSpaceSidecarsForUpdates(input: SpaceSidecarsForUpdatesInput): Promise<UpdateSidecars> {
  if (input.updates.length === 0) {
    return emptySidecars()
  }

  const userIds = new Set<number>()
  for (const update of input.updates) {
    switch (update.update.oneofKind) {
      case "spaceMemberAdd":
        addSafeId(userIds, update.update.spaceMemberAdd.member?.userId)
        break
      case "spaceMemberUpdate":
        addSafeId(userIds, update.update.spaceMemberUpdate.member?.userId)
        break
      default:
        break
    }
  }

  const encodedUsers: User[] = []
  if (userIds.size > 0) {
    const rows = await UsersModel.getUsersWithPhotos(Array.from(userIds))
    for (const row of rows) {
      encodedUsers.push(Encoders.user({ user: row.user, photoFile: row.photoFile, min: true }))
    }
  }

  const [space] = await db.select().from(spaces).where(eq(spaces.id, input.spaceId)).limit(1)

  return {
    users: encodedUsers,
    chats: [],
    dialogs: [],
    spaces: space ? [Encoders.space(space, { encodingForUserId: input.userId })] : [],
    userGroups: [],
  }
}

type ChatSidecarsForUpdatesInput = {
  chatId: number
  updates: Update[]
  userId: number
}

async function buildChatSidecarsForUpdates(input: ChatSidecarsForUpdatesInput): Promise<UpdateSidecars> {
  const users = new Map<string, User>()
  const chatMap = new Map<string, ProtocolChat>()
  const dialogMap = new Map<string, Dialog>()
  const spaceMap = new Map<string, ProtocolSpace>()
  const userGroupMap = new Map<string, ProtocolUserGroup>()
  const userIds = new Set<number>()
  const structuralUserIds = new Set<number>()
  const idOnlyUserIds = new Set<number>()
  const chatIds = new Set<number>()
  const spaceIds = new Set<number>()
  const groupIds = new Set<number>()

  if (input.updates.length === 0) {
    return emptySidecars()
  }

  const [primaryChat] = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1)
  if (!primaryChat) {
    log.warn("Failed to find chat for delivered update sidecars", { chatId: input.chatId })
  } else {
    collectChatSidecarRefs(primaryChat, input.userId, { chatIds, userIds: structuralUserIds, spaceIds })
  }

  for (const update of input.updates) {
    switch (update.update.oneofKind) {
      case "acknowledgement":
        if (!update.update.acknowledgement.cleared) {
          addSafeId(userIds, update.update.acknowledgement.userId)
        }
        break

      case "newMessage":
        collectMessageSidecarRefs(update.update.newMessage.message, { chatIds, userIds, spaceIds })
        break

      case "editMessage":
        collectMessageSidecarRefs(update.update.editMessage.message, { chatIds, userIds, spaceIds })
        break

      case "newChat":
        collectProtocolChatSidecarRefs(update.update.newChat.chat, {
          chatIds,
          userIds: structuralUserIds,
          spaceIds,
        })
        if (isIdOnlyUser(update.update.newChat.user)) {
          idOnlyUserIds.add(Number(update.update.newChat.user.id))
        }
        break

      case "chatMoved":
        collectProtocolChatSidecarRefs(update.update.chatMoved.chat, { chatIds, userIds, spaceIds })
        break

      case "participantGroupAdd":
        chatIds.add(input.chatId)
        addSafeId(groupIds, update.update.participantGroupAdd.groupParticipant?.groupId)
        break

      case "participantAdd":
        chatIds.add(input.chatId)
        addSafeId(userIds, update.update.participantAdd.participant?.userId)
        break

      default:
        break
    }
  }

  const groupSidecars = await getSidecarUserGroups(groupIds, input.userId)
  for (const group of groupSidecars.groups) {
    userGroupMap.set(String(group.id), group)
  }
  for (const userId of groupSidecars.userIds) {
    userIds.add(userId)
  }

  const candidateChatRows = await getSidecarChats(primaryChat, chatIds)
  const accessibleChatIds = await getAccessibleReplayChatIds(
    candidateChatRows.map((chat) => chat.id),
    input.userId,
  )
  const chatRows = candidateChatRows.filter((chat) => accessibleChatIds.has(chat.id))
  // Parent and payload references are dependencies, not authority. Rebuild
  // Space enrichment only from chats the requester can still access.
  spaceIds.clear()
  const encodedChats = await Encoders.chatsForUser(chatRows, { encodingForUserId: input.userId })
  for (const [index, chat] of chatRows.entries()) {
    collectChatSidecarRefs(chat, input.userId, { chatIds, userIds: structuralUserIds, spaceIds })
    const encoded = encodedChats[index]
    if (!encoded) {
      continue
    }
    chatMap.set(String(encoded.id), encoded)
  }

  const sidecarChatIds = chatRows.map((chat) => chat.id)
  if (sidecarChatIds.length > 0) {
    const dialogRows = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.userId, input.userId), inArray(dialogs.chatId, sidecarChatIds)))
    const unreadCounts = await DialogsModel.getBatchUnreadCounts({
      userId: input.userId,
      chatIds: dialogRows.map((dialog) => dialog.chatId),
    })
    const unreadCountByChatId = new Map(unreadCounts.map((row) => [row.chatId, row.unreadCount]))

    for (const dialog of dialogRows) {
      const encoded = Encoders.dialog(dialog, { unreadCount: unreadCountByChatId.get(dialog.chatId) ?? 0 })
      dialogMap.set(String(encoded.chatId), encoded)
    }
  }

  for (const userId of structuralUserIds) {
    if (!idOnlyUserIds.has(userId)) {
      userIds.add(userId)
    }
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
    dialogs: Array.from(dialogMap.values()),
    spaces: Array.from(spaceMap.values()),
    userGroups: Array.from(userGroupMap.values()),
  }
}

type UserSidecarsForUpdatesInput = {
  updates: Update[]
  userId: number
}

async function buildUserSidecarsForUpdates(input: UserSidecarsForUpdatesInput): Promise<UpdateSidecars> {
  const users = new Map<string, User>()
  const chatMap = new Map<string, ProtocolChat>()
  const dialogMap = new Map<string, Dialog>()
  const spaceMap = new Map<string, ProtocolSpace>()
  const userGroupMap = new Map<string, ProtocolUserGroup>()
  const userIds = new Set<number>()
  const chatIds = new Set<number>()
  const spaceIds = new Set<number>()
  const groupIds = new Set<number>()
  const dmPeerUserIds = new Set<number>()
  const peerRefs = { chatIds, userIds, spaceIds, dmPeerUserIds }

  if (input.updates.length === 0) {
    return emptySidecars()
  }

  for (const update of input.updates) {
    switch (update.update.oneofKind) {
      case "userAddedToChat":
        addSafeId(chatIds, update.update.userAddedToChat.chatId)
        addSafeId(userIds, update.update.userAddedToChat.participant?.userId)
        addSafeId(groupIds, update.update.userAddedToChat.group?.groupId)
        break

      case "userRemovedFromChat":
        addSafeId(chatIds, update.update.userRemovedFromChat.chatId)
        break

      case "participantAdd":
        addSafeId(chatIds, update.update.participantAdd.chatId)
        addSafeId(userIds, update.update.participantAdd.participant?.userId)
        break

      case "participantDelete":
        addSafeId(chatIds, update.update.participantDelete.chatId)
        break

      case "participantGroupAdd":
        addSafeId(chatIds, update.update.participantGroupAdd.chatId)
        addSafeId(groupIds, update.update.participantGroupAdd.groupParticipant?.groupId)
        break

      case "participantGroupDelete":
        addSafeId(chatIds, update.update.participantGroupDelete.chatId)
        break

      case "joinSpace":
        userIds.add(input.userId)
        break

      case "dialogArchived":
        collectPeerSidecarRefs(update.update.dialogArchived.peerId, peerRefs)
        break

      case "updateReadMaxId":
        collectPeerSidecarRefs(update.update.updateReadMaxId.peerId, peerRefs)
        break

      case "markAsUnread":
        collectPeerSidecarRefs(update.update.markAsUnread.peerId, peerRefs)
        break

      case "dialogNotificationSettings":
        collectPeerSidecarRefs(update.update.dialogNotificationSettings.peerId, peerRefs)
        break

      case "dialogTranslation":
        collectPeerSidecarRefs(update.update.dialogTranslation.peerId, peerRefs)
        break

      case "dialogFollowMode":
        collectPeerSidecarRefs(update.update.dialogFollowMode.peerId, peerRefs)
        break

      case "dialogCollapsedMaxId":
        collectPeerSidecarRefs(update.update.dialogCollapsedMaxId.peerId, peerRefs)
        break

      case "dialogFolder":
        for (const dialog of update.update.dialogFolder.dialogs) {
          collectPeerSidecarRefs(dialog.peer, peerRefs)
        }
        break

      case "chatOpen":
        collectProtocolChatSidecarRefs(update.update.chatOpen.chat, { chatIds, userIds, spaceIds })
        break

      case "chatPermissions":
        addSafeId(chatIds, update.update.chatPermissions.chatId)
        break

      default:
        break
    }
  }

  if (dmPeerUserIds.size > 0) {
    // User-bucket dialog updates name DMs by peer, not Chat ID. Resolve only
    // this delivered page's peer pairs; profile dependencies are not DM work.
    const peerIds = Array.from(dmPeerUserIds)
    const dmRows = await db.select({ id: chats.id }).from(chats).where(and(
      eq(chats.type, "private"),
      or(
        and(eq(chats.minUserId, input.userId), inArray(chats.maxUserId, peerIds)),
        and(eq(chats.maxUserId, input.userId), inArray(chats.minUserId, peerIds)),
      ),
    ))
    for (const chat of dmRows) chatIds.add(chat.id)
  }

  const groupSidecars = await getSidecarUserGroups(groupIds, input.userId)
  for (const group of groupSidecars.groups) {
    userGroupMap.set(String(group.id), group)
  }
  for (const userId of groupSidecars.userIds) {
    userIds.add(userId)
  }

  const candidateChatRows = await getSidecarChats(undefined, chatIds)
  const accessibleChatIds = await getAccessibleReplayChatIds(candidateChatRows.map((chat) => chat.id), input.userId)
  const chatRows = candidateChatRows.filter((chat) => accessibleChatIds.has(chat.id))
  // Historical chatOpen payloads are not authority to enrich their old Space
  // with current metadata; rebuild Space references from admitted chats only.
  spaceIds.clear()
  const encodedChats = await Encoders.chatsForUser(chatRows, { encodingForUserId: input.userId })
  for (const [index, chat] of chatRows.entries()) {
    collectChatSidecarRefs(chat, input.userId, { chatIds, userIds, spaceIds })
    const encoded = encodedChats[index]
    if (!encoded) {
      continue
    }
    chatMap.set(String(encoded.id), encoded)
  }

  const sidecarChatIds = chatRows.map((chat) => chat.id)
  if (sidecarChatIds.length > 0) {
    const dialogRows = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.userId, input.userId), inArray(dialogs.chatId, sidecarChatIds)))
    const unreadCounts = await DialogsModel.getBatchUnreadCounts({
      userId: input.userId,
      chatIds: dialogRows.map((dialog) => dialog.chatId),
    })
    const unreadCountByChatId = new Map(unreadCounts.map((row) => [row.chatId, row.unreadCount]))

    for (const dialog of dialogRows) {
      const encoded = Encoders.dialog(dialog, { unreadCount: unreadCountByChatId.get(dialog.chatId) ?? 0 })
      dialogMap.set(String(encoded.chatId), encoded)
    }
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
    dialogs: Array.from(dialogMap.values()),
    spaces: Array.from(spaceMap.values()),
    userGroups: Array.from(userGroupMap.values()),
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

function collectPeerSidecarRefs(peer: Peer | undefined, refs: ChatSidecarRefs & { dmPeerUserIds?: Set<number> }) {
  switch (peer?.type.oneofKind) {
    case "chat":
      addSafeId(refs.chatIds, peer.type.chat.chatId)
      break
    case "user":
      addSafeId(refs.userIds, peer.type.user.userId)
      if (refs.dmPeerUserIds) addSafeId(refs.dmPeerUserIds, peer.type.user.userId)
      break
    case undefined:
      break
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

function safePositiveId(id: bigint | number | undefined): number | undefined {
  if (id === undefined) {
    return undefined
  }

  const value = typeof id === "bigint" ? Number(id) : id
  return Number.isSafeInteger(value) && value > 0 ? value : undefined
}

function addSafeId(ids: Set<number>, id: bigint | number | undefined) {
  const value = safePositiveId(id)
  if (value !== undefined) ids.add(value)
}

async function getSidecarUserGroups(
  groupIds: Set<number>,
  currentUserId: number,
): Promise<{ groups: ProtocolUserGroup[]; userIds: Set<number> }> {
  const ids = Array.from(groupIds).filter((id) => Number.isSafeInteger(id) && id > 0)
  if (ids.length === 0) {
    return { groups: [], userIds: new Set() }
  }

  const rows = await db.select({ group: userGroups }).from(userGroups)
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, currentUserId)))
    .innerJoin(spaces, eq(spaces.id, userGroups.spaceId))
    .where(and(inArray(userGroups.id, ids), isNull(spaces.deleted)))
    .orderBy(asc(userGroups.name))
  const groupRows = rows.map((row) => row.group)
  if (groupRows.length === 0) {
    return { groups: [], userIds: new Set() }
  }

  const memberRows = await db
    .select({
      groupId: userGroupMembers.groupId,
      userId: userGroupMembers.userId,
    })
    .from(userGroups)
    .innerJoin(userGroupMembers, eq(userGroups.id, userGroupMembers.groupId))
    .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
    .innerJoin(usersTable, eq(usersTable.id, userGroupMembers.userId))
    .where(and(inArray(userGroups.id, groupRows.map((group) => group.id)), userNotDeleted()))
    .orderBy(asc(userGroupMembers.userId))

  const userIdsByGroupId = new Map<number, number[]>()
  const userIds = new Set<number>()
  for (const row of memberRows) {
    userIds.add(row.userId)
    const groupUserIds = userIdsByGroupId.get(row.groupId)
    if (groupUserIds) {
      groupUserIds.push(row.userId)
    } else {
      userIdsByGroupId.set(row.groupId, [row.userId])
    }
  }

  const groups = groupRows.map((group): ProtocolUserGroup => {
    const groupUserIds = userIdsByGroupId.get(group.id) ?? []
    return {
      id: BigInt(group.id),
      spaceId: BigInt(group.spaceId),
      name: group.name,
      description: group.description ?? undefined,
      memberCount: groupUserIds.length,
      userIds: groupUserIds.map((id) => BigInt(id)),
      currentUserIsMember: groupUserIds.includes(currentUserId),
      date: encodeDateStrict(group.date),
    }
  })

  return { groups, userIds }
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
  return inflateSpaceUpdatesPage(dbUpdates, options).updates
}

function inflateUserUpdates(dbUpdates: DbUpdate[]): Update[] {
  return inflateUserUpdatesPage(dbUpdates).updates
}

function inflateSpaceUpdatesPage(
  dbUpdates: DbUpdate[],
  options?: { sanitizeUsers?: boolean },
): InflatedUpdatesPage {
  return inflateUpdatesPage(dbUpdates, (dbUpdate) => convertSpaceUpdate(UpdatesModel.decrypt(dbUpdate), options))
}

function inflateUserUpdatesPage(dbUpdates: DbUpdate[]): InflatedUpdatesPage {
  return inflateUpdatesPage(dbUpdates, (dbUpdate) =>
    convertUserUpdate(UpdatesModel.decrypt(dbUpdate), dbUpdate.entityId),
  )
}

async function getAccessibleReplayChatIds(chatIds: number[], userId: number): Promise<Set<number>> {
  if (chatIds.length === 0) return new Set()
  const access = await db.transaction(
    (tx) => getEffectiveChatAccessUserIds(tx, chatIds, { userIds: [userId] }),
    { accessMode: "read only" },
  )
  return new Set(Array.from(access).flatMap(([chatId, users]) => users.has(userId) ? [chatId] : []))
}

type ReplayChatAccessRef = {
  chatId: bigint
  userId?: bigint
  groupId?: bigint
  valid: boolean
}

function replayPeerIdentity(peer: Peer | undefined): { kind: "chat" | "user"; id: number } | undefined {
  switch (peer?.type.oneofKind) {
    case "chat": {
      const id = safePositiveId(peer.type.chat.chatId)
      return id === undefined ? undefined : { kind: "chat", id }
    }
    case "user": {
      const id = safePositiveId(peer.type.user.userId)
      return id === undefined ? undefined : { kind: "user", id }
    }
    case undefined:
      return undefined
  }
}

function replayChatAccessRef(update: Update): ReplayChatAccessRef | undefined {
  switch (update.update.oneofKind) {
    case "chatOpen": {
      const opened = update.update.chatOpen
      const chatId = safePositiveId(opened.chat?.id)
      const chatPeer = replayPeerIdentity(opened.chat?.peerId)
      const dialogPeer = replayPeerIdentity(opened.dialog?.peer)
      const dialogChatId = safePositiveId(opened.dialog?.chatId)
      const peerMatches = chatPeer !== undefined && dialogPeer !== undefined &&
        chatPeer.kind === dialogPeer.kind && chatPeer.id === dialogPeer.id
      const threadIdentityMatches = chatPeer?.kind !== "chat" || chatPeer.id === chatId
      const spaceMatches = opened.chat?.spaceId === opened.dialog?.spaceId
      const userMatches = opened.user === undefined ||
        (chatPeer?.kind === "user" && safePositiveId(opened.user.id) === chatPeer.id)
      return {
        chatId: BigInt(chatId ?? 0),
        valid: chatId !== undefined && dialogChatId === chatId && peerMatches &&
          threadIdentityMatches && spaceMatches && userMatches,
      }
    }
    case "userAddedToChat": {
      const added = update.update.userAddedToChat
      return { chatId: added.chatId, userId: added.participant?.userId, groupId: added.group?.groupId, valid: true }
    }
    case "participantAdd": {
      const added = update.update.participantAdd
      return { chatId: added.chatId, userId: added.participant?.userId, valid: added.participant !== undefined }
    }
    case "participantGroupAdd": {
      const added = update.update.participantGroupAdd
      return { chatId: added.chatId, groupId: added.groupParticipant?.groupId, valid: added.groupParticipant !== undefined }
    }
    default:
      return undefined
  }
}

/** Access-bearing replay must be complete and currently authorized. Obsolete
 * grants and snapshots are accounted without reviving private cached state. */
async function prepareUserUpdatesPage(dbUpdates: DbUpdate[], userId: number): Promise<InflatedUpdatesPage> {
  const page = inflateUserUpdatesPage(dbUpdates)
  const ids = new Set<number>()
  const userIds = new Set<number>()
  const groupIds = new Set<number>()
  for (const update of page.updates) {
    const ref = replayChatAccessRef(update)
    addSafeId(ids, ref?.chatId)
    addSafeId(userIds, ref?.userId)
    addSafeId(groupIds, ref?.groupId)
  }
  const accessible = await getAccessibleReplayChatIds(Array.from(ids), userId)
  const validUsers = new Set<string>()
  const validGroups = new Set<string>()
  if (ids.size > 0 && userIds.size > 0) {
    const rows = await db.select({ chatId: chatParticipants.chatId, userId: chatParticipants.userId })
      .from(chatParticipants)
      .innerJoin(chats, eq(chats.id, chatParticipants.chatId))
      .innerJoin(usersTable, eq(usersTable.id, chatParticipants.userId))
      .leftJoin(members, and(eq(members.userId, chatParticipants.userId), eq(members.spaceId, chats.spaceId)))
      .where(and(
        inArray(chatParticipants.chatId, Array.from(ids)), inArray(chatParticipants.userId, Array.from(userIds)), userNotDeleted(),
        or(isNull(chats.spaceId), eq(members.userId, chatParticipants.userId)),
      ))
    for (const row of rows) validUsers.add(`${row.chatId}:${row.userId}`)
  }
  if (ids.size > 0 && groupIds.size > 0) {
    const rows = await db.select({ chatId: chatParticipantGroups.chatId, groupId: chatParticipantGroups.groupId })
      .from(chatParticipantGroups)
      .innerJoin(chats, eq(chats.id, chatParticipantGroups.chatId))
      .innerJoin(userGroups, and(eq(userGroups.id, chatParticipantGroups.groupId), eq(userGroups.spaceId, chats.spaceId)))
      .where(and(
        inArray(chatParticipantGroups.chatId, Array.from(ids)), inArray(chatParticipantGroups.groupId, Array.from(groupIds)),
        or(eq(chats.publicThread, false), isNull(chats.publicThread)),
      ))
    for (const row of rows) validGroups.add(`${row.chatId}:${row.groupId}`)
  }
  const updates: Update[] = []
  for (const update of page.updates) {
    const ref = replayChatAccessRef(update)
    const validUser = ref?.userId === undefined || validUsers.has(`${ref.chatId}:${ref.userId}`)
    const validGroup = ref?.groupId === undefined || validGroups.has(`${ref.chatId}:${ref.groupId}`)
    if (ref !== undefined && ref.valid && accessible.has(Number(ref.chatId)) && update.update.oneofKind === "userAddedToChat") {
      // Access may now come from a different grant. Preserve chat discovery,
      // but never resurrect an obsolete optional participant/group edge.
      updates.push({ ...update, update: { oneofKind: "userAddedToChat", userAddedToChat: {
        ...update.update.userAddedToChat,
        participant: validUser ? update.update.userAddedToChat.participant : undefined,
        group: validGroup ? update.update.userAddedToChat.group : undefined,
      } } })
    } else if (ref === undefined || (ref.valid && accessible.has(Number(ref.chatId)) && validUser && validGroup)) {
      updates.push(update)
    } else {
      if (!ref.valid && update.update.oneofKind === "chatOpen") {
        const decision = malformedUserReplayLogs.record("chatOpen")
        if (decision.emit) {
          log.warn("Accounting malformed durable user replay envelope", {
            updateKind: "chatOpen",
            sampleSeq: String(update.seq ?? 0),
            suppressedCount: decision.suppressedCount,
          })
        }
      }
      page.skippedSequences.push({
        seq: BigInt(update.seq ?? 0),
        reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
      })
    }
  }
  return { updates, skippedSequences: page.skippedSequences }
}

function inflateUpdatesPage(
  dbUpdates: DbUpdate[],
  convert: (dbUpdate: DbUpdate) => Update | null,
): InflatedUpdatesPage {
  const updates: Update[] = []
  const skippedSequences: SyncSkippedSequence[] = []
  for (const dbUpdate of dbUpdates) {
    const update = convert(dbUpdate)
    if (update) {
      updates.push(update)
    } else {
      skippedSequences.push({
        seq: BigInt(dbUpdate.seq),
        reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
      })
    }
  }
  return { updates, skippedSequences }
}

function convertSpaceUpdate(update: DecryptedUpdate, options?: { sanitizeUsers?: boolean }): Update | null {
  const seq = update.seq
  const date = encodeDateStrict(update.date)
  const payload = update.payload.update

  switch (payload.oneofKind) {
    case "spaceRemoveMember":
      return {
        seq,
        date,
        update: {
          oneofKind: "spaceMemberDelete",
          spaceMemberDelete: {
            spaceId: payload.spaceRemoveMember.spaceId,
            userId: payload.spaceRemoveMember.userId,
            memberId: payload.spaceRemoveMember.memberId,
          },
        },
      }
    case "spaceMemberUpdate":
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
    case "spaceMemberAdd": {
      const user = options?.sanitizeUsers
        ? sanitizeUser(payload.spaceMemberAdd.user)
        : payload.spaceMemberAdd.user
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
    case "spaceClearHistory":
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
    case "spaceProfile": {
      const profile = payload.spaceProfile
      return { seq, date, update: { oneofKind: "spaceProfile", spaceProfile: {
        ...profile,
        photoUrl: profile.photoFileUniqueId ? getSignedMediaFileProxyUrl(profile.photoFileUniqueId) ?? undefined : undefined,
      } } }
    }
    case "spaceSettings":
      return {
        seq,
        date,
        update: {
          oneofKind: "spaceSettings",
          spaceSettings: {
            spaceId: payload.spaceSettings.settings?.spaceId ?? BigInt(update.entityId),
            settings: payload.spaceSettings.settings,
          },
        },
      }
    case "newMessage":
    case "editMessage":
    case "deleteMessages":
    case "deleteChat":
    case "participantDelete":
    case "participantAdd":
    case "newChat":
    case "chatVisibility":
    case "chatInfo":
    case "pinnedMessages":
    case "chatMoved":
    case "reaction":
    case "reactionDeleted":
    case "acknowledgement":
    case "userSpaceMemberDelete":
    case "userChatParticipantDelete":
    case "userChatParticipantAdd":
    case "userDialogArchived":
    case "userJoinSpace":
    case "userReadMaxId":
    case "userMarkAsUnread":
    case "userDialogNotificationSettings":
    case "userChatOpen":
    case "userMessageActionInvoked":
    case "userMessageActionAnswered":
    case "clearChatHistory":
    case "messageAttachment":
    case "userDialogTranslation":
    case "userDialogFollowMode":
    case "userDialogCollapsedMaxId":
    case "updatedUser":
    case "participantGroupAdd":
    case "participantGroupDelete":
    case "userChatParticipantGroupAdd":
    case "userChatParticipantGroupDelete":
    case "userAddedToChat":
    case "userRemovedFromChat":
    case "userChatPermissions":
    case "userSettings":
    case "userDialogFolder":
      return null
    case undefined:
      log.warn("Skipping unknown durable space update", { spaceId: update.entityId, seq: update.seq })
      return null
    default:
      return assertNever(payload)
  }
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

function isIdOnlyUser(user: User | undefined): user is User {
  if (!user || user.min !== true) {
    return false
  }

  return Object.entries(user).every(
    ([key, value]) => value === undefined || key === "id" || key === "min",
  )
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

    case "userChatParticipantGroupDelete":
      return {
        seq,
        date,
        update: {
          oneofKind: "participantGroupDelete",
          participantGroupDelete: {
            chatId: payload.userChatParticipantGroupDelete.chatId,
            groupId: payload.userChatParticipantGroupDelete.groupId,
          },
        },
      }

    case "userChatParticipantGroupAdd":
      return {
        seq,
        date,
        update: {
          oneofKind: "participantGroupAdd",
          participantGroupAdd: {
            chatId: payload.userChatParticipantGroupAdd.chatId,
            groupParticipant: payload.userChatParticipantGroupAdd.groupParticipant,
          },
        },
      }

    case "userAddedToChat":
      return {
        seq,
        date,
        update: {
          oneofKind: "userAddedToChat",
          userAddedToChat: payload.userAddedToChat,
        },
      }

    case "userRemovedFromChat":
      return {
        seq,
        date,
        update: {
          oneofKind: "userRemovedFromChat",
          userRemovedFromChat: payload.userRemovedFromChat,
        },
      }

    case "userChatPermissions":
      return {
        seq,
        date,
        update: {
          oneofKind: "chatPermissions",
          chatPermissions: {
            chatId: payload.userChatPermissions.chatId,
            permissions: payload.userChatPermissions.permissions,
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
            space: payload.userJoinSpace.space ? {
              ...payload.userJoinSpace.space,
              photoUrl: payload.userJoinSpace.space.photoFileUniqueId
                ? getSignedMediaFileProxyUrl(payload.userJoinSpace.space.photoFileUniqueId) ?? undefined
                : undefined,
            } : undefined,
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

    case "userDialogTranslation":
      return {
        seq,
        date,
        update: {
          oneofKind: "dialogTranslation",
          dialogTranslation: payload.userDialogTranslation,
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

    case "userDialogCollapsedMaxId":
      return {
        seq,
        date,
        update: {
          oneofKind: "dialogCollapsedMaxId",
          dialogCollapsedMaxId: {
            peerId: payload.userDialogCollapsedMaxId.peerId,
            maxId: payload.userDialogCollapsedMaxId.maxId,
          },
        },
      }

    case "updatedUser":
      return {
        seq,
        date,
        update: {
          oneofKind: "updatedUser",
          updatedUser: {
            user: payload.updatedUser.user,
          },
        },
      }

    case "userSettings":
      return {
        seq,
        date,
        update: {
          oneofKind: "updateUserSettings",
          updateUserSettings: {
            settings: payload.userSettings.settings,
          },
        },
      }

    case "userDialogFolder":
      return {
        seq,
        date,
        update: {
          oneofKind: "dialogFolder",
          dialogFolder: {
            folderChange: payload.userDialogFolder.folderChange,
            dialogs: payload.userDialogFolder.dialogs,
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

    case "newMessage":
    case "editMessage":
    case "deleteMessages":
    case "deleteChat":
    case "participantDelete":
    case "participantAdd":
    case "newChat":
    case "chatVisibility":
    case "chatInfo":
    case "pinnedMessages":
    case "chatMoved":
    case "reaction":
    case "reactionDeleted":
    case "acknowledgement":
    case "spaceRemoveMember":
    case "spaceMemberUpdate":
    case "spaceMemberAdd":
    case "spaceClearHistory":
    case "spaceProfile":
    case "spaceSettings":
    case "clearChatHistory":
    case "messageAttachment":
    case "participantGroupAdd":
    case "participantGroupDelete":
      return null
    case undefined:
      log.warn("Skipping unknown durable user update", { userId, seq: decrypted.seq })
      return null
    default:
      return assertNever(payload)
  }
}
