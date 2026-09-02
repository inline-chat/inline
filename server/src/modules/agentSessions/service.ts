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
  blockContents,
  botMessageRoutes,
  chats,
  messages,
  spaces,
  type DbAgentSession,
  type DbChat,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { chatAgentContext } from "@in/server/modules/agentConfiguration"
import { encryptMessage, encryptMessageEntities } from "@in/server/modules/encryption/encryptMessage"
import { detectHasLink } from "@in/server/modules/message/linkDetection"
import {
  deleteUnreferencedBlockContents,
  insertPreparedBlockContent,
  prepareBlockContent,
  replacePreparedBlockContent,
  type PreparedBlockContent,
} from "@in/server/modules/message/blockContentStorage"
import { processOutgoingText } from "@in/server/modules/message/processOutgoingText"
import { validateOutgoingMessageText } from "@in/server/modules/message/messageTextLimits"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { sendProjectedMessageNotification } from "@in/server/functions/messages.sendMessage"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodeOutputPeerFromChat, encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { and, eq, exists, gt, inArray, ne, or, sql } from "drizzle-orm"
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
  encryptedEntities?: ReturnType<typeof encryptMessageEntities>
  preparedBlockContent?: PreparedBlockContent
  hasLink: boolean
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

function ensureCompatibleProjectRef(row: DbAgentSession, projectRef: string | undefined): void {
  if (projectRef === undefined) return
  if (row.projectRefEncrypted === null) throw RealtimeRpcError.BadRequest()
  if (decryptAgentRef(row.projectRefEncrypted) !== projectRef) {
    throw RealtimeRpcError.BadRequest()
  }
}

function ensureSelectedProjectRef(
  context: ReturnType<typeof chatAgentContext>,
  projectRef: string | undefined,
): void {
  const selectedProjectId = context?.configuration?.projectId
  if (selectedProjectId !== undefined && selectedProjectId !== projectRef) {
    throw RealtimeRpcError.BadRequest()
  }
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
  await verifiedOwnerBot(input.botUserId, input.ownerUserId)
  await Promise.all([
    AccessGuards.ensureChatAccess(input.chat, input.ownerUserId),
    AccessGuards.ensureChatAccess(input.chat, input.botUserId),
    ensureNotInternetPublic(input.chat),
  ])
}

async function verifiedOwnerBot(botUserId: number, ownerUserId: number): Promise<void> {
  const bot = await UsersModel.getUserById(botUserId)
  if (!bot?.bot || bot.botCreatorId !== ownerUserId || UsersModel.isDeleted(bot)) {
    throw RealtimeRpcError.UserIdInvalid()
  }
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
    parentChatId: chat.parentChatId ? BigInt(chat.parentChatId) : undefined,
  }
}

export async function connectAgentSession(
  input: ConnectAgentSessionInput,
  currentUserId: number,
): Promise<ConnectAgentSessionResult> {
  if (!validProvider(input.provider)) throw RealtimeRpcError.BadRequest()
  const botUserId = safePositiveNumber(input.botUserId)
  const instanceRef = ensureBounded(input.instanceRef, 512, true)!
  const sessionRef = ensureBounded(input.sessionRef, 512, true)!
  const projectRef = ensureBounded(input.projectRef, MAX_PROJECT_REF_BYTES, false)
  const sessionKeyHash = agentSessionHash(input.provider, instanceRef, sessionRef)

  // An omitted peer is an owner-authenticated, read-only identity lookup. It
  // lets a bridge recover the canonical Inline thread before creating a new
  // reply thread after local state loss. A miss deliberately reserves nothing.
  if (!input.peerId) {
    if (input.statusMessageId !== undefined) throw RealtimeRpcError.BadRequest()
    await verifiedOwnerBot(botUserId, currentUserId)
    const [external] = await db.select().from(agentSessions).where(and(
      eq(agentSessions.botUserId, botUserId),
      eq(agentSessions.provider, input.provider),
      eq(agentSessions.sessionKeyHash, sessionKeyHash),
    )).limit(1)
    if (!external) return { state: ConnectAgentSessionState.UNSPECIFIED }
    if (external.ownerUserId !== currentUserId) throw RealtimeRpcError.UserIdInvalid()
    ensureCompatibleProjectRef(external, projectRef)
    const canonicalChat = await db._query.chats.findFirst({ where: eq(chats.id, external.chatId) })
    if (!canonicalChat) throw RealtimeRpcError.PeerIdInvalid()
    await verifiedOwnerBotChat({ chat: canonicalChat, botUserId, ownerUserId: currentUserId })
    return {
      agentSession: await encodeAgentSession(external, currentUserId),
      state: ConnectAgentSessionState.ALREADY_CONNECTED,
    }
  }

  const chat = await ChatModel.getChatFromInputPeer(input.peerId, { currentUserId })
  await verifiedOwnerBotChat({ chat, botUserId, ownerUserId: currentUserId })
  const statusGlobalId = await statusMessageGlobalId({
    chatId: chat.id,
    botUserId,
    messageId: input.statusMessageId,
  })

  const result = await db.transaction(async (tx) => {
    const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
    if (!lockedChat) throw RealtimeRpcError.PeerIdInvalid()
    const boundContext = chatAgentContext(lockedChat)
    if (boundContext && Number(boundContext.botUserId) !== botUserId) {
      throw RealtimeRpcError.BadRequest()
    }
    ensureSelectedProjectRef(boundContext, projectRef)

    const [external] = await tx.select().from(agentSessions).where(and(
        eq(agentSessions.botUserId, botUserId),
        eq(agentSessions.provider, input.provider),
        eq(agentSessions.sessionKeyHash, sessionKeyHash),
      )).for("update").limit(1)
    if (external) {
      if (external.ownerUserId !== currentUserId) throw RealtimeRpcError.UserIdInvalid()
      ensureCompatibleProjectRef(external, projectRef)
      if (external.chatId !== chat.id) {
        return { row: external, state: ConnectAgentSessionState.CONNECTED_ELSEWHERE }
      }
      const [updated] = await tx
        .update(agentSessions)
        .set({
          projectRefEncrypted: external.projectRefEncrypted,
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
      eq(agentSessions.chatId, chat.id),
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
        ensureCompatibleProjectRef(concurrentExternal, projectRef)
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

  const canonicalChat = result.row.chatId === chat.id
    ? chat
    : await db._query.chats.findFirst({ where: eq(chats.id, result.row.chatId) })
  if (!canonicalChat) throw RealtimeRpcError.PeerIdInvalid()
  await verifiedOwnerBotChat({ chat: canonicalChat, botUserId, ownerUserId: currentUserId })
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

async function prepareSync(input: AgentSessionMessageSync): Promise<PreparedSync> {
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
      hasLink: false,
    }
  }

  if (input.operation.oneofKind !== "upsert") throw RealtimeRpcError.BadRequest()
  let text = input.operation.upsert.text
  const assistantRandomId = input.operation.upsert.assistantRandomId
  if (assistantRandomId !== undefined) {
    if (input.role !== AgentSessionMessageRole.ASSISTANT) throw RealtimeRpcError.BadRequest()
    if (assistantRandomId <= 0n) throw RealtimeRpcError.BadRequest()
  }
  validateOutgoingMessageText(text)
  if (
    input.sourceDate === undefined && assistantRandomId === undefined
  ) {
    throw RealtimeRpcError.BadRequest()
  }
  const sourceDateSeconds = input.sourceDate === undefined ? undefined : Number(input.sourceDate)
  if (
    sourceDateSeconds !== undefined &&
    (!Number.isSafeInteger(sourceDateSeconds) || sourceDateSeconds < 0)
  ) throw RealtimeRpcError.BadRequest()
  const sourceDate = sourceDateSeconds === undefined
    ? undefined
    : new Date(sourceDateSeconds * 1_000)
  if (sourceDate !== undefined && !Number.isFinite(sourceDate.getTime())) {
    throw RealtimeRpcError.BadRequest()
  }
  const revisionRef = ensureBounded(input.revisionRef, 512, true)!
  const baseRevisionRef = ensureBounded(input.baseRevisionRef, 512, false)
  let entities = input.operation.upsert.entities
  let preparedBlockContent: PreparedBlockContent | undefined
  if (input.role === AgentSessionMessageRole.ASSISTANT) {
    const outgoing = await processOutgoingText({ text, entities, parseMarkdown: true })
    text = outgoing.text
    entities = outgoing.entities
    if (outgoing.blockContent) {
      try {
        preparedBlockContent = prepareBlockContent({
          text,
          entities,
          parsed: {
            blockContent: outgoing.blockContent,
            imageSources: outgoing.blockImageSources ?? [],
          },
        })
      } catch (error) {
        log.error("agent history rich content preparation failed; storing the plain projection", {
          errorType: error instanceof Error ? error.name : "UnknownError",
        })
      }
    }
  }
  const entityBytes = entities
    ? MessageEntities.toBinary(entities)
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
    encryptedEntities: entityBytes && entityBytes.length > 0
      ? encryptMessageEntities(entityBytes)
      : undefined,
    preparedBlockContent,
    hasLink: detectHasLink({ entities }),
    sourceDate,
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
  const prepared = await Promise.all(input.messages.map(prepareSync))

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
          ? input.mode === AgentSessionSyncMode.HISTORY
            // HISTORY is an owner-authorized repair of an already-bound
            // session thread. Delivery routes are intentionally transient, so
            // repair may adopt any existing non-self row in that thread,
            // including another user's or bot's prompt. LIVE still requires
            // this bot's current routed delivery below.
            ? await tx
                .select({ globalId: messages.globalId })
                .from(messages)
                .where(and(
                  eq(messages.chatId, lockedChat.id),
                  eq(messages.messageId, messageId),
                  ne(messages.fromId, botUserId),
                ))
                .for("update")
                .limit(1)
            : await tx
              .select({ globalId: messages.globalId })
              .from(messages)
              .where(and(
                eq(messages.chatId, lockedChat.id),
                eq(messages.messageId, messageId),
                ne(messages.fromId, botUserId),
                or(
                  eq(messages.fromId, lockedSession.ownerUserId),
                  exists(tx
                    .select({ one: sql`1` })
                    .from(botMessageRoutes)
                    .where(and(
                      eq(botMessageRoutes.chatId, messages.chatId),
                      eq(botMessageRoutes.messageId, messages.messageId),
                      eq(botMessageRoutes.botUserId, botUserId),
                      gt(botMessageRoutes.expiresAt, new Date()),
                    ))),
                ),
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
          .select({
            messageId: messages.messageId,
            blockContentId: messages.blockContentId,
          })
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

        let blockContentId = storedMessage.blockContentId
        if (item.preparedBlockContent) {
          if (storedMessage.blockContentId) {
            const [storedBlockContent] = await tx
              .select({ revision: blockContents.revision })
              .from(blockContents)
              .where(eq(blockContents.id, storedMessage.blockContentId))
              .for("update")
              .limit(1)
            if (storedBlockContent) {
              await replacePreparedBlockContent({
                tx,
                contentId: storedMessage.blockContentId,
                currentRevision: storedBlockContent.revision,
                prepared: item.preparedBlockContent,
              })
            } else {
              blockContentId = await insertPreparedBlockContent(tx, item.preparedBlockContent, 0)
            }
          } else {
            blockContentId = await insertPreparedBlockContent(tx, item.preparedBlockContent, 0)
          }
        } else {
          blockContentId = null
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
          hasLink: item.hasLink,
          blockContentId,
        }).where(eq(messages.globalId, existing.messageGlobalId!)).returning({ messageId: messages.messageId })
        if (!edited) throw RealtimeRpcError.InternalError()
        if (blockContentId === null && storedMessage.blockContentId) {
          await deleteUnreferencedBlockContents(tx, [storedMessage.blockContentId])
        }
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
      const blockContentId = item.preparedBlockContent
        ? await insertPreparedBlockContent(tx, item.preparedBlockContent, 0)
        : null
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
        blockContentId,
        date: item.sourceDate!,
        hasLink: item.hasLink,
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
    .select({ id: agentSessionMessages.id })
    .from(messages)
    .innerJoin(agentSessionMessages, eq(agentSessionMessages.messageGlobalId, messages.globalId))
    .where(and(
      eq(messages.chatId, chatId),
      eq(messages.messageId, messageId),
      eq(agentSessionMessages.relation, AgentSessionMessageRelation.IMPORTED),
    ))
    .limit(1)
  return row !== undefined
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
