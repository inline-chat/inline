import {
  AgentAttentionKind,
  AgentHeldBy_Client,
  AgentRunState,
  AgentSessionState,
  AgentWaitingReason,
  type AgentAttention,
  type AgentSession,
  type GetAgentSessionStatesInput,
  type GetAgentSessionStatesResult,
  type UpdateAgentSessionStateInput,
  type UpdateAgentSessionStateResult,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { agentSessions, chats, messages, type DbAgentSession, type DbChat } from "@in/server/db/schema"
import { insertChatUpdate, pushChatUpdate } from "@in/server/modules/agents/chatUpdates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { getCachedUserSettings } from "@in/server/modules/cache/userSettings"
import { decideNotification } from "@in/server/modules/notifications/decision"
import { resolveEffectiveNotificationMode } from "@in/server/modules/notifications/dialogNotificationSettings"
import { getInheritedDialogNotificationSettings } from "@in/server/modules/notifications/inheritedDialogNotificationSettings"
import { normalizeGlobalNotificationMode } from "@in/server/modules/notifications/notificationSettingsCompat"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { and, desc, eq, gt, inArray, notInArray } from "drizzle-orm"
import { AgentSessionMovedError, MAX_MOVE_RETRIES } from "./moved"
import { agentSessionV2Fields, decryptAgentSessionState, encryptAgentSessionState } from "./stateFields"

const log = new Log("AgentSessions.runState")

const MAX_ATTENTION_USERS = 32
const MAX_TEXT_LENGTH = 256
const MAX_QUEUED_COUNT = 100_000
/** Badge listings skip sessions whose state has not moved for this long. */
const ACTIVE_STATE_WINDOW_MS = 7 * 24 * 60 * 60 * 1_000
const MAX_ACTIVE_SESSIONS = 500

function inEnum(value: number, min: number, max: number): boolean {
  return Number.isInteger(value) && value >= min && value <= max
}

function boundedText(value: string | undefined): string | undefined {
  if (value === undefined) return undefined
  const trimmed = value.trim()
  if (trimmed.length === 0) return undefined
  if (trimmed.length > MAX_TEXT_LENGTH) throw RealtimeRpcError.BadRequest()
  return trimmed
}

/** Validates a bridge report and drops fields that do not apply to its run state. */
export function normalizeAgentSessionState(input: AgentSessionState): AgentSessionState {
  if (!inEnum(input.runState, AgentRunState.UNKNOWN, AgentRunState.RELEASED)) throw RealtimeRpcError.BadRequest()
  if (!inEnum(input.waitingReason, AgentWaitingReason.UNSPECIFIED, AgentWaitingReason.SETUP)) throw RealtimeRpcError.BadRequest()
  if (input.revision <= 0n) throw RealtimeRpcError.BadRequest()
  if (input.queuedCount > MAX_QUEUED_COUNT) throw RealtimeRpcError.BadRequest()
  if (input.startedAt !== undefined && input.startedAt < 0n) throw RealtimeRpcError.BadRequest()

  let attention: AgentAttention | undefined
  if (input.attention && input.attention.kind !== AgentAttentionKind.UNSPECIFIED) {
    if (!inEnum(input.attention.kind, AgentAttentionKind.APPROVAL, AgentAttentionKind.ERROR)) {
      throw RealtimeRpcError.BadRequest()
    }
    const userIds = [...new Set(input.attention.userIds)]
    if (userIds.length > MAX_ATTENTION_USERS || userIds.some((id) => id <= 0n || id > 2_147_483_647n)) {
      throw RealtimeRpcError.BadRequest()
    }
    if (input.attention.messageId !== undefined && input.attention.messageId <= 0n) throw RealtimeRpcError.BadRequest()
    attention = {
      kind: input.attention.kind,
      userIds,
      messageId: input.attention.messageId,
      text: boundedText(input.attention.text),
    }
  }

  const heldElsewhere = input.runState === AgentRunState.HELD_ELSEWHERE
  if (heldElsewhere && input.heldBy && !inEnum(input.heldBy.client, AgentHeldBy_Client.UNSPECIFIED, AgentHeldBy_Client.OTHER)) {
    throw RealtimeRpcError.BadRequest()
  }
  return AgentSessionState.create({
    runState: input.runState,
    waitingReason: input.runState === AgentRunState.WAITING ? input.waitingReason : AgentWaitingReason.UNSPECIFIED,
    attention,
    heldBy: heldElsewhere && input.heldBy
      ? { client: input.heldBy.client, label: boundedText(input.heldBy.label) }
      : undefined,
    queuedCount: input.queuedCount,
    detail: boundedText(input.detail),
    revision: input.revision,
    startedAt: input.startedAt,
  })
}

/** Same state apart from revision and timestamps. */
function sameState(left: AgentSessionState | undefined, right: AgentSessionState): boolean {
  if (!left) return false
  const strip = (state: AgentSessionState) =>
    AgentSessionState.toBinary({ ...state, revision: 0n, updatedAt: 0n })
  return Buffer.from(strip(left)).equals(Buffer.from(strip(right)))
}

function attentionKey(attention: AgentAttention | undefined): string {
  if (!attention) return ""
  return [attention.kind, attention.messageId ?? "", [...attention.userIds].sort().join(","), attention.text ?? ""].join("|")
}

/** People the attention may reach: the listed users who can access the chat, never the bot. */
async function attentionAudience(chat: DbChat, botUserId: number, attention: AgentAttention | undefined): Promise<number[]> {
  if (!attention) return []
  const requested = attention.userIds.map(Number).filter((id) => id !== botUserId)
  if (requested.length === 0) return []
  if (chat.type === "private") {
    return UsersModel.getActiveUserIds(requested.filter((id) => id === chat.minUserId || id === chat.maxUserId))
  }
  const access = await getEffectiveChatAccessUserIds(db, [chat.id], { userIds: requested })
  return requested.filter((id) => access.get(chat.id)?.has(id))
}

async function statusMessageId(row: DbAgentSession): Promise<bigint | undefined> {
  if (row.statusMessageGlobalId === null) return undefined
  const [status] = await db
    .select({ messageId: messages.messageId })
    .from(messages)
    .where(eq(messages.globalId, row.statusMessageGlobalId))
    .limit(1)
  return status ? BigInt(status.messageId) : undefined
}

/** Chat-bucket snapshot of a session; the client peer is encoded per recipient. */
export async function agentSessionChatUpdate(row: DbAgentSession): Promise<ServerUpdate["update"]> {
  const fields = agentSessionV2Fields(row)
  return {
    oneofKind: "agentSessionState",
    agentSessionState: {
      agentSessionId: row.id,
      botUserId: BigInt(row.botUserId),
      provider: row.provider,
      statusMessageId: await statusMessageId(row),
      parentSessionId: fields.parentSessionId,
      relation: fields.relation,
      state: fields.state,
      workspaceLabel: fields.workspaceLabel,
      chatId: BigInt(row.chatId),
    },
  }
}

export async function encodeAgentSessionForViewer(row: DbAgentSession, chat: DbChat, viewerUserId: number): Promise<AgentSession> {
  return {
    id: row.id,
    peerId: encodeOutputPeerFromChat(chat, { currentUserId: viewerUserId }),
    botUserId: BigInt(row.botUserId),
    provider: row.provider,
    statusMessageId: await statusMessageId(row),
    parentChatId: chat.parentChatId ? BigInt(chat.parentChatId) : undefined,
    ...agentSessionV2Fields(row),
  }
}

/**
 * Bridge → server run-state report. Chat members get the change in realtime
 * and through catch-up; the attention's people get a push when it changes.
 */
export async function updateAgentSessionState(
  input: UpdateAgentSessionStateInput,
  currentUserId: number,
): Promise<UpdateAgentSessionStateResult> {
  if (!input.state) throw RealtimeRpcError.BadRequest()
  if (input.agentSessionId <= 0n) throw RealtimeRpcError.BadRequest()
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await updateAgentSessionStateOnce(input, input.state, currentUserId)
    } catch (error) {
      // The work moved between reading its chat and locking it: report in
      // the new chat, with that chat's attention audience.
      if (error instanceof AgentSessionMovedError && attempt < MAX_MOVE_RETRIES) continue
      throw error
    }
  }
}

async function updateAgentSessionStateOnce(
  input: UpdateAgentSessionStateInput,
  state: AgentSessionState,
  currentUserId: number,
): Promise<UpdateAgentSessionStateResult> {
  const sessionId = input.agentSessionId
  const [session] = await db.select().from(agentSessions).where(eq(agentSessions.id, sessionId)).limit(1)
  // Only the session's bot, or the owner who connected it, reports its state.
  if (!session || (session.botUserId !== currentUserId && session.ownerUserId !== currentUserId)) {
    throw RealtimeRpcError.BadRequest()
  }
  const [chat] = await db.select().from(chats).where(eq(chats.id, session.chatId)).limit(1)
  if (!chat) throw RealtimeRpcError.PeerIdInvalid()

  const normalized = normalizeAgentSessionState(state)
  const audience = await attentionAudience(chat, session.botUserId, normalized.attention)
  if (normalized.attention) normalized.attention.userIds = audience.map(BigInt)

  const result = await db.transaction(async (tx) => {
    // Lock order for every writer of a work: its chat, then the session.
    const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, session.chatId)).for("update").limit(1)
    if (!lockedChat) throw RealtimeRpcError.PeerIdInvalid()
    const [current] = await tx.select().from(agentSessions).where(eq(agentSessions.id, session.id)).for("update").limit(1)
    if (!current) throw RealtimeRpcError.BadRequest()
    if (current.chatId !== lockedChat.id) throw new AgentSessionMovedError()
    if (normalized.revision <= current.stateRevision) return { row: current, applied: false as const }

    const previous = decryptAgentSessionState(current.stateEncrypted)
    const now = new Date()
    const changed = !sameState(previous, normalized)
    const stored: AgentSessionState = {
      ...normalized,
      updatedAt: changed || !previous ? encodeDateStrict(now) : previous.updatedAt,
    }
    const [row] = await tx
      .update(agentSessions)
      .set({
        runState: stored.runState,
        attentionKind: stored.attention?.kind ?? AgentAttentionKind.UNSPECIFIED,
        attentionUserIds: stored.attention ? audience : null,
        heldBy: stored.heldBy?.client ?? AgentHeldBy_Client.UNSPECIFIED,
        stateRevision: stored.revision,
        stateEncrypted: encryptAgentSessionState(stored),
        stateUpdatedAt: changed || !current.stateUpdatedAt ? now : current.stateUpdatedAt,
      })
      .where(eq(agentSessions.id, current.id))
      .returning()
    if (!row) throw RealtimeRpcError.InternalError()
    if (!changed) return { row, applied: true as const }

    const { durable } = await insertChatUpdate(tx, lockedChat.id, await agentSessionChatUpdate(row))
    return {
      row,
      applied: true as const,
      durable,
      attentionChanged: attentionKey(previous?.attention) !== attentionKey(stored.attention),
    }
  })

  const agentSession = await encodeAgentSessionForViewer(result.row, chat, currentUserId)
  if (result.applied && "durable" in result && result.durable) {
    await pushChatUpdate(chat, result.durable, (peerId) => ({
      oneofKind: "agentSessionState",
      agentSessionState: { agentSession: { ...agentSession, peerId }, bucketPeerId: peerId },
    }))
    if (result.attentionChanged) await pushAttention(result.row, chat)
  }
  return { agentSession, applied: result.applied }
}

const attentionFallback: Record<number, string> = {
  [AgentAttentionKind.APPROVAL]: "needs your approval",
  [AgentAttentionKind.QUESTION]: "has a question",
  [AgentAttentionKind.DIALOG]: "is waiting for you",
  [AgentAttentionKind.LIMIT]: "reached a usage limit",
  [AgentAttentionKind.SETUP]: "needs setup",
  [AgentAttentionKind.ERROR]: "stopped with an error",
}

async function pushAttention(row: DbAgentSession, chat: DbChat): Promise<void> {
  const state = decryptAgentSessionState(row.stateEncrypted)
  const attention = state?.attention
  if (!attention || attention.userIds.length === 0) return
  const bot = await UsersModel.getUserById(row.botUserId)
  const name = [bot?.firstName, bot?.lastName].filter(Boolean).join(" ") || "Agent"
  const userIds = attention.userIds.map(Number)
  const dialogSettings = await getInheritedDialogNotificationSettings(chat.id, userIds)
  for (const userId of userIds) {
    // Attention is addressed to these people, so it notifies like a mention:
    // muted chats and "no notifications" stay silent.
    const decision = decideNotification({
      mode: resolveEffectiveNotificationMode({
        globalMode: normalizeGlobalNotificationMode(await getCachedUserSettings(userId)),
        dialogNotificationSettings: dialogSettings.get(userId),
      }),
      isUrgentNudge: false,
      isNudge: false,
      isDM: chat.type === "private",
      isReplyToUser: false,
      isExplicitlyMentioned: true,
    })
    if (!decision.shouldNotify) continue
    try {
      await Notifications.sendToUser({
        userId,
        payload: {
          kind: "alert",
          senderUserId: row.botUserId,
          threadId: `chat_${chat.id}`,
          title: name,
          body: attention.text ?? `${name} ${attentionFallback[attention.kind] ?? "needs you"}`,
          isThread: chat.type === "thread",
          isReplyThread: chat.parentMessageId !== null,
        },
      })
    } catch (error) {
      log.warn("Failed to push agent attention", { sessionId: row.id, userId, error })
    }
  }
}

/**
 * One chat's sessions, or for badges the viewer's sessions that are not idle.
 */
export async function getAgentSessionStates(
  input: GetAgentSessionStatesInput,
  currentUserId: number,
): Promise<GetAgentSessionStatesResult> {
  if (input.peerId) {
    const chat = await ChatModel.getAuthorizedChatFromInputPeer(input.peerId, { currentUserId })
    const rows = await db
      .select()
      .from(agentSessions)
      .where(eq(agentSessions.chatId, chat.id))
      .orderBy(desc(agentSessions.id))
      .limit(MAX_ACTIVE_SESSIONS)
    return { sessions: await Promise.all(rows.map((row) => encodeAgentSessionForViewer(row, chat, currentUserId))) }
  }

  const since = new Date(Date.now() - ACTIVE_STATE_WINDOW_MS)
  const rows = await db
    .select()
    .from(agentSessions)
    .where(and(
      notInArray(agentSessions.runState, [AgentRunState.UNKNOWN, AgentRunState.IDLE, AgentRunState.RELEASED]),
      gt(agentSessions.stateUpdatedAt, since),
    ))
    .orderBy(desc(agentSessions.stateUpdatedAt))
    .limit(MAX_ACTIVE_SESSIONS)
  if (rows.length === 0) return { sessions: [] }

  const chatRows = await db.select().from(chats).where(inArray(chats.id, [...new Set(rows.map((row) => row.chatId))]))
  const chatById = new Map(chatRows.map((chat) => [chat.id, chat]))
  const threadIds = chatRows.filter((chat) => chat.type !== "private").map((chat) => chat.id)
  const access = await getEffectiveChatAccessUserIds(db, threadIds, { userIds: [currentUserId] })
  const visible = rows.filter((row) => {
    const chat = chatById.get(row.chatId)
    if (!chat) return false
    if (chat.type === "private") return chat.minUserId === currentUserId || chat.maxUserId === currentUserId
    return access.get(chat.id)?.has(currentUserId) ?? false
  })
  return {
    sessions: await Promise.all(visible.map((row) => encodeAgentSessionForViewer(row, chatById.get(row.chatId)!, currentUserId))),
  }
}
