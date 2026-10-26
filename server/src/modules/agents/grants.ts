import {
  AgentGrantOperation,
  AgentGrantRequirement,
  type AgentGrant,
  type DeleteAgentGrantInput,
  type DeleteAgentGrantResult,
  type ImportAgentGrantsInput,
  type ImportAgentGrantsResult,
  type ListAgentGrantsInput,
  type ListAgentGrantsResult,
  type SetAgentGrantInput,
  type SetAgentGrantResult,
  type Update,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { UsersModel } from "@in/server/db/models/users"
import { agentGrants, type DbAgentGrant, type DbUser } from "@in/server/db/schema"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, eq, isNull, max, sql } from "drizzle-orm"

const MAX_IMPORT_USERS = 256

const nextRevision = () => sql`nextval('agent_grant_revision')`

const grantableOperations = [
  AgentGrantOperation.INVOKE,
  AgentGrantOperation.STEER,
  AgentGrantOperation.APPROVE,
  AgentGrantOperation.VIEW,
  AgentGrantOperation.CONFIGURE,
] as const

/** Operations a bot may grant on itself, as the bridge's /allowlist does. */
const botGrantableMask = maskOf([AgentGrantOperation.INVOKE, AgentGrantOperation.STEER, AgentGrantOperation.VIEW])
const importedMask = maskOf([AgentGrantOperation.INVOKE, AgentGrantOperation.STEER])

function bit(operation: AgentGrantOperation): number {
  return 1 << operation
}

function maskOf(operations: readonly AgentGrantOperation[]): number {
  return operations.reduce((mask, operation) => mask | bit(operation), 0)
}

/** Rejects unknown or unspecified operations instead of silently dropping them. */
export function operationsToMask(operations: readonly AgentGrantOperation[]): number {
  if (operations.length === 0) throw RealtimeRpcError.BadRequest()
  let mask = 0
  for (const operation of operations) {
    if (!(grantableOperations as readonly AgentGrantOperation[]).includes(operation)) {
      throw RealtimeRpcError.BadRequest()
    }
    mask |= bit(operation)
  }
  return mask
}

export function maskToOperations(mask: number): AgentGrantOperation[] {
  return grantableOperations.filter((operation) => (mask & bit(operation)) !== 0)
}

export type AgentAccess = {
  botUserId: number
  ownerUserId: number | null
  isOwner: boolean
  /** Active grant operations for the viewer; 0 without a grant. */
  operations: number
}

/** Owners always qualify. Unknown requirements from newer senders fail closed to owner-only. */
export function satisfiesGrantRequirement(access: AgentAccess, requirement: AgentGrantRequirement): boolean {
  if (requirement === AgentGrantRequirement.NONE) return true
  if (access.isOwner) return true
  switch (requirement) {
    case AgentGrantRequirement.ACCESS:
      return access.operations !== 0
    case AgentGrantRequirement.INVOKE:
      return (access.operations & bit(AgentGrantOperation.INVOKE)) !== 0
    case AgentGrantRequirement.STEER:
      return (access.operations & bit(AgentGrantOperation.STEER)) !== 0
    case AgentGrantRequirement.APPROVE:
      return (access.operations & bit(AgentGrantOperation.APPROVE)) !== 0
    case AgentGrantRequirement.VIEW:
      return (access.operations & bit(AgentGrantOperation.VIEW)) !== 0
    case AgentGrantRequirement.CONFIGURE:
      return (access.operations & bit(AgentGrantOperation.CONFIGURE)) !== 0
    default:
      return false
  }
}

export function isKnownGrantRequirement(requirement: AgentGrantRequirement): boolean {
  return requirement >= AgentGrantRequirement.NONE && requirement <= AgentGrantRequirement.OWNER
}

function activeBotOwner(bot: DbUser | undefined): number | null {
  if (!bot?.bot || UsersModel.isDeleted(bot)) return null
  return bot.botCreatorId ?? null
}

export async function resolveAgentAccess(bot: DbUser, userId: number): Promise<AgentAccess> {
  const ownerUserId = activeBotOwner(bot)
  if (ownerUserId === userId) {
    return { botUserId: bot.id, ownerUserId, isOwner: true, operations: 0 }
  }
  const [row] = await db
    .select({ operations: agentGrants.operations })
    .from(agentGrants)
    .where(and(
      eq(agentGrants.botUserId, bot.id),
      eq(agentGrants.subjectUserId, userId),
      isNull(agentGrants.revokedAt),
    ))
    .limit(1)
  return { botUserId: bot.id, ownerUserId, isOwner: false, operations: row?.operations ?? 0 }
}

export async function grantsRevision(botUserId: number, query: Pick<Transaction, "select"> = db): Promise<bigint> {
  const [row] = await query
    .select({ revision: max(agentGrants.revision) })
    .from(agentGrants)
    .where(eq(agentGrants.botUserId, botUserId))
  return row?.revision ?? 0n
}

function encodeGrant(row: DbAgentGrant): AgentGrant {
  return {
    id: row.id,
    botUserId: BigInt(row.botUserId),
    userId: BigInt(row.subjectUserId),
    operations: maskToOperations(row.operations),
    revision: row.revision,
    grantedBy: row.grantedBy === null ? undefined : BigInt(row.grantedBy),
    date: encodeDateStrict(row.updatedAt),
  }
}

type GrantEditor = { bot: DbUser; ownerUserId: number; actor: "owner" | "bot" }

/** The owner, or the bot itself (the bridge's /allowlist and allowlist import). */
async function grantEditor(botUserIdInput: bigint, currentUserId: number): Promise<GrantEditor> {
  const botUserId = botUserIdInput === 0n ? currentUserId : Number(botUserIdInput)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  const bot = await UsersModel.getUserById(botUserId)
  const ownerUserId = activeBotOwner(bot)
  if (!bot || ownerUserId === null) throw RealtimeRpcError.UserIdInvalid()
  if (currentUserId === ownerUserId) return { bot, ownerUserId, actor: "owner" }
  if (currentUserId === bot.id) return { bot, ownerUserId, actor: "bot" }
  throw RealtimeRpcError.UserIdInvalid()
}

async function validSubject(userIdInput: bigint, editor: GrantEditor): Promise<number> {
  const userId = Number(userIdInput)
  if (!Number.isSafeInteger(userId) || userId <= 0) throw RealtimeRpcError.UserIdInvalid()
  // The owner needs no grant, and a bot's grant on itself means nothing.
  if (userId === editor.ownerUserId || userId === editor.bot.id) throw RealtimeRpcError.BadRequest()
  const subject = await UsersModel.getUserById(userId)
  if (!subject || UsersModel.isDeleted(subject)) throw RealtimeRpcError.UserIdInvalid()
  return userId
}

export async function listAgentGrants(
  input: ListAgentGrantsInput,
  currentUserId: number,
): Promise<ListAgentGrantsResult> {
  const botUserId = input.botUserId === 0n ? currentUserId : Number(input.botUserId)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  const bot = await UsersModel.getUserById(botUserId)
  const ownerUserId = activeBotOwner(bot)
  if (!bot || ownerUserId === null) throw RealtimeRpcError.UserIdInvalid()

  const seesAll = currentUserId === ownerUserId || currentUserId === bot.id
  const rows = await db
    .select()
    .from(agentGrants)
    .where(and(
      eq(agentGrants.botUserId, botUserId),
      isNull(agentGrants.revokedAt),
      seesAll ? undefined : eq(agentGrants.subjectUserId, currentUserId),
    ))
    .orderBy(agentGrants.id)
  return {
    grants: rows.map(encodeGrant),
    // Others learn nothing about the bot's other grants from the revision.
    revision: seesAll ? await grantsRevision(botUserId) : (rows[0]?.revision ?? 0n),
    ownerUserId: BigInt(ownerUserId),
  }
}

export async function setAgentGrant(input: SetAgentGrantInput, currentUserId: number): Promise<SetAgentGrantResult> {
  const editor = await grantEditor(input.botUserId, currentUserId)
  const subjectUserId = await validSubject(input.userId, editor)
  const operations = operationsToMask(input.operations)
  if (editor.actor === "bot" && (operations & ~botGrantableMask) !== 0) throw RealtimeRpcError.UserIdInvalid()

  const live: LiveGrantUpdate[] = []
  const row = await db.transaction(async (tx) => {
    const [saved] = await tx
      .insert(agentGrants)
      .values({
        botUserId: editor.bot.id,
        subjectUserId,
        operations,
        revision: nextRevision(),
        grantedBy: currentUserId,
      })
      .onConflictDoUpdate({
        target: [agentGrants.botUserId, agentGrants.subjectUserId],
        set: {
          operations,
          revision: nextRevision(),
          grantedBy: currentUserId,
          revokedAt: null,
          updatedAt: new Date(),
        },
      })
      .returning()
    if (!saved) throw RealtimeRpcError.InternalError()
    live.push(...await enqueueGrantUpdates(tx, editor, subjectUserId, saved))
    return saved
  })
  publishGrantUpdates(live)
  return { grant: encodeGrant(row), revision: await grantsRevision(editor.bot.id) }
}

export async function deleteAgentGrant(
  input: DeleteAgentGrantInput,
  currentUserId: number,
): Promise<DeleteAgentGrantResult> {
  const editor = await grantEditor(input.botUserId, currentUserId)
  const subjectUserId = Number(input.userId)
  if (!Number.isSafeInteger(subjectUserId) || subjectUserId <= 0) throw RealtimeRpcError.UserIdInvalid()

  const live: LiveGrantUpdate[] = []
  await db.transaction(async (tx) => {
    const [revoked] = await tx
      .update(agentGrants)
      .set({
        operations: 0,
        revision: nextRevision(),
        revokedAt: new Date(),
        updatedAt: new Date(),
      })
      .where(and(
        eq(agentGrants.botUserId, editor.bot.id),
        eq(agentGrants.subjectUserId, subjectUserId),
        isNull(agentGrants.revokedAt),
      ))
      .returning()
    if (revoked) live.push(...await enqueueGrantUpdates(tx, editor, subjectUserId, revoked))
  })
  publishGrantUpdates(live)
  return { revision: await grantsRevision(editor.bot.id) }
}

/**
 * One-time migration of a bridge's allowed_user_ids. It applies only while the
 * bot has never had a grant row, so the owner's later edits always win.
 */
export async function importAgentGrants(
  input: ImportAgentGrantsInput,
  currentUserId: number,
): Promise<ImportAgentGrantsResult> {
  const editor = await grantEditor(0n, currentUserId)
  if (input.userIds.length > MAX_IMPORT_USERS) throw RealtimeRpcError.BadRequest()
  const candidates = [...new Set(input.userIds.map(Number))]
    .filter((id) => Number.isSafeInteger(id) && id > 0 && id !== editor.ownerUserId && id !== editor.bot.id)
  const subjects = candidates.length === 0 ? [] : await UsersModel.getActiveUserIds(candidates)

  const live: LiveGrantUpdate[] = []
  await db.transaction(async (tx) => {
    // Serializes concurrent imports and edits for this bot.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext('agent_grants'), ${editor.bot.id})`)
    const [existing] = await tx
      .select({ id: agentGrants.id })
      .from(agentGrants)
      .where(eq(agentGrants.botUserId, editor.bot.id))
      .limit(1)
    if (existing || subjects.length === 0) return
    const saved = await tx
      .insert(agentGrants)
      .values(subjects.map((subjectUserId) => ({
        botUserId: editor.bot.id,
        subjectUserId,
        operations: importedMask,
        revision: nextRevision(),
        grantedBy: editor.ownerUserId,
      })))
      .onConflictDoNothing()
      .returning()
    for (const row of saved) live.push(...await enqueueGrantUpdates(tx, editor, row.subjectUserId, row))
  })
  publishGrantUpdates(live)

  const rows = await db
    .select()
    .from(agentGrants)
    .where(and(eq(agentGrants.botUserId, editor.bot.id), isNull(agentGrants.revokedAt)))
    .orderBy(agentGrants.id)
  return { grants: rows.map(encodeGrant), revision: await grantsRevision(editor.bot.id) }
}

// ------------------------------------------------------------
// Updates to the owner, the bot and the subject
// ------------------------------------------------------------

type LiveGrantUpdate = { userId: number; update: Update }

/** Durable user-bucket rows inside the transaction; live pushes after commit. */
async function enqueueGrantUpdates(
  tx: Transaction,
  editor: GrantEditor,
  subjectUserId: number,
  row: DbAgentGrant,
): Promise<LiveGrantUpdate[]> {
  const live: LiveGrantUpdate[] = []
  const payload = {
    botUserId: BigInt(editor.bot.id),
    userId: BigInt(subjectUserId),
    grant: row.revokedAt === null ? encodeGrant(row) : undefined,
    revision: row.revision,
  }
  for (const userId of new Set([editor.ownerUserId, editor.bot.id, subjectUserId])) {
    const durable = await UserBucketUpdates.enqueue(
      { userId, update: { oneofKind: "userAgentGrant", userAgentGrant: payload } },
      { tx },
    )
    live.push({
      userId,
      update: {
        seq: durable.seq,
        date: encodeDateStrict(durable.date),
        update: { oneofKind: "agentGrant", agentGrant: payload },
      },
    })
  }
  return live
}

function publishGrantUpdates(live: readonly LiveGrantUpdate[]): void {
  for (const { userId, update } of live) RealtimeUpdates.pushToUser(userId, [update])
}

export const AgentGrants = {
  resolveAccess: resolveAgentAccess,
  satisfies: satisfiesGrantRequirement,
  revision: grantsRevision,
}
