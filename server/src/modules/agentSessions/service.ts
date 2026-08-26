import {
  AgentSessionMessageRelation,
  AgentSessionMessageRole,
  AgentSessionMessageSyncState,
  AgentSessionProvider,
  AgentSessionSyncMode,
  ConnectAgentSessionState,
  MessageEntities,
  type AgentSession,
  type AgentSessionMessageSync,
  type AgentSessionMessageSyncResult,
  type ConnectAgentSessionInput,
  type ConnectAgentSessionResult,
  type GetAgentSessionInput,
  type GetAgentSessionResult,
  type SyncAgentSessionMessagesInput,
  type SyncAgentSessionMessagesResult,
  type Update,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UsersModel } from "@in/server/db/models/users"
import {
  agentSessionMessages,
  agentSessions,
  botMessageRoutes,
  chats,
  messages,
  spaces,
  type DbAgentSession,
  type DbChat,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { detectHasLink } from "@in/server/modules/message/linkDetection"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { sendProjectedMessageNotification } from "@in/server/functions/messages.sendMessage"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodeOutputPeerFromChat, encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { and, eq, gt, inArray, or, sql } from "drizzle-orm"
import {
  agentSessionHash,
  agentSourceHash,
  decryptAgentRef,
  decryptAgentSourceRefs,
  encryptAgentRef,
  encryptAgentSourceRefs,
  normalizeAgentSourceRefs,
  type AgentSourceRefs,
} from "./crypto"

const log = new Log("AgentSessions")
const MAX_BATCH_SIZE = 100
const MAX_MESSAGE_BYTES = 20_000
const MAX_PROJECT_REF_BYTES = 512

type AgentSessionContext = {
  session: DbAgentSession
  chat: DbChat
}

type PreparedSync = {
  input: AgentSessionMessageSync
  refs: AgentSourceRefs
  sourceKeyHash: Buffer
  itemKeyHash: Buffer | null
  sourceRefEncrypted: Buffer
  revisionRefEncrypted: Buffer | null
  revisionRef?: string
  baseRevisionRef?: string
  encryptedText?: ReturnType<typeof encryptMessage>
  encryptedEntities?: ReturnType<typeof encryptBinary>
  sourceDate?: Date
}

type ProjectedUpdate = {
  kind: "newMessage" | "editMessage"
  messageId: number
  update: UpdateSeqAndDate
  notify: boolean
}

function safePositiveNumber(value: bigint): number {
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number <= 0) throw RealtimeRpcError.BadRequest()
  return number
}

function validProvider(provider: AgentSessionProvider): boolean {
  return provider >= AgentSessionProvider.CODEX && provider <= AgentSessionProvider.AMP
}

function ensureBounded(value: string | undefined, maxBytes: number, required: boolean): string | undefined {
  const byteLength = value === undefined ? 0 : Buffer.byteLength(value, "utf8")
  if (
    (required && (value === undefined || value.trim().length === 0)) ||
    (value !== undefined && value.trim().length === 0) ||
    byteLength > maxBytes
  ) throw RealtimeRpcError.BadRequest()
  return value
}

async function ensureNotInternetPublic(chat: DbChat): Promise<void> {
  if (chat.spaceId === null) return
  const [space] = await db.select({ isPublic: spaces.isPublic }).from(spaces).where(eq(spaces.id, chat.spaceId)).limit(1)
  if (!space || space.isPublic) throw RealtimeRpcError.PeerIdInvalid()
}

async function verifiedOwnerBotChat(input: {
  chat: DbChat
  botUserId: number
  ownerUserId: number
}): Promise<void> {
  const bot = await UsersModel.getUserById(input.botUserId)
  if (!bot?.bot || bot.botCreatorId !== input.ownerUserId || UsersModel.isDeleted(bot)) {
    throw RealtimeRpcError.UserIdInvalid()
  }
  await Promise.all([
    AccessGuards.ensureChatAccess(input.chat, input.ownerUserId),
    AccessGuards.ensureChatAccess(input.chat, input.botUserId),
    ensureNotInternetPublic(input.chat),
  ])
}

async function statusMessageGlobalId(input: {
  chatId: number
  botUserId: number
  messageId?: bigint
}): Promise<bigint | undefined> {
  if (input.messageId === undefined) return undefined
  const message = await MessageModel.getMessage(safePositiveNumber(input.messageId), input.chatId)
  if (message.fromId !== input.botUserId) throw RealtimeRpcError.MessageIdInvalid()
  return message.globalId
}

async function encodeAgentSession(row: DbAgentSession, viewerUserId: number): Promise<AgentSession> {
  const [chat, statusMessage] = await Promise.all([
    db._query.chats.findFirst({ where: eq(chats.id, row.chatId) }),
    row.statusMessageGlobalId === null
      ? Promise.resolve(undefined)
      : db.select({ messageId: messages.messageId })
          .from(messages)
          .where(eq(messages.globalId, row.statusMessageGlobalId))
          .limit(1)
          .then((rows) => rows[0]),
  ])
  if (!chat) throw RealtimeRpcError.PeerIdInvalid()
  return {
    id: row.id,
    peerId: encodeOutputPeerFromChat(chat, { currentUserId: viewerUserId }),
    botUserId: BigInt(row.botUserId),
    provider: row.provider,
    statusMessageId: statusMessage ? BigInt(statusMessage.messageId) : undefined,
  }
}

export async function connectAgentSession(
  input: ConnectAgentSessionInput,
  currentUserId: number,
): Promise<ConnectAgentSessionResult> {
  if (!input.peerId || !validProvider(input.provider)) throw RealtimeRpcError.BadRequest()
  const botUserId = safePositiveNumber(input.botUserId)
  const instanceRef = ensureBounded(input.instanceRef, 512, true)!
  const sessionRef = ensureBounded(input.sessionRef, 512, true)!
  const projectRef = ensureBounded(input.projectRef, MAX_PROJECT_REF_BYTES, false)
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, { currentUserId })
  await verifiedOwnerBotChat({ chat, botUserId, ownerUserId: currentUserId })
  const statusGlobalId = await statusMessageGlobalId({
    chatId: chat.id,
    botUserId,
    messageId: input.statusMessageId,
  })
  const sessionKeyHash = agentSessionHash(input.provider, instanceRef, sessionRef)

  const result = await db.transaction(async (tx) => {
    const [external] = await tx.select().from(agentSessions).where(and(
        eq(agentSessions.botUserId, botUserId),
        eq(agentSessions.provider, input.provider),
        eq(agentSessions.sessionKeyHash, sessionKeyHash),
      )).limit(1)
    if (external) {
      if (external.ownerUserId !== currentUserId) throw RealtimeRpcError.UserIdInvalid()
      if (external.chatId !== chat.id) {
        return { row: external, state: ConnectAgentSessionState.CONNECTED_ELSEWHERE }
      }
      const [updated] = await tx
        .update(agentSessions)
        .set({
          projectRefEncrypted: projectRef ? encryptAgentRef(projectRef) : external.projectRefEncrypted,
          statusMessageGlobalId: statusGlobalId ?? external.statusMessageGlobalId,
          updatedAt: new Date(),
        })
        .where(eq(agentSessions.id, external.id))
        .returning()
      return {
        row: updated ?? external,
        state: ConnectAgentSessionState.ALREADY_CONNECTED,
      }
    }

    const [occupied] = await tx.select().from(agentSessions).where(
      and(eq(agentSessions.chatId, chat.id), eq(agentSessions.botUserId, botUserId)),
    ).limit(1)
    if (occupied) throw RealtimeRpcError.BadRequest()

    const [created] = await tx
      .insert(agentSessions)
      .values({
        chatId: chat.id,
        botUserId,
        ownerUserId: currentUserId,
        provider: input.provider,
        sessionKeyHash,
        instanceRefEncrypted: encryptAgentRef(instanceRef),
        sessionRefEncrypted: encryptAgentRef(sessionRef),
        projectRefEncrypted: projectRef ? encryptAgentRef(projectRef) : null,
        statusMessageGlobalId: statusGlobalId ?? null,
      })
      .onConflictDoNothing()
      .returning()
    if (!created) {
      const [concurrentExternal] = await tx.select().from(agentSessions).where(and(
        eq(agentSessions.botUserId, botUserId),
        eq(agentSessions.provider, input.provider),
        eq(agentSessions.sessionKeyHash, sessionKeyHash),
      )).limit(1)
      if (concurrentExternal?.ownerUserId !== currentUserId) throw RealtimeRpcError.BadRequest()
      if (concurrentExternal) {
        return {
          row: concurrentExternal,
          state: concurrentExternal.chatId === chat.id
            ? ConnectAgentSessionState.ALREADY_CONNECTED
            : ConnectAgentSessionState.CONNECTED_ELSEWHERE,
        }
      }
      throw RealtimeRpcError.BadRequest()
    }
    return { row: created, state: ConnectAgentSessionState.CREATED }
  })

  return {
    agentSession: await encodeAgentSession(result.row, currentUserId),
    state: result.state,
  }
}

export async function getAgentSession(
  input: GetAgentSessionInput,
  currentUserId: number,
): Promise<GetAgentSessionResult> {
  if (!input.peerId) throw RealtimeRpcError.BadRequest()
  const botUserId = safePositiveNumber(input.botUserId)
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, { currentUserId })
  await verifiedOwnerBotChat({ chat, botUserId, ownerUserId: currentUserId })
  const [row] = await db.select().from(agentSessions).where(and(
    eq(agentSessions.chatId, chat.id),
    eq(agentSessions.botUserId, botUserId),
  )).limit(1)
  if (!row) return {}
  if (row.ownerUserId !== currentUserId) throw RealtimeRpcError.UserIdInvalid()
  return {
    connection: {
      agentSession: await encodeAgentSession(row, currentUserId),
      instanceRef: decryptAgentRef(row.instanceRefEncrypted),
      sessionRef: decryptAgentRef(row.sessionRefEncrypted),
      projectRef: row.projectRefEncrypted ? decryptAgentRef(row.projectRefEncrypted) : undefined,
    },
  }
}

function prepareSync(input: AgentSessionMessageSync): PreparedSync {
  if (
    input.role !== AgentSessionMessageRole.USER &&
    input.role !== AgentSessionMessageRole.ASSISTANT
  ) throw RealtimeRpcError.BadRequest()

  let refs: AgentSourceRefs
  try {
    refs = normalizeAgentSourceRefs({
      correlationRef: input.correlationRef,
      itemRef: input.itemRef,
    })
  } catch {
    throw RealtimeRpcError.BadRequest()
  }
  const sourceKeyHash = refs.correlationRef
    ? agentSourceHash("correlation", refs.correlationRef)
    : agentSourceHash("item", refs.itemRef!)
  const itemKeyHash = refs.itemRef ? agentSourceHash("item", refs.itemRef) : null

  let sourceRefEncrypted: Buffer
  try {
    sourceRefEncrypted = encryptAgentSourceRefs(refs)
  } catch {
    throw RealtimeRpcError.BadRequest()
  }

  if (input.operation.oneofKind === "link") {
    if (!refs.correlationRef) {
      throw RealtimeRpcError.BadRequest()
    }
    safePositiveNumber(input.operation.link.messageId)
    return {
      input,
      refs,
      sourceKeyHash,
      itemKeyHash,
      sourceRefEncrypted,
      revisionRefEncrypted: null,
      revisionRef: undefined,
      baseRevisionRef: undefined,
    }
  }

  if (input.operation.oneofKind !== "upsert") throw RealtimeRpcError.BadRequest()
  const text = input.operation.upsert.text
  const assistantRandomId = input.operation.upsert.assistantRandomId
  if (assistantRandomId !== undefined) {
    if (input.role !== AgentSessionMessageRole.ASSISTANT) throw RealtimeRpcError.BadRequest()
    safePositiveNumber(assistantRandomId)
  }
  if (
    Buffer.byteLength(text, "utf8") > MAX_MESSAGE_BYTES ||
    (input.sourceDate === undefined && assistantRandomId === undefined)
  ) {
    throw RealtimeRpcError.BadRequest()
  }
  const sourceDateSeconds = input.sourceDate === undefined ? undefined : Number(input.sourceDate)
  if (
    sourceDateSeconds !== undefined &&
    (!Number.isSafeInteger(sourceDateSeconds) || sourceDateSeconds < 0)
  ) throw RealtimeRpcError.BadRequest()
  const revisionRef = ensureBounded(input.revisionRef, 512, true)!
  const baseRevisionRef = ensureBounded(input.baseRevisionRef, 512, false)
  const entityBytes = input.operation.upsert.entities
    ? MessageEntities.toBinary(input.operation.upsert.entities)
    : undefined
  return {
    input,
    refs,
    sourceKeyHash,
    itemKeyHash,
    sourceRefEncrypted,
    revisionRefEncrypted: encryptAgentRef(revisionRef),
    revisionRef,
    baseRevisionRef,
    encryptedText: text.length > 0 ? encryptMessage(text) : undefined,
    encryptedEntities: entityBytes && entityBytes.length > 0 ? encryptBinary(entityBytes) : undefined,
    sourceDate: sourceDateSeconds === undefined ? undefined : new Date(sourceDateSeconds * 1_000),
  }
}

async function loadSyncContext(agentSessionId: bigint, botUserId: number): Promise<AgentSessionContext> {
  const [session] = await db.select().from(agentSessions).where(eq(agentSessions.id, agentSessionId)).limit(1)
  if (!session || session.botUserId !== botUserId) throw RealtimeRpcError.BadRequest()
  const chat = await db._query.chats.findFirst({ where: eq(chats.id, session.chatId) })
  if (!chat) throw RealtimeRpcError.PeerIdInvalid()
  await verifiedOwnerBotChat({ chat, botUserId, ownerUserId: session.ownerUserId })
  return { session, chat }
}

function sameRefs(storedEncrypted: Buffer, incoming: AgentSourceRefs): boolean {
  const stored = decryptAgentSourceRefs(storedEncrypted)
  return (
    (!stored.correlationRef || !incoming.correlationRef || stored.correlationRef === incoming.correlationRef) &&
    (!stored.itemRef || !incoming.itemRef || stored.itemRef === incoming.itemRef)
  )
}

function mergedIdentity(storedEncrypted: Buffer, incoming: AgentSourceRefs): {
  sourceKeyHash: Buffer
  itemKeyHash: Buffer | null
  sourceRefEncrypted: Buffer
} {
  const stored = decryptAgentSourceRefs(storedEncrypted)
  const refs: AgentSourceRefs = {
    correlationRef: stored.correlationRef ?? incoming.correlationRef,
    itemRef: stored.itemRef ?? incoming.itemRef,
  }
  return {
    sourceKeyHash: refs.correlationRef
      ? agentSourceHash("correlation", refs.correlationRef)
      : agentSourceHash("item", refs.itemRef!),
    itemKeyHash: refs.itemRef ? agentSourceHash("item", refs.itemRef) : null,
    sourceRefEncrypted: encryptAgentSourceRefs(refs),
  }
}

function currentRevision(encrypted: Buffer | null): string | undefined {
  return encrypted ? decryptAgentRef(encrypted) : undefined
}

function syncResult(
  index: number,
  state: AgentSessionMessageSyncState,
  messageId?: number,
  currentRevisionRef?: string,
): AgentSessionMessageSyncResult {
  return {
    index,
    state,
    messageId: messageId === undefined ? undefined : BigInt(messageId),
    currentRevisionRef,
  }
}

async function broadcastProjectedUpdates(input: {
  context: AgentSessionContext
  updates: ProjectedUpdate[]
}): Promise<void> {
  if (input.updates.length === 0) return
  const { chat, session } = input.context
  const inputPeer = encodePeerFromChat(chat, { currentUserId: session.botUserId })
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId: session.botUserId })
  const fullMessages = await MessageModel.getMessagesByIds(
    chat.id,
    Array.from(new Set(input.updates.map((update) => BigInt(update.messageId)))),
  )
  const messagesById = new Map(fullMessages.map((message) => [message.messageId, message]))
  const rawMessages = await db.select().from(messages).where(and(
    eq(messages.chatId, chat.id),
    inArray(messages.messageId, input.updates.map((update) => update.messageId)),
  ))
  const rawMessagesById = new Map(rawMessages.map((message) => [message.messageId, message]))

  for (const projected of input.updates) {
    const message = messagesById.get(projected.messageId)
    if (!message) continue
    for (const userId of updateGroup.userIds) {
      const encoded = Encoders.fullMessage({
        message,
        encodingForUserId: userId,
        encodingForPeer: { peer: encodeOutputPeerFromChat(chat, { currentUserId: userId }) },
      })
      const update: Update = projected.kind === "newMessage"
        ? {
            seq: projected.update.seq,
            date: encodeDateStrict(projected.update.date),
            update: { oneofKind: "newMessage", newMessage: { message: encoded } },
          }
        : {
            seq: projected.update.seq,
            date: encodeDateStrict(projected.update.date),
            update: { oneofKind: "editMessage", editMessage: { message: encoded } },
          }
      RealtimeUpdates.pushToUser(userId, [update])
    }
    if (projected.kind === "newMessage" && projected.notify) {
      const rawMessage = rawMessagesById.get(projected.messageId)
      if (rawMessage) {
        void sendProjectedMessageNotification({
          chat,
          message: rawMessage,
          text: message.text ?? undefined,
          entities: message.entities ?? undefined,
        }).catch((error) => {
          log.error("failed to notify for live agent session message", {
            agentSessionId: session.id.toString(),
            messageId: projected.messageId,
            error,
          })
        })
      }
    }
  }
}

export async function syncAgentSessionMessages(
  input: SyncAgentSessionMessagesInput,
  botUserId: number,
): Promise<SyncAgentSessionMessagesResult> {
  if (
    input.mode !== AgentSessionSyncMode.HISTORY &&
    input.mode !== AgentSessionSyncMode.LIVE
  ) throw RealtimeRpcError.BadRequest()
  if (input.messages.length === 0 || input.messages.length > MAX_BATCH_SIZE) {
    throw RealtimeRpcError.BadRequest()
  }
  const context = await loadSyncContext(input.agentSessionId, botUserId)
  const prepared = input.messages.map(prepareSync)

  const projected: ProjectedUpdate[] = []
  const results = await db.transaction(async (tx) => {
    const [lockedSession] = await tx
      .select()
      .from(agentSessions)
      .where(and(eq(agentSessions.id, context.session.id), eq(agentSessions.botUserId, botUserId)))
      .for("update")
      .limit(1)
    const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, context.chat.id)).for("update").limit(1)
    if (!lockedSession || !lockedChat) throw RealtimeRpcError.BadRequest()

    let nextMessageId = Math.max(lockedChat.lastMsgId ?? 0, lockedChat.messageIdCounter ?? 0)
    let lastCreatedMessageId: number | undefined
    let lastUpdate: UpdateSeqAndDate | undefined
    const itemResults: AgentSessionMessageSyncResult[] = []

    for (let index = 0; index < prepared.length; index += 1) {
      const item = prepared[index]!
      const existingRows = await tx
        .select()
        .from(agentSessionMessages)
        .where(and(
          eq(agentSessionMessages.agentSessionId, lockedSession.id),
          item.itemKeyHash
            ? or(
                eq(agentSessionMessages.sourceKeyHash, item.sourceKeyHash),
                eq(agentSessionMessages.itemKeyHash, item.itemKeyHash),
              )
            : eq(agentSessionMessages.sourceKeyHash, item.sourceKeyHash),
        ))
        .for("update")
        .limit(2)
      if (existingRows.length > 1) {
        itemResults.push(syncResult(index, AgentSessionMessageSyncState.CONFLICT))
        continue
      }
      const existing = existingRows[0]
      if (existing && !sameRefs(existing.sourceRefEncrypted, item.refs)) {
        itemResults.push(syncResult(index, AgentSessionMessageSyncState.CONFLICT))
        continue
      }
      const identity = existing ? mergedIdentity(existing.sourceRefEncrypted, item.refs) : undefined
      if (existing?.messageGlobalId === null) {
        const identityChanged =
          !existing.sourceKeyHash.equals(identity!.sourceKeyHash) ||
          (existing.itemKeyHash === null) !== (identity!.itemKeyHash === null) ||
          (existing.itemKeyHash !== null && !existing.itemKeyHash.equals(identity!.itemKeyHash!))
        if (identityChanged) {
          await tx.update(agentSessionMessages).set({
            sourceKeyHash: identity!.sourceKeyHash,
            itemKeyHash: identity!.itemKeyHash,
            sourceRefEncrypted: identity!.sourceRefEncrypted,
            updatedAt: new Date(),
          }).where(eq(agentSessionMessages.id, existing.id))
        }
        itemResults.push(syncResult(index, AgentSessionMessageSyncState.TOMBSTONED))
        continue
      }

      if (item.input.operation.oneofKind === "link") {
        const messageId = safePositiveNumber(item.input.operation.link.messageId)
        if (existing) {
          const [linkedMessage] = await tx
            .select({ messageId: messages.messageId, fromId: messages.fromId })
            .from(messages)
            .where(eq(messages.globalId, existing.messageGlobalId!))
            .limit(1)
          const alreadyLinked = existing.relation === AgentSessionMessageRelation.LINKED
          const adoptsImportedAssistant =
            existing.relation === AgentSessionMessageRelation.IMPORTED &&
            existing.role === AgentSessionMessageRole.ASSISTANT &&
            item.input.role === AgentSessionMessageRole.ASSISTANT &&
            linkedMessage?.fromId === lockedSession.botUserId
          if (
            (!alreadyLinked && !adoptsImportedAssistant) ||
            existing.role !== item.input.role ||
            linkedMessage?.messageId !== messageId
          ) {
            itemResults.push(syncResult(index, AgentSessionMessageSyncState.CONFLICT))
            continue
          }
          await tx.update(agentSessionMessages).set({
            sourceKeyHash: identity!.sourceKeyHash,
            itemKeyHash: identity!.itemKeyHash,
            sourceRefEncrypted: identity!.sourceRefEncrypted,
            relation: AgentSessionMessageRelation.LINKED,
            complete: existing.complete || item.input.complete,
            updatedAt: new Date(),
          }).where(eq(agentSessionMessages.id, existing.id))
          if (adoptsImportedAssistant) {
            const update = await UpdatesModel.insertUpdate(tx, {
              update: {
                oneofKind: "editMessage",
                editMessage: { chatId: BigInt(lockedChat.id), msgId: BigInt(messageId) },
              },
              bucket: UpdateBucket.Chat,
              entity: lockedChat,
            })
            lockedChat.updateSeq = update.seq
            lastUpdate = update
            projected.push({ kind: "editMessage", messageId, update, notify: false })
          }
          itemResults.push(syncResult(
            index,
            adoptsImportedAssistant
              ? AgentSessionMessageSyncState.LINKED
              : AgentSessionMessageSyncState.UNCHANGED,
            messageId,
          ))
          continue
        }

        const linked = item.input.role === AgentSessionMessageRole.USER
          ? await tx
              .select({ globalId: messages.globalId })
              .from(messages)
              .innerJoin(botMessageRoutes, and(
                eq(botMessageRoutes.chatId, messages.chatId),
                eq(botMessageRoutes.messageId, messages.messageId),
              ))
              .where(and(
                eq(messages.chatId, lockedChat.id),
                eq(messages.messageId, messageId),
                eq(botMessageRoutes.botUserId, botUserId),
                gt(botMessageRoutes.expiresAt, new Date()),
              ))
              .for("update")
              .limit(1)
          : await tx
              .select({ globalId: messages.globalId })
              .from(messages)
              .where(and(
                eq(messages.chatId, lockedChat.id),
                eq(messages.messageId, messageId),
                eq(messages.fromId, botUserId),
              ))
              .for("update")
              .limit(1)
        const linkedMessage = linked[0]
        if (!linkedMessage) throw RealtimeRpcError.MessageIdInvalid()
        await tx.insert(agentSessionMessages).values({
          agentSessionId: lockedSession.id,
          sourceKeyHash: item.sourceKeyHash,
          itemKeyHash: item.itemKeyHash,
          sourceRefEncrypted: item.sourceRefEncrypted,
          messageGlobalId: linkedMessage.globalId,
          relation: AgentSessionMessageRelation.LINKED,
          role: item.input.role,
          complete: item.input.complete,
        })
        const update = await UpdatesModel.insertUpdate(tx, {
          update: {
            oneofKind: "editMessage",
            editMessage: { chatId: BigInt(lockedChat.id), msgId: BigInt(messageId) },
          },
          bucket: UpdateBucket.Chat,
          entity: lockedChat,
        })
        lockedChat.updateSeq = update.seq
        lastUpdate = update
        projected.push({ kind: "editMessage", messageId, update, notify: false })
        itemResults.push(syncResult(index, AgentSessionMessageSyncState.LINKED, messageId))
        continue
      }

      if (item.input.operation.oneofKind !== "upsert") throw RealtimeRpcError.BadRequest()
      const revisionRef = item.revisionRef!
      if (existing) {
        if (existing.relation === AgentSessionMessageRelation.LINKED) {
          await tx.update(agentSessionMessages).set({
            sourceKeyHash: identity!.sourceKeyHash,
            itemKeyHash: identity!.itemKeyHash,
            sourceRefEncrypted: identity!.sourceRefEncrypted,
            complete: existing.complete || item.input.complete,
            updatedAt: new Date(),
          }).where(eq(agentSessionMessages.id, existing.id))
          const [linked] = await tx
            .select({ messageId: messages.messageId })
            .from(messages)
            .where(eq(messages.globalId, existing.messageGlobalId!))
            .limit(1)
          itemResults.push(syncResult(index, AgentSessionMessageSyncState.UNCHANGED, linked?.messageId))
          continue
        }

        const storedRevision = currentRevision(existing.revisionRefEncrypted)
        const [storedMessage] = await tx
          .select({ messageId: messages.messageId })
          .from(messages)
          .where(eq(messages.globalId, existing.messageGlobalId!))
          .for("update")
          .limit(1)
        if (!storedMessage) {
          itemResults.push(syncResult(index, AgentSessionMessageSyncState.TOMBSTONED))
          continue
        }
        if (storedRevision === revisionRef) {
          await tx.update(agentSessionMessages).set({
            sourceKeyHash: identity!.sourceKeyHash,
            itemKeyHash: identity!.itemKeyHash,
            sourceRefEncrypted: identity!.sourceRefEncrypted,
            complete: existing.complete || item.input.complete,
            updatedAt: new Date(),
          }).where(eq(agentSessionMessages.id, existing.id))
          itemResults.push(syncResult(index, AgentSessionMessageSyncState.UNCHANGED, storedMessage.messageId))
          continue
        }
        if (existing.complete && !item.input.complete) {
          itemResults.push(syncResult(index, AgentSessionMessageSyncState.STALE, storedMessage.messageId, storedRevision))
          continue
        }
        if (!item.baseRevisionRef || item.baseRevisionRef !== storedRevision) {
          itemResults.push(syncResult(index, AgentSessionMessageSyncState.CONFLICT, storedMessage.messageId, storedRevision))
          continue
        }

        const [edited] = await tx.update(messages).set({
          text: null,
          textEncrypted: item.encryptedText?.encrypted ?? null,
          textIv: item.encryptedText?.iv ?? null,
          textTag: item.encryptedText?.authTag ?? null,
          entitiesEncrypted: item.encryptedEntities?.encrypted ?? null,
          entitiesIv: item.encryptedEntities?.iv ?? null,
          entitiesTag: item.encryptedEntities?.authTag ?? null,
          editDate: null,
          rev: sql`${messages.rev} + 1`,
          hasLink: detectHasLink({ entities: item.input.operation.upsert.entities }),
        }).where(eq(messages.globalId, existing.messageGlobalId!)).returning({ messageId: messages.messageId })
        if (!edited) throw RealtimeRpcError.InternalError()
        await tx.update(agentSessionMessages).set({
          sourceKeyHash: identity!.sourceKeyHash,
          itemKeyHash: identity!.itemKeyHash,
          sourceRefEncrypted: identity!.sourceRefEncrypted,
          revisionRefEncrypted: item.revisionRefEncrypted,
          complete: item.input.complete,
          updatedAt: new Date(),
        }).where(eq(agentSessionMessages.id, existing.id))
        const update = await UpdatesModel.insertUpdate(tx, {
          update: {
            oneofKind: "editMessage",
            editMessage: { chatId: BigInt(lockedChat.id), msgId: BigInt(edited.messageId) },
          },
          bucket: UpdateBucket.Chat,
          entity: lockedChat,
        })
        lockedChat.updateSeq = update.seq
        lastUpdate = update
        projected.push({ kind: "editMessage", messageId: edited.messageId, update, notify: false })
        itemResults.push(syncResult(index, AgentSessionMessageSyncState.EDITED, edited.messageId))
        continue
      }

      if (
        item.refs.correlationRef &&
        item.input.role === AgentSessionMessageRole.USER
      ) {
        itemResults.push(syncResult(index, AgentSessionMessageSyncState.CONFLICT))
        continue
      }

      const assistantRandomId = item.input.operation.upsert.assistantRandomId
      if (assistantRandomId !== undefined) {
        const [candidate] = await tx
          .select({ globalId: messages.globalId, messageId: messages.messageId })
          .from(messages)
          .where(and(
            eq(messages.chatId, lockedChat.id),
            eq(messages.fromId, lockedSession.botUserId),
            eq(messages.randomId, assistantRandomId),
          ))
          .for("update")
          .limit(1)
        if (candidate) {
          const [claimed] = await tx
            .select({ id: agentSessionMessages.id })
            .from(agentSessionMessages)
            .where(and(
              eq(agentSessionMessages.agentSessionId, lockedSession.id),
              eq(agentSessionMessages.messageGlobalId, candidate.globalId),
            ))
            .limit(1)
          if (claimed) {
            itemResults.push(syncResult(index, AgentSessionMessageSyncState.CONFLICT))
            continue
          }
          await tx.insert(agentSessionMessages).values({
            agentSessionId: lockedSession.id,
            sourceKeyHash: item.sourceKeyHash,
            itemKeyHash: item.itemKeyHash,
            sourceRefEncrypted: item.sourceRefEncrypted,
            messageGlobalId: candidate.globalId,
            relation: AgentSessionMessageRelation.LINKED,
            role: item.input.role,
            complete: item.input.complete,
          })
          const update = await UpdatesModel.insertUpdate(tx, {
            update: {
              oneofKind: "editMessage",
              editMessage: { chatId: BigInt(lockedChat.id), msgId: BigInt(candidate.messageId) },
            },
            bucket: UpdateBucket.Chat,
            entity: lockedChat,
          })
          lockedChat.updateSeq = update.seq
          lastUpdate = update
          projected.push({ kind: "editMessage", messageId: candidate.messageId, update, notify: false })
          itemResults.push(syncResult(index, AgentSessionMessageSyncState.LINKED, candidate.messageId))
          continue
        }
      }
      if (!item.sourceDate) {
        itemResults.push(syncResult(index, AgentSessionMessageSyncState.CONFLICT))
        continue
      }

      nextMessageId += 1
      const fromId = item.input.role === AgentSessionMessageRole.USER
        ? lockedSession.ownerUserId
        : lockedSession.botUserId
      const [created] = await tx.insert(messages).values({
        chatId: lockedChat.id,
        messageId: nextMessageId,
        fromId,
        randomId: assistantRandomId ?? null,
        textEncrypted: item.encryptedText?.encrypted ?? null,
        textIv: item.encryptedText?.iv ?? null,
        textTag: item.encryptedText?.authTag ?? null,
        entitiesEncrypted: item.encryptedEntities?.encrypted ?? null,
        entitiesIv: item.encryptedEntities?.iv ?? null,
        entitiesTag: item.encryptedEntities?.authTag ?? null,
        date: item.sourceDate!,
        hasLink: detectHasLink({ entities: item.input.operation.upsert.entities }),
        countsAsUnread: input.mode === AgentSessionSyncMode.LIVE,
      }).returning()
      if (!created) throw RealtimeRpcError.InternalError()
      await tx.insert(agentSessionMessages).values({
        agentSessionId: lockedSession.id,
        sourceKeyHash: item.sourceKeyHash,
        itemKeyHash: item.itemKeyHash,
        sourceRefEncrypted: item.sourceRefEncrypted,
        revisionRefEncrypted: item.revisionRefEncrypted,
        messageGlobalId: created.globalId,
        relation: AgentSessionMessageRelation.IMPORTED,
        role: item.input.role,
        complete: item.input.complete,
      })
      const update = await UpdatesModel.insertUpdate(tx, {
        update: {
          oneofKind: "newMessage",
          newMessage: { chatId: BigInt(lockedChat.id), msgId: BigInt(created.messageId) },
        },
        bucket: UpdateBucket.Chat,
        entity: lockedChat,
      })
      lockedChat.updateSeq = update.seq
      lastUpdate = update
      lastCreatedMessageId = created.messageId
      projected.push({
        kind: "newMessage",
        messageId: created.messageId,
        update,
        notify: input.mode === AgentSessionSyncMode.LIVE,
      })
      itemResults.push(syncResult(index, AgentSessionMessageSyncState.CREATED, created.messageId))
    }

    if (lastUpdate) {
      await tx.update(chats).set({
        updateSeq: lastUpdate.seq,
        lastUpdateDate: lastUpdate.date,
        messageIdCounter: nextMessageId,
        lastMsgId: lastCreatedMessageId ?? lockedChat.lastMsgId,
      }).where(eq(chats.id, lockedChat.id))
    }
    return itemResults
  })

  try {
    await broadcastProjectedUpdates({ context, updates: projected })
  } catch (error) {
    log.error("failed to fan out committed agent session messages", {
      agentSessionId: input.agentSessionId.toString(),
      botUserId,
      error,
    })
  }
  return { messages: results }
}

export async function isImportedAgentMessage(chatId: number, messageId: number): Promise<boolean> {
  const [row] = await db
    .select({ relation: agentSessionMessages.relation })
    .from(messages)
    .innerJoin(agentSessionMessages, eq(agentSessionMessages.messageGlobalId, messages.globalId))
    .where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
    .limit(1)
  return row?.relation === AgentSessionMessageRelation.IMPORTED
}

export async function hasImportedAgentMessages(chatId: number, messageIds: readonly number[]): Promise<boolean> {
  if (messageIds.length === 0) return false
  const [row] = await db
    .select({ id: agentSessionMessages.id })
    .from(messages)
    .innerJoin(agentSessionMessages, eq(agentSessionMessages.messageGlobalId, messages.globalId))
    .where(and(
      eq(messages.chatId, chatId),
      inArray(messages.messageId, [...messageIds]),
      eq(agentSessionMessages.relation, AgentSessionMessageRelation.IMPORTED),
    ))
    .limit(1)
  return row !== undefined
}
