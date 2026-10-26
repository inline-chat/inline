import {
  AgentGrantRequirement,
  AgentOutputMode,
  AgentRuntimeSetup_Reason,
  AgentRuntimeStatus,
  AgentSessionProvider,
  type AgentRuntime,
  type GetAgentRuntimeInput,
  type GetAgentRuntimeResult,
  type ReportAgentRuntimeInput,
  type ReportAgentRuntimeResult,
  type UpdateAgentSettingsInput,
  type UpdateAgentSettingsResult,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UsersModel } from "@in/server/db/models/users"
import type { Transaction } from "@in/server/db/types"
import { agentParticipations, agentRuntimes, agentSessions, chats, type DbAgentRuntime } from "@in/server/db/schema"
import { chatRecipientUserIds } from "@in/server/modules/agents/chatUpdates"
import { Log } from "@in/server/utils/log"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { grantsRevision, resolveAgentAccess, satisfiesGrantRequirement } from "@in/server/modules/agents/grants"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, desc, eq, inArray, lt, ne } from "drizzle-orm"

const log = new Log("Agents.runtime")

export const AGENT_RUNTIME_HEARTBEAT_SECONDS = 60
/** A runtime that missed this many heartbeats counts as offline. */
const MISSED_HEARTBEATS_OFFLINE = 3

function boundedText(value: string | undefined, maxLength: number): string | null {
  if (value === undefined) return null
  const trimmed = value.trim()
  if (trimmed.length === 0) return null
  if (trimmed.length > maxLength) throw RealtimeRpcError.BadRequest()
  return trimmed
}

function validProvider(provider: AgentSessionProvider): boolean {
  return provider >= AgentSessionProvider.CODEX && provider <= AgentSessionProvider.AMP
}

/** Stored status, or offline once heartbeats stop. */
export function effectiveRuntimeStatus(row: Pick<DbAgentRuntime, "status" | "lastSeenAt">, now = Date.now()): AgentRuntimeStatus {
  if (row.status === AgentRuntimeStatus.OFFLINE) return AgentRuntimeStatus.OFFLINE
  const staleAfterMs = AGENT_RUNTIME_HEARTBEAT_SECONDS * MISSED_HEARTBEATS_OFFLINE * 1_000
  return now - row.lastSeenAt.getTime() > staleAfterMs ? AgentRuntimeStatus.OFFLINE : row.status
}

export function encodeAgentRuntime(row: DbAgentRuntime, viewer: "owner" | "other", now = Date.now()): AgentRuntime {
  const owner = viewer === "owner"
  return {
    botUserId: BigInt(row.botUserId),
    provider: row.provider,
    status: effectiveRuntimeStatus(row, now),
    setup: row.setupReason === null
      ? undefined
      : {
          reason: row.setupReason,
          // Fix text can name local paths; others see the reason only.
          text: owner ? row.setupText ?? undefined : undefined,
          minVersion: row.setupMinVersion ?? undefined,
        },
    machineLabel: row.machineLabel ?? undefined,
    executableVersion: row.executableVersion ?? undefined,
    lastSeen: encodeDateStrict(row.lastSeenAt),
    executablePath: owner && row.executablePathEncrypted
      ? Encryption2.decryptToString(row.executablePathEncrypted)
      : undefined,
    manifestHash: owner ? row.manifestHash ?? undefined : undefined,
    bridgeVersion: owner ? row.bridgeVersion ?? undefined : undefined,
    defaultOutputMode: row.defaultOutputMode,
  }
}

export function validOutputMode(mode: AgentOutputMode): boolean {
  return mode >= AgentOutputMode.UNSPECIFIED && mode <= AgentOutputMode.FRIENDLY
}

/** Agent Settings: the owner or a CONFIGURE grantee. The owner and the bot get the change. */
export async function updateAgentSettings(
  input: UpdateAgentSettingsInput,
  currentUserId: number,
): Promise<UpdateAgentSettingsResult> {
  const botUserId = Number(input.botUserId)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  const bot = await UsersModel.getUserById(botUserId)
  if (!bot?.bot || UsersModel.isDeleted(bot) || bot.botCreatorId === null) throw RealtimeRpcError.UserIdInvalid()
  const access = await resolveAgentAccess(bot, currentUserId)
  if (!satisfiesGrantRequirement(access, AgentGrantRequirement.CONFIGURE)) throw RealtimeRpcError.AgentGrantRequired()
  if (input.defaultOutputMode !== undefined && !validOutputMode(input.defaultOutputMode)) throw RealtimeRpcError.BadRequest()

  const ownerUserId = bot.botCreatorId
  // Members of the agent's chats resolve its effective output mode from the
  // default, so they get the change too (status-only view).
  const audience = await runtimeAudience(botUserId, ownerUserId)
  const { row, live } = await db.transaction(async (tx) => {
    const [saved] = await tx
      .update(agentRuntimes)
      .set({
        ...(input.defaultOutputMode === undefined ? {} : { defaultOutputMode: input.defaultOutputMode }),
        updatedAt: new Date(),
      })
      .where(eq(agentRuntimes.botUserId, botUserId))
      .returning()
    // Settings live on the runtime, which exists once the bridge has reported.
    if (!saved) throw RealtimeRpcError.BadRequest()
    return { row: saved, live: await enqueueRuntimeChange(tx, saved, ownerUserId, audience, { includeBot: true }) }
  })
  pushRuntimeChange(live)
  return { runtime: encodeAgentRuntime(row, currentUserId === ownerUserId ? "owner" : "other") }
}

/** Bot heartbeat. Runtime updates reach the owner only when status or setup changes. */
export async function reportAgentRuntime(
  input: ReportAgentRuntimeInput,
  currentUserId: number,
): Promise<ReportAgentRuntimeResult> {
  const bot = await UsersModel.getUserById(currentUserId)
  if (!bot?.bot || UsersModel.isDeleted(bot) || bot.botCreatorId === null) throw RealtimeRpcError.UserIdInvalid()
  if (!validProvider(input.provider)) throw RealtimeRpcError.BadRequest()
  if (
    input.status !== AgentRuntimeStatus.ONLINE &&
    input.status !== AgentRuntimeStatus.OFFLINE &&
    input.status !== AgentRuntimeStatus.NEEDS_SETUP
  ) throw RealtimeRpcError.BadRequest()
  const setup = input.setup
  if (setup && (setup.reason < AgentRuntimeSetup_Reason.UNSPECIFIED || setup.reason > AgentRuntimeSetup_Reason.OTHER)) {
    throw RealtimeRpcError.BadRequest()
  }
  // A setup reason only describes a runtime that needs setup.
  const needsSetup = input.status === AgentRuntimeStatus.NEEDS_SETUP
  const executablePath = boundedText(input.executablePath, 1024)
  const now = new Date()
  const values = {
    provider: input.provider,
    status: input.status,
    setupReason: needsSetup ? setup?.reason ?? AgentRuntimeSetup_Reason.UNSPECIFIED : null,
    setupText: needsSetup ? boundedText(setup?.text, 512) : null,
    setupMinVersion: needsSetup ? boundedText(setup?.minVersion, 64) : null,
    machineLabel: boundedText(input.machineLabel, 128),
    executablePathEncrypted: executablePath === null ? null : Encryption2.encrypt(Buffer.from(executablePath, "utf8")),
    executableVersion: boundedText(input.executableVersion, 64),
    manifestHash: boundedText(input.manifestHash, 128),
    bridgeVersion: boundedText(input.bridgeVersion, 64),
    lastSeenAt: now,
    updatedAt: now,
  }

  const ownerUserId = bot.botCreatorId
  const { row, live } = await db.transaction(async (tx) => {
    const [previous] = await tx.select().from(agentRuntimes).where(eq(agentRuntimes.botUserId, bot.id)).for("update").limit(1)
    const [saved] = previous
      ? await tx.update(agentRuntimes).set(values).where(eq(agentRuntimes.botUserId, bot.id)).returning()
      : await tx.insert(agentRuntimes).values({ botUserId: bot.id, ...values }).returning()
    if (!saved) throw RealtimeRpcError.InternalError()
    const changed = !previous ||
      effectiveRuntimeStatus(previous, now.getTime()) !== saved.status ||
      previous.setupReason !== saved.setupReason ||
      previous.setupText !== saved.setupText ||
      previous.provider !== saved.provider ||
      previous.machineLabel !== saved.machineLabel ||
      previous.executableVersion !== saved.executableVersion
    // The durable updates commit with the change, so a crash cannot drop them
    // while later heartbeats see nothing changed.
    const live = changed
      ? await enqueueRuntimeChange(tx, saved, ownerUserId, await runtimeAudience(bot.id, ownerUserId))
      : []
    return { row: saved, live }
  })

  // Any process that serves heartbeats also watches for lapsed ones.
  startAgentRuntimeSweeper()
  const runtime = encodeAgentRuntime(row, "owner", now.getTime())
  pushRuntimeChange(live)
  return {
    runtime,
    grantsRevision: await grantsRevision(bot.id),
    heartbeatIntervalSeconds: AGENT_RUNTIME_HEARTBEAT_SECONDS,
  }
}

/** Everyone sees status; the owner and the bot also see paths, hashes and fix text. */
export async function getAgentRuntime(
  input: GetAgentRuntimeInput,
  currentUserId: number,
): Promise<GetAgentRuntimeResult> {
  const botUserId = Number(input.botUserId)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  const bot = await UsersModel.getUserById(botUserId)
  if (!bot?.bot || UsersModel.isDeleted(bot)) throw RealtimeRpcError.UserIdInvalid()
  const [row] = await db.select().from(agentRuntimes).where(eq(agentRuntimes.botUserId, botUserId)).limit(1)
  if (!row) return {}
  const viewer = currentUserId === bot.botCreatorId || currentUserId === bot.id ? "owner" : "other"
  return { runtime: encodeAgentRuntime(row, viewer) }
}

// ------------------------------------------------------------
// Runtime changes reach the owner and the agent's chat members
// ------------------------------------------------------------

const MAX_RUNTIME_AUDIENCE_CHATS = 200
const MAX_RUNTIME_AUDIENCE_USERS = 500

/** People in chats where the agent takes part or has work, besides the owner and the bot. */
async function runtimeAudience(botUserId: number, ownerUserId: number): Promise<number[]> {
  const [participating, working] = await Promise.all([
    db.select({ chatId: agentParticipations.chatId }).from(agentParticipations)
      .where(eq(agentParticipations.botUserId, botUserId))
      .orderBy(desc(agentParticipations.updatedAt)).limit(MAX_RUNTIME_AUDIENCE_CHATS),
    db.select({ chatId: agentSessions.chatId }).from(agentSessions)
      .where(eq(agentSessions.botUserId, botUserId))
      .orderBy(desc(agentSessions.updatedAt)).limit(MAX_RUNTIME_AUDIENCE_CHATS),
  ])
  const chatIds = [...new Set([...participating, ...working].map((row) => row.chatId))].slice(0, MAX_RUNTIME_AUDIENCE_CHATS)
  if (chatIds.length === 0) return []
  const chatRows = await db.select().from(chats).where(inArray(chats.id, chatIds))
  const users = new Set<number>()
  for (const chat of chatRows) {
    for (const userId of await chatRecipientUserIds(chat)) {
      if (userId !== ownerUserId && userId !== botUserId) users.add(userId)
      if (users.size >= MAX_RUNTIME_AUDIENCE_USERS) return [...users]
    }
  }
  return [...users]
}

type RuntimeDelivery = { userId: number; runtime: AgentRuntime; durable: UpdateSeqAndDate }

/**
 * Durable user-bucket updates so reconnecting apps render the right status on
 * the first frame: the owner's view to the owner (and the bot, for settings),
 * the status-only view to members of the agent's chats. Enqueued in the
 * transaction that changes the runtime.
 */
async function enqueueRuntimeChange(
  tx: Transaction,
  row: DbAgentRuntime,
  ownerUserId: number,
  audience: number[],
  options: { includeBot?: boolean } = {},
): Promise<RuntimeDelivery[]> {
  const ownerView = encodeAgentRuntime(row, "owner")
  const otherView = encodeAgentRuntime(row, "other")
  const recipients = [
    { userId: ownerUserId, runtime: ownerView },
    ...(options.includeBot && row.botUserId !== ownerUserId ? [{ userId: row.botUserId, runtime: ownerView }] : []),
    ...audience.map((userId) => ({ userId, runtime: otherView })),
  ]
  const deliveries: RuntimeDelivery[] = []
  for (const { userId, runtime } of recipients) {
    const durable = await UserBucketUpdates.enqueue(
      { userId, update: { oneofKind: "userAgentRuntime", userAgentRuntime: { runtime } } },
      { tx },
    )
    deliveries.push({ userId, runtime, durable })
  }
  return deliveries
}

function pushRuntimeChange(deliveries: RuntimeDelivery[]): void {
  for (const { userId, runtime, durable } of deliveries) {
    RealtimeUpdates.pushToUser(userId, [{
      seq: durable.seq,
      date: encodeDateStrict(durable.date),
      update: { oneofKind: "agentRuntime", agentRuntime: { runtime } },
    }])
  }
}

/**
 * Marks runtimes whose heartbeats lapsed as offline and publishes the change.
 * Each lapse is claimed with its durable updates in one transaction, so it is
 * claimed once across server processes and never left unpublished.
 */
export async function sweepLapsedAgentRuntimes(now = Date.now()): Promise<number> {
  const cutoff = new Date(now - AGENT_RUNTIME_HEARTBEAT_SECONDS * MISSED_HEARTBEATS_OFFLINE * 1_000)
  const candidates = await db
    .select({ botUserId: agentRuntimes.botUserId })
    .from(agentRuntimes)
    .where(and(ne(agentRuntimes.status, AgentRuntimeStatus.OFFLINE), lt(agentRuntimes.lastSeenAt, cutoff)))
  let swept = 0
  for (const { botUserId } of candidates) {
    const bot = await UsersModel.getUserById(botUserId)
    if (bot?.botCreatorId == null) continue
    const ownerUserId = bot.botCreatorId
    try {
      const audience = await runtimeAudience(botUserId, ownerUserId)
      const live = await db.transaction(async (tx) => {
        const [row] = await tx
          .update(agentRuntimes)
          .set({ status: AgentRuntimeStatus.OFFLINE, updatedAt: new Date(now) })
          .where(and(
            eq(agentRuntimes.botUserId, botUserId),
            ne(agentRuntimes.status, AgentRuntimeStatus.OFFLINE),
            lt(agentRuntimes.lastSeenAt, cutoff),
          ))
          .returning()
        // Another process claimed it, or a heartbeat arrived meanwhile.
        if (!row) return []
        return enqueueRuntimeChange(tx, row, ownerUserId, audience)
      })
      if (live.length > 0) swept += 1
      pushRuntimeChange(live)
    } catch (error) {
      log.warn("Failed to mark a lapsed agent runtime offline", { botUserId, error })
    }
  }
  return swept
}

let sweepTimer: ReturnType<typeof setInterval> | undefined
let sweepInFlight: Promise<unknown> | undefined

export function startAgentRuntimeSweeper(): void {
  if (sweepTimer) return
  sweepTimer = setInterval(() => {
    if (sweepInFlight) return
    sweepInFlight = sweepLapsedAgentRuntimes()
      .catch((error: unknown) => log.warn("Agent runtime sweep failed", { error }))
      .finally(() => { sweepInFlight = undefined })
  }, AGENT_RUNTIME_HEARTBEAT_SECONDS * 1_000)
  sweepTimer.unref?.()
}

export async function stopAgentRuntimeSweeper(): Promise<void> {
  if (sweepTimer) clearInterval(sweepTimer)
  sweepTimer = undefined
  await sweepInFlight
}
