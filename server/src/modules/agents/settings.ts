import {
  AgentGrantRequirement,
  AgentOutputMode,
  type AgentSettings,
  type GetAgentSettingsInput,
  type GetAgentSettingsResult,
  type Update,
  type UpdateAgentSettingsInput,
  type UpdateAgentSettingsResult,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import type { Transaction } from "@in/server/db/types"
import { agentGrants, agentRuntimes, agentSettings, type DbAgentSettings, type DbUser } from "@in/server/db/schema"
import { resolveAgentAccess, satisfiesGrantRequirement } from "@in/server/modules/agents/grants"
import {
  encodeAgentRuntime,
  enqueueRuntimeChange,
  pushRuntimeChange,
  runtimeAudience,
} from "@in/server/modules/agents/runtime"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, eq, isNotNull, isNull, sql } from "drizzle-orm"

/** Grantees past this many get the change on their next read instead of a push. */
const MAX_SETTINGS_AUDIENCE_GRANTEES = 500

export function validOutputMode(mode: AgentOutputMode): boolean {
  return mode >= AgentOutputMode.UNSPECIFIED && mode <= AgentOutputMode.FRIENDLY
}

/** A missing row is every setting at its default, revision 0. */
export function encodeAgentSettings(botUserId: number, row: DbAgentSettings | undefined): AgentSettings {
  return {
    botUserId: BigInt(botUserId),
    defaultOutputMode: row?.defaultOutputMode ?? AgentOutputMode.UNSPECIFIED,
    revision: row?.revision ?? 0n,
    date: row ? encodeDateStrict(row.updatedAt) : undefined,
  }
}

export async function loadAgentSettings(
  botUserId: number,
  query: Pick<Transaction, "select"> = db,
): Promise<DbAgentSettings | undefined> {
  const [row] = await query.select().from(agentSettings).where(eq(agentSettings.botUserId, botUserId)).limit(1)
  return row
}

/** Live, owned bots only: settings belong to an owner who can change them. */
async function ownedBotOrThrow(botUserId: number): Promise<DbUser & { botCreatorId: number }> {
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  const bot = await UsersModel.getUserById(botUserId)
  if (!bot?.bot || UsersModel.isDeleted(bot) || bot.botCreatorId === null) throw RealtimeRpcError.UserIdInvalid()
  return bot as DbUser & { botCreatorId: number }
}

/** The bot itself, its owner, or anyone it granted access. */
export async function getAgentSettings(
  input: GetAgentSettingsInput,
  currentUserId: number,
): Promise<GetAgentSettingsResult> {
  const botUserId = input.botUserId === 0n ? currentUserId : Number(input.botUserId)
  const bot = await ownedBotOrThrow(botUserId)
  if (currentUserId !== bot.id) {
    const access = await resolveAgentAccess(bot, currentUserId)
    if (!satisfiesGrantRequirement(access, AgentGrantRequirement.ACCESS)) throw RealtimeRpcError.AgentGrantRequired()
  }
  return { settings: encodeAgentSettings(bot.id, await loadAgentSettings(bot.id)) }
}

/**
 * Agent Settings: the owner or a CONFIGURE grantee, for any owned bot. The
 * runtime's mirror keeps bridges that read the mode from it in step.
 */
export async function updateAgentSettings(
  input: UpdateAgentSettingsInput,
  currentUserId: number,
): Promise<UpdateAgentSettingsResult> {
  const bot = await ownedBotOrThrow(Number(input.botUserId))
  const access = await resolveAgentAccess(bot, currentUserId)
  if (!satisfiesGrantRequirement(access, AgentGrantRequirement.CONFIGURE)) throw RealtimeRpcError.AgentGrantRequired()
  if (input.defaultOutputMode !== undefined && !validOutputMode(input.defaultOutputMode)) throw RealtimeRpcError.BadRequest()

  const ownerUserId = bot.botCreatorId
  const viewer = currentUserId === ownerUserId ? "owner" : "other"
  const [currentRuntime] = await db.select().from(agentRuntimes).where(eq(agentRuntimes.botUserId, bot.id)).limit(1)

  if (input.defaultOutputMode === undefined) {
    return {
      runtime: currentRuntime ? encodeAgentRuntime(currentRuntime, viewer) : undefined,
      settings: encodeAgentSettings(bot.id, await loadAgentSettings(bot.id)),
    }
  }

  const defaultOutputMode = input.defaultOutputMode
  // Members of the agent's chats resolve its effective output mode from the
  // runtime's default, so they get the runtime change too (status-only view).
  const memberAudience = currentRuntime ? await runtimeAudience(bot.id, ownerUserId) : []
  const now = new Date()
  const { saved, runtime, liveRuntime, liveSettings } = await db.transaction(async (tx) => {
    // Legacy setters lock the runtime before the compatibility trigger writes
    // settings. Keep that order during overlap and rollback to avoid deadlocks.
    await tx.select({ botUserId: agentRuntimes.botUserId }).from(agentRuntimes)
      .where(eq(agentRuntimes.botUserId, bot.id)).for("update").limit(1)
    const [saved] = await tx
      .insert(agentSettings)
      .values({ botUserId: bot.id, defaultOutputMode, updatedBy: currentUserId, updatedAt: now })
      .onConflictDoUpdate({
        target: agentSettings.botUserId,
        set: {
          defaultOutputMode,
          updatedBy: currentUserId,
          revision: sql`${agentSettings.revision} + 1`,
          updatedAt: now,
        },
      })
      .returning()
    if (!saved) throw RealtimeRpcError.InternalError()
    const [runtime] = await tx
      .update(agentRuntimes)
      .set({ defaultOutputMode, updatedAt: now })
      .where(eq(agentRuntimes.botUserId, bot.id))
      .returning()
    const liveRuntime = runtime
      ? await enqueueRuntimeChange(tx, runtime, ownerUserId, memberAudience, { includeBot: true })
      : []
    const liveSettings = await enqueueSettingsChange(tx, bot.id, ownerUserId, saved)
    return { saved, runtime, liveRuntime, liveSettings }
  })
  pushRuntimeChange(liveRuntime)
  for (const { userId, update } of liveSettings) RealtimeUpdates.pushToUser(userId, [update])
  return {
    runtime: runtime ? encodeAgentRuntime(runtime, viewer) : undefined,
    settings: encodeAgentSettings(bot.id, saved),
  }
}

/** Durable user-bucket rows for the owner, the bot and its grantees; live pushes after commit. */
async function enqueueSettingsChange(
  tx: Transaction,
  botUserId: number,
  ownerUserId: number,
  row: DbAgentSettings,
): Promise<Array<{ userId: number; update: Update }>> {
  const grantees = await tx
    .select({ userId: agentGrants.subjectUserId })
    .from(agentGrants)
    .where(and(eq(agentGrants.botUserId, botUserId), isNull(agentGrants.revokedAt), isNotNull(agentGrants.subjectUserId)))
    .limit(MAX_SETTINGS_AUDIENCE_GRANTEES)
  const payload = { settings: encodeAgentSettings(botUserId, row) }
  const live: Array<{ userId: number; update: Update }> = []
  for (const userId of new Set([ownerUserId, botUserId, ...grantees.map((grantee) => grantee.userId!)])) {
    const durable = await UserBucketUpdates.enqueue(
      { userId, update: { oneofKind: "userAgentSettings", userAgentSettings: payload } },
      { tx },
    )
    live.push({
      userId,
      update: {
        seq: durable.seq,
        date: encodeDateStrict(durable.date),
        update: { oneofKind: "agentSettings", agentSettings: payload },
      },
    })
  }
  return live
}
