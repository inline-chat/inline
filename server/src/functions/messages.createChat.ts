import { chatTitleFields, chatTitleMatches } from "@in/server/modules/encryption/chatTitleStorage"
import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { users } from "@in/server/db/schema/users"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import { Chat, Dialog, type AgentThreadContext, type ChatParticipant } from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { dialogs } from "@in/server/db/schema"
import { Update } from "@inline-chat/protocol/core"
import { getUpdateGroup } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { UpdateGroup } from "@in/server/modules/updates"
import type { DbChat, DbDialog } from "@in/server/db/schema"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UsersModel } from "@in/server/db/models/users"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"
import { ensureCanCreateSpaceThread } from "@in/server/modules/authorization/spaceThreadGuards"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { Transaction } from "@in/server/db/types"
import { allocateThreadNumber } from "@in/server/modules/threadNumbers"
import { encodeAgentThreadContext, validateAgentThreadContext } from "@in/server/modules/agentConfiguration"
import { getPublicSpaceBotUserIds } from "@in/server/functions/bot.peerDiscovery"
import {
  chatCreationIntentHash,
  lockChatCreationReservation,
  claimChatCreationReservation,
} from "@in/server/modules/chatCreationReservation"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { initializeInvitedDialogs } from "@in/server/modules/dialogInvitations"

type InitialParticipant = {
  chatId: number
  userId: number
  date: Date
}

type InitialAccessUpdate = {
  userId: number
  participant: ChatParticipant
  update: UpdateSeqAndDate
}

const PLACEHOLDER_TITLE_MAX_CHARACTERS = 60

export async function createChat(
  input: {
    title?: string
    placeholderTitle?: string
    spaceId?: bigint
    emoji?: string
    description?: string
    isPublic?: boolean
    participants?: { userId: bigint }[]
    reservedChatId?: bigint
    agentContext?: AgentThreadContext
  },
  context: FunctionContext,
): Promise<{ chat: Chat; dialog: Dialog }> {
  const hasSpaceId = input.spaceId !== undefined && input.spaceId !== null
  const spaceId = hasSpaceId ? Number(input.spaceId) : undefined
  if (hasSpaceId && (spaceId === undefined || !Number.isSafeInteger(spaceId) || spaceId <= 0)) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Space ID is invalid", 400)
  }
  const resolvedSpaceId = spaceId as number
  const reservedChatId = input.reservedChatId !== undefined ? Number(input.reservedChatId) : undefined
  if (
    input.reservedChatId !== undefined &&
    (reservedChatId === undefined || Number.isNaN(reservedChatId) || !Number.isSafeInteger(reservedChatId) || reservedChatId <= 0)
  ) {
    throw RealtimeRpcError.BadRequest()
  }

  const isPublic = input.isPublic ?? (hasSpaceId ? true : false)

  if (!hasSpaceId) {
    if (isPublic) {
      throw new RealtimeRpcError(
        RealtimeRpcError.Code.BAD_REQUEST,
        "Public home threads are not supported",
        400,
      )
    }
    if (!input.participants) {
      throw new RealtimeRpcError(
        RealtimeRpcError.Code.BAD_REQUEST,
        "Participants are required for home threads",
        400,
      )
    }
  }

  // For space threads, if it's private, participants are required
  if (hasSpaceId && isPublic === false && !input.participants) {
    throw new RealtimeRpcError(
      RealtimeRpcError.Code.BAD_REQUEST,
      "Participants are required for private space threads",
      400,
    )
  }

  // For space threads, if it's public, participants should be empty
  if (hasSpaceId && isPublic === true && input.participants && input.participants.length > 0) {
    throw new RealtimeRpcError(
      RealtimeRpcError.Code.BAD_REQUEST,
      "Participants should be empty for public space threads",
      400,
    )
  }

  // Do not mutate the submitted request: the same immutable intent can be retried.
  const participantUserIds = Array.from(new Set(input.participants?.map((p) => Number(p.userId)) ?? []))
  if (!isPublic && !participantUserIds.includes(context.currentUserId)) {
    participantUserIds.push(context.currentUserId)
  }
  participantUserIds.sort((a, b) => a - b)
  if (participantUserIds.some((id) => !Number.isSafeInteger(id) || id <= 0)) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  const explicitTitle = normalizeOptionalString(input.title)
  const placeholderTitle = normalizePlaceholderTitle(input.placeholderTitle)
  if (explicitTitle && placeholderTitle) {
    throw new RealtimeRpcError(
      RealtimeRpcError.Code.BAD_REQUEST,
      "A thread cannot have both an explicit title and a placeholder title",
      400,
    )
  }
  const storedTitle = explicitTitle ?? placeholderTitle
  const intentHash = chatCreationIntentHash({
    method: "createChat",
    userId: context.currentUserId,
    spaceId: spaceId ?? null,
    isPublic,
    title: explicitTitle ?? null,
    placeholderTitle: placeholderTitle ?? null,
    emoji: input.emoji ?? null,
    description: input.description ?? null,
    participantUserIds,
    agentContext: input.agentContext ? Buffer.from(encodeAgentThreadContext(input.agentContext)).toString("hex") : null,
  })

  let createdChat: DbChat
  let createdDialog: DbDialog
  let createdParticipants: InitialParticipant[] = []
  let initialAccessUpdates: InitialAccessUpdate[] = []
  let persistedUpdate: UpdateSeqAndDate | undefined
  try {
    ;({
      chat: createdChat,
      dialog: createdDialog,
      participants: createdParticipants,
      accessUpdates: initialAccessUpdates,
      update: persistedUpdate,
    } = await db.transaction(async (tx) => {
      if (reservedChatId !== undefined) {
        const existing = await lockChatCreationReservation(tx, {
          chatId: reservedChatId,
          userId: context.currentUserId,
          intentHash,
        })
        if (existing) {
          const [dialog] = await tx
            .select()
            .from(dialogs)
            .where(and(eq(dialogs.chatId, existing.id), eq(dialogs.userId, context.currentUserId)))
            .limit(1)
          if (!dialog) throw RealtimeRpcError.InternalError()
          return { chat: existing, dialog, participants: [], accessUpdates: [], update: undefined }
        }
      }

      // Only an unclaimed reservation performs new-creation checks. A retry
      // reconciles captured intent and current destination access above.
      if (!hasSpaceId && isPublic === false) {
        const activeUserIds = await UsersModel.getActiveUserIds(participantUserIds, { tx })
        if (activeUserIds.length !== participantUserIds.length) throw RealtimeRpcError.UserIdInvalid()
      }
      if (hasSpaceId) {
        await ensureCanCreateSpaceThread({ spaceId: resolvedSpaceId, userId: context.currentUserId, isPublic, participantUserIds }, { tx })
      }
      const agentContext = input.agentContext
        ? await validateAgentThreadContext(input.agentContext, {
            bindingActorUserId: context.currentUserId,
            operation: "create_chat",
            tx,
          })
        : undefined
      if (agentContext) {
        const botUserId = Number(agentContext.botUserId)
        if (!isPublic && !participantUserIds.includes(botUserId)) throw RealtimeRpcError.UserIdInvalid()
        if (isPublic && !(await getPublicSpaceBotUserIds(resolvedSpaceId, { tx })).includes(botUserId)) throw RealtimeRpcError.UserIdInvalid()
      }
      const encodedAgentContext = agentContext ? encodeAgentThreadContext(agentContext) : null

      // Replay is resolved before title uniqueness: a retry must also survive
      // automatic titles and later human renames without overwriting either.
      if (explicitTitle && hasSpaceId) {
        const duplicate = await tx
          .select({ id: chats.id })
          .from(chats)
          .where(
            and(
              eq(chats.type, "thread"),
              eq(chats.spaceId, resolvedSpaceId),
              chatTitleMatches(explicitTitle.toLowerCase(), { spaceId: resolvedSpaceId }),
            ),
          )
          .limit(1)

        if (duplicate.length > 0) {
          throw new RealtimeRpcError(
            RealtimeRpcError.Code.BAD_REQUEST,
            "A thread with that name already exists",
            400,
          )
        }
      }

      if (!isPublic) {
        // Creation may allocate a creator-scoped number and multiple user
        // frontiers. Own all user rows in one order before either operation.
        for (const userId of participantUserIds) {
          await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("no key update").limit(1)
        }
      }
      const threadNumber = await allocateThreadNumber(
        tx,
        hasSpaceId
          ? { type: "space", id: resolvedSpaceId }
          : { type: "user", id: context.currentUserId },
      )

      const [chat] = await tx
        .insert(chats)
        .values({
          ...(reservedChatId !== undefined ? { id: reservedChatId } : {}),
          type: "thread",
          spaceId: hasSpaceId ? resolvedSpaceId : null,
          ...chatTitleFields(storedTitle ?? null, {
            spaceId: hasSpaceId ? resolvedSpaceId : null,
            createdBy: context.currentUserId,
          }),
          isUntitled: explicitTitle ? null : true,
          publicThread: isPublic,
          date: new Date(),
          threadNumber: threadNumber,
          emoji: input.emoji ?? null,
          description: input.description ?? null,
          createdBy: context.currentUserId,
          agentContext: encodedAgentContext,
        })
        .returning()

      if (!chat) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create chat", 500)
      }

      let participants: InitialParticipant[] = []
      let accessUpdates: InitialAccessUpdate[] = []
      if (isPublic === false) {
        participants = participantUserIds.map((userId) => ({
          chatId: chat.id,
          userId,
          date: new Date(),
        }))

        await tx.insert(chatParticipants).values(participants)
        accessUpdates = await enqueueInitialParticipantAdds(
          tx,
          chat.id,
          participants,
          context.currentUserId,
        )
      }

      let [dialog] = await tx
        .insert(dialogs)
        .values({
          chatId: chat.id,
          userId: context.currentUserId,
          spaceId: hasSpaceId ? resolvedSpaceId : null,
          date: new Date(),
          ...dialogOpenDefaultsForChat(chat),
        })
        .returning()

      if (!dialog) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create dialog", 500)
      }

      if (!isPublic) {
        const invited = await initializeInvitedDialogs(tx, { chat, userIds: participantUserIds })
        dialog = invited.dialogs.find((candidate) => candidate.userId === context.currentUserId) ?? dialog
      }

      if (reservedChatId !== undefined) {
        await claimChatCreationReservation(tx, { chatId: reservedChatId, intentHash })
      }
      const update = await persistNewChatUpdate(chat.id, tx)

      return { chat, dialog, participants, accessUpdates, update }
    }))
  } catch (error) {
    Log.shared.error(`Failed to create chat: ${error}`)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create chat", 500)
  }

  createdParticipants.forEach((p) => AccessGuardsCache.setChatParticipant(p.chatId, p.userId))

  const unreadCount = persistedUpdate ? 0 : await DialogsModel.getUnreadCount(createdChat.id, context.currentUserId)
  const encodedDialog: Dialog = Encoders.dialog(createdDialog, { unreadCount })

  if (persistedUpdate) {
    await pushUpdates({ chat: createdChat, currentUserId: context.currentUserId, update: persistedUpdate })
  }
  pushInitialAccessUpdates(createdChat.id, initialAccessUpdates)

  return {
    chat: await Encoders.chatForUser(createdChat, { encodingForUserId: context.currentUserId }),
    dialog: encodedDialog,
  }
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim()
  return trimmed && trimmed.length > 0 ? trimmed : undefined
}

function normalizePlaceholderTitle(value: string | undefined): string | undefined {
  const normalized = value?.trim().replace(/\s+/g, " ")
  if (!normalized) {
    return undefined
  }
  return Array.from(normalized).slice(0, PLACEHOLDER_TITLE_MAX_CHARACTERS).join("").trim()
}

async function enqueueInitialParticipantAdds(
  tx: Transaction,
  chatId: number,
  participants: InitialParticipant[],
  currentUserId: number,
): Promise<InitialAccessUpdate[]> {
  const targets = participants.filter((participant) => participant.userId !== currentUserId)
  const updates = await UserBucketUpdates.enqueueMany(
    targets.map((participant) => ({
      userId: participant.userId,
      update: {
        oneofKind: "userAddedToChat" as const,
        userAddedToChat: {
          chatId: BigInt(chatId),
          participant: encodeParticipant(participant),
        },
      },
    })),
    { tx },
  )

  return targets.map((participant, index) => ({
    userId: participant.userId,
    participant: encodeParticipant(participant),
    update: updates[index]!,
  }))
}

function pushInitialAccessUpdates(chatId: number, accessUpdates: InitialAccessUpdate[]): void {
  for (const item of accessUpdates) {
    RealtimeUpdates.pushToUser(item.userId, [
      {
        seq: item.update.seq,
        date: encodeDateStrict(item.update.date),
        update: {
          oneofKind: "userAddedToChat",
          userAddedToChat: {
            chatId: BigInt(chatId),
            participant: item.participant,
          },
        },
      },
    ])
  }
}

function encodeParticipant(participant: InitialParticipant): ChatParticipant {
  return {
    userId: BigInt(participant.userId),
    date: encodeDateStrict(participant.date),
  }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

/** Push updates for new chat creation */
const pushUpdates = async ({
  chat,
  currentUserId,
  update,
}: {
  chat: DbChat
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  // Use getUpdateGroup with the new chat info
  const updateGroup = await getUpdateGroup({ threadId: chat.id }, { currentUserId })

  let selfUpdates: Update[] = []
  const chatsByUserId = await Encoders.chatForUsers(chat, updateGroup.userIds)

  // Broadcast to all users in the update group
  updateGroup.userIds.forEach((userId) => {
    // Prepare the update
    const newChatUpdate: Update = {
      seq: update.seq,
      date: encodeDateStrict(update.date),
      update: {
        oneofKind: "newChat",
        newChat: {
          chat: chatsByUserId.get(userId),
        },
      },
    }

    RealtimeUpdates.pushToUser(userId, [newChatUpdate])

    if (userId === currentUserId) {
      selfUpdates = [newChatUpdate]
    }
  })

  return { selfUpdates, updateGroup }
}

const persistNewChatUpdate = async (chatId: number, tx: Transaction): Promise<UpdateSeqAndDate> => {
  const chatUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "newChat",
    newChat: {
      chatId: BigInt(chatId),
    },
  }

  const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)

  if (!chat) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat not found", 404)
  }

  const update = await UpdatesModel.insertUpdate(tx, {
    update: chatUpdatePayload,
    bucket: UpdateBucket.Chat,
    entity: chat,
  })

  await tx
    .update(chats)
    .set({
      updateSeq: update.seq,
      lastUpdateDate: update.date,
    })
    .where(eq(chats.id, chatId))

  return update
}
