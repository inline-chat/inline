import { chatTitleFields } from "@in/server/modules/encryption/chatTitleStorage"
import { db } from "@in/server/db"
import { chats, chatParticipants, userNotDeleted, users, type DbChat, type DbDialog } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import {
  getAnchorMessageForChat,
  getDialogForUser,
  buildDefaultReplyThreadTitle,
  ensureLinkedSubthreadDialogs,
  isSubthreadParentMessage,
  persistMessageRepliesUpdate,
  pushMessageRepliesUpdate,
} from "@in/server/modules/subthreads"
import {
  DIALOG_FOLLOWING,
  setDialogFollowModeForUsers,
} from "@in/server/modules/dialogFollow"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { Transaction } from "@in/server/db/types"
import type { AgentThreadContext, Chat, Dialog, Message } from "@inline-chat/protocol/core"
import { allocateThreadNumber } from "@in/server/modules/threadNumbers"
import { and, eq, inArray } from "drizzle-orm"
import { queueReplyThreadGraphMaterialization } from "@in/server/modules/threadGraph"
import { encodeAgentThreadContext, validateAgentThreadContext } from "@in/server/modules/agentConfiguration"
import { initializeInvitedDialogs } from "@in/server/modules/dialogInvitations"
import { getBotUserIdsForChatScope, getPublicSpaceBotUserIds } from "@in/server/functions/bot.peerDiscovery"
import {
  chatCreationIntentHash,
  lockChatCreationReservation,
  claimChatCreationReservation,
} from "@in/server/modules/chatCreationReservation"
import { getEffectiveChatAccessUserIds, lockChatAndAncestors } from "@in/server/modules/authorization/chatAccessProjection"

type Input = {
  parentChatId: bigint
  parentMessageId?: bigint
  title?: string
  description?: string
  emoji?: string
  participants?: { userId: bigint }[]
  agentContext?: AgentThreadContext
  reservedChatId?: bigint
}

type Output = {
  chat: Chat
  dialog?: Dialog
  anchorMessage?: Message
}

type InitialParticipant = {
  chatId: number
  userId: number
  date: Date
}

export async function createSubthread(input: Input, context: FunctionContext): Promise<Output> {
  const parentChatId = Number(input.parentChatId)
  if (!Number.isSafeInteger(parentChatId) || parentChatId <= 0) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  const parentMessageId = input.parentMessageId !== undefined ? Number(input.parentMessageId) : undefined
  if (parentMessageId !== undefined && (!Number.isSafeInteger(parentMessageId) || parentMessageId <= 0)) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  const reservedChatId = input.reservedChatId !== undefined ? Number(input.reservedChatId) : undefined
  if (reservedChatId !== undefined && (!Number.isSafeInteger(reservedChatId) || reservedChatId <= 0)) {
    throw RealtimeRpcError.BadRequest()
  }

  const directParticipantUserIds = uniquePositiveUserIds(input.participants ?? [])
  const explicitTitle = normalizeOptionalString(input.title)
  const description = normalizeOptionalString(input.description)
  const emoji = normalizeOptionalString(input.emoji)
  const intentHash = chatCreationIntentHash({
    method: "createSubthread",
    userId: context.currentUserId,
    parentChatId,
    parentMessageId: parentMessageId ?? null,
    title: explicitTitle ?? null,
    description: description ?? null,
    emoji: emoji ?? null,
    directParticipantUserIds: [...directParticipantUserIds].sort((a, b) => a - b),
    agentContext: input.agentContext ? Buffer.from(encodeAgentThreadContext(input.agentContext)).toString("hex") : null,
  })
  const { chat, created, parentUpdate, parentChat, anchorMessage } = await createSubthreadChat({
    parentChatId,
    parentMessageId,
    title: explicitTitle,
    description,
    emoji,
    createdBy: context.currentUserId,
    directParticipantUserIds,
    agentContext: input.agentContext,
    reservedChatId,
    intentHash,
  })

  if (!created) {
    // One anchor has one reply thread. Reuse only navigates to it; submitted
    // titles, participants and Agent settings do not mutate an existing child.
    await ensureLinkedSubthreadDialogs({ chat, userIds: [context.currentUserId], chatListHidden: true })
    if (chat.parentMessageId != null) {
      await autoFollowCreatedReplyThread({ chat, currentUserId: context.currentUserId })
    }
    if (chat.parentMessageId != null && parentChat) {
      queueReplyThreadGraphMaterialization({
        replyThread: chat,
        parentChat,
        parentMessageGlobalId: anchorMessage?.globalId ?? null,
      })
    }
    return encodeSubthreadResult({ chat, currentUserId: context.currentUserId })
  }

  const { dialogs: materializedDialogs } =
    parentMessageId !== undefined
      ? await autoFollowCreatedReplyThread({
          chat,
          currentUserId: context.currentUserId,
          anchorMessage,
        })
      : await ensureLinkedSubthreadDialogs({
          chat,
          userIds: [context.currentUserId],
          chatListHidden: true,
        })

  if (parentMessageId !== undefined && parentUpdate && parentChat) {
    await pushMessageRepliesUpdate({
      parentChatId,
      parentMessageId,
      currentUserId: context.currentUserId,
      update: parentUpdate,
    })
    queueReplyThreadGraphMaterialization({
      replyThread: chat,
      parentChat,
      parentMessageGlobalId: anchorMessage?.globalId ?? null,
    })
  }

  return encodeSubthreadResult({
    chat,
    currentUserId: context.currentUserId,
    dialog: materializedDialogs.find((dialog) => dialog.userId === context.currentUserId),
    anchorMessage,
  })
}

async function autoFollowCreatedReplyThread(input: {
  chat: DbChat
  currentUserId: number
  anchorMessage?: Awaited<ReturnType<typeof getAnchorMessageForChat>>
}): Promise<{ dialogs: DbDialog[] }> {
  const userIds = new Set<number>([input.currentUserId])

  if (input.anchorMessage?.fromId != null) {
    userIds.add(input.anchorMessage.fromId)
  }

  const { dialogs } = await setDialogFollowModeForUsers({
    chat: input.chat,
    userIds: Array.from(userIds),
    followMode: DIALOG_FOLLOWING,
    preserveUnfollowed: true,
  })

  return { dialogs }
}

async function encodeSubthreadResult(input: {
  chat: DbChat
  currentUserId: number
  dialog?: DbDialog | undefined
  anchorMessage?: Awaited<ReturnType<typeof getAnchorMessageForChat>>
}): Promise<Output> {
  const dialog = input.dialog ?? (await getDialogForUser(input.chat.id, input.currentUserId))

  const anchorMessage = input.anchorMessage ?? (await getAnchorMessageForChat(input.chat))

  return {
    chat: await Encoders.chatForUser(input.chat, { encodingForUserId: input.currentUserId }),
    dialog: dialog ? Encoders.dialog(dialog, { unreadCount: 0 }) : undefined,
    anchorMessage: anchorMessage
      ? Encoders.fullMessage({
          message: anchorMessage,
          encodingForUserId: input.currentUserId,
          encodingForPeer: {
            inputPeer: {
              type: {
                oneofKind: "chat",
                chat: { chatId: BigInt(input.chat.parentChatId ?? input.chat.id) },
              },
            },
          },
        })
      : undefined,
  }
}

type SubthreadCreationResult = {
  chat: DbChat
  created: boolean
  parentUpdate?: UpdateSeqAndDate
  parentChat?: DbChat
  anchorMessage?: Awaited<ReturnType<typeof getAnchorMessageForChat>>
}

async function createSubthreadChat(input: {
  parentChatId: number
  parentMessageId?: number
  title?: string
  description?: string
  emoji?: string
  createdBy: number
  directParticipantUserIds: number[]
  agentContext?: AgentThreadContext
  reservedChatId?: number
  intentHash: string
}): Promise<SubthreadCreationResult> {
  const result = await db.transaction(async (tx): Promise<SubthreadCreationResult & {
    participants: InitialParticipant[]
  }> => {
    const reservedChat = input.reservedChatId !== undefined
      ? await lockChatCreationReservation(tx, {
        chatId: input.reservedChatId,
        userId: input.createdBy,
        intentHash: input.intentHash,
      })
      : undefined
    if (reservedChat) {
      const parentChat = reservedChat.parentChatId == null ? undefined :
        (await tx.select().from(chats).where(eq(chats.id, reservedChat.parentChatId)).limit(1))[0]
      return {
        chat: reservedChat, participants: [], created: false, parentChat,
        anchorMessage: await getAnchorMessageForChat(reservedChat, tx),
      }
    }
    // Hold the parent and inherited authority through insertion, using the
    // same ID order as forwarding and nested placement deletion.
    // Non-key authority changes and deletion still serialize here. Allow the
    // KEY SHARE foreign-key check when a dialog writer already owns a user.
    const parent = await lockChatAndAncestors(tx, input.parentChatId, "no key update")
    if (!parent) throw RealtimeRpcError.ChatIdInvalid()
    const access = await getEffectiveChatAccessUserIds(tx, [parent.id], { userIds: [input.createdBy] })
    if (!access.get(parent.id)?.has(input.createdBy)) throw RealtimeRpcError.PeerIdInvalid()
    if (input.parentMessageId !== undefined) {
      const [existing] = await tx
        .select()
        .from(chats)
        .where(and(eq(chats.parentChatId, parent.id), eq(chats.parentMessageId, input.parentMessageId)))
        .limit(1)
      if (existing) {
        if (input.reservedChatId !== undefined) {
          await claimChatCreationReservation(tx, {
            chatId: input.reservedChatId,
            intentHash: input.intentHash,
            resolvedChatId: existing.id,
          })
        }
        return {
          chat: existing, participants: [], created: false, parentChat: parent,
          anchorMessage: await getAnchorMessageForChat(existing, tx),
        }
      }
    }

    const anchorMessage = input.parentMessageId !== undefined
      ? await getAnchorMessageForChat({ parentChatId: parent.id, parentMessageId: input.parentMessageId }, tx)
      : undefined
    if (input.parentMessageId !== undefined && !anchorMessage) throw RealtimeRpcError.MessageIdInvalid()
    if (anchorMessage && (await isSubthreadParentMessage(anchorMessage.globalId, tx))) throw RealtimeRpcError.BadRequest()
    await ensureUsersExist(input.directParticipantUserIds, tx)
    const agentContext = input.agentContext
      ? await validateAgentThreadContext(input.agentContext, { bindingActorUserId: input.createdBy, operation: "create_subthread", tx })
      : undefined
    if (agentContext) {
      const botUserId = Number(agentContext.botUserId)
      if (parent.spaceId !== null && parent.publicThread === true && !(await getPublicSpaceBotUserIds(parent.spaceId, { tx })).includes(botUserId)) {
        throw RealtimeRpcError.UserIdInvalid()
      }
      const visibleBotIds = new Set([
        ...input.directParticipantUserIds,
        ...(await getBotUserIdsForChatScope(parent, input.createdBy, undefined, { tx })),
      ])
      if (!visibleBotIds.has(botUserId)) throw RealtimeRpcError.UserIdInvalid()
    }
    const title = input.title ?? (input.parentMessageId !== undefined ? buildDefaultReplyThreadTitle(anchorMessage) : undefined)

    // Number allocation and invitation frontiers use these same user owners.
    for (const userId of Array.from(new Set([input.createdBy, ...input.directParticipantUserIds])).sort((a, b) => a - b)) {
      await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("no key update").limit(1)
    }
    const spaceId = parent.spaceId ?? null
    const threadNumber = await allocateThreadNumber(
      tx,
      spaceId !== null ? { type: "space", id: spaceId } : { type: "user", id: input.createdBy },
    )

    const [chat] = await tx
      .insert(chats)
      .values({
        ...(input.reservedChatId !== undefined ? { id: input.reservedChatId } : {}),
        type: "thread",
        spaceId,
        ...chatTitleFields(title ?? null, { spaceId, createdBy: input.createdBy }),
        isUntitled: input.title === undefined ? true : null,
        description: input.description ?? null,
        emoji: input.emoji ?? null,
        createdBy: input.createdBy,
        publicThread: parent.publicThread ?? false,
        parentChatId: parent.id,
        parentMessageId: input.parentMessageId ?? null,
        threadNumber,
        agentContext: agentContext ? encodeAgentThreadContext(agentContext) : null,
      })
      .returning()

    if (!chat) {
      throw RealtimeRpcError.InternalError()
    }

    let participants: InitialParticipant[] = []
    if (input.directParticipantUserIds.length > 0) {
      participants = input.directParticipantUserIds.map((userId) => ({
        chatId: chat.id,
        userId,
        date: new Date(),
      }))

      await tx.insert(chatParticipants).values(participants).onConflictDoNothing()
    }

    await initializeInvitedDialogs(tx, { chat, userIds: input.directParticipantUserIds })
    const parentUpdate =
      input.parentMessageId !== undefined
        ? await persistMessageRepliesUpdate(
            { parentChatId: parent.id, parentMessageId: input.parentMessageId },
            tx,
          )
        : undefined
    if (input.reservedChatId !== undefined) {
      await claimChatCreationReservation(tx, { chatId: input.reservedChatId, intentHash: input.intentHash })
    }

    return { chat, participants, created: true, parentUpdate, parentChat: parent, anchorMessage }
  })

  result.participants.forEach((participant) => {
    AccessGuardsCache.setChatParticipant(participant.chatId, participant.userId)
  })
  const { participants: _participants, ...creation } = result
  return creation

}

async function ensureUsersExist(userIds: number[], tx: Transaction): Promise<void> {
  if (userIds.length === 0) {
    return
  }

  const existingUsers = await tx
    .select({ id: users.id })
    .from(users)
    .where(and(inArray(users.id, userIds), userNotDeleted()))

  if (existingUsers.length !== userIds.length) {
    throw RealtimeRpcError.UserIdInvalid()
  }
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim()
  return trimmed && trimmed.length > 0 ? trimmed : undefined
}

function uniquePositiveUserIds(participants: { userId: bigint }[]): number[] {
  const result = new Set<number>()

  for (const participant of participants) {
    const userId = Number(participant.userId)
    if (!Number.isSafeInteger(userId) || userId <= 0) {
      throw RealtimeRpcError.UserIdInvalid()
    }
    result.add(userId)
  }

  return Array.from(result)
}
