import {
  AgentGrantOperation,
  AgentGrantRequirement,
  type AccessSubject,
  type AgentGrant,
  type DeleteAgentGrantInput,
  type DeleteAgentGrantResult,
  type GetAgentAccessInput,
  type GetAgentAccessResult,
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
import {
  agentGrants,
  members,
  spaces,
  userGroupMembers,
  userGroups,
  type DbAgentGrant,
  type DbUser,
} from "@in/server/db/schema"
import { getCurrentSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { ensureBotCanReach } from "@in/server/modules/contacts/contacts"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { and, eq, inArray, isNotNull, isNull, max, sql } from "drizzle-orm"

const MAX_IMPORT_USERS = 256

const nextRevision = () => sql`nextval('agent_grant_revision')`

/** Serializes every grant write for one bot, so the import's "no rows yet" check never races an edit. */
async function lockBotGrants(tx: Transaction, botUserId: number): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtext('agent_grants'), ${botUserId})`)
}

const grantableOperations = [
  AgentGrantOperation.INVOKE,
  AgentGrantOperation.STEER,
  AgentGrantOperation.APPROVE,
  AgentGrantOperation.CONFIGURE,
] as const

/** Operations a bot may grant on itself, as the bridge's /allowlist does. */
const botGrantableMask = maskOf([AgentGrantOperation.INVOKE, AgentGrantOperation.STEER])
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

/** What a bot can do through the person it acts for: use and steer, never approve or configure. */
export const actingForMask = maskOf([AgentGrantOperation.INVOKE, AgentGrantOperation.STEER])

/** The person a bot acts for, or null for people, deleted bots and ownerless bots. */
export function actingForUserId(actor: DbUser | undefined): number | null {
  return activeBotOwner(actor)
}

/**
 * A person's access, or a bot's: a bot is evaluated as itself plus the person it
 * acts for. What it gets through that person is capped to `actingForMask`, so a
 * bot never approves or configures because its owner may. Same-owner bots fall
 * out of this: the owner manages the target, so the sibling may use and steer it.
 */
export async function resolveAgentAccess(
  bot: DbUser,
  userId: number,
  actor?: DbUser,
): Promise<AgentAccess> {
  const ownerUserId = activeBotOwner(bot)
  if (ownerUserId === userId) {
    return { botUserId: bot.id, ownerUserId, isOwner: true, operations: 0 }
  }
  const actorUser = actor?.id === userId ? actor : await UsersModel.getUserById(userId)
  const actingFor = actingForUserId(actorUser)
  const viaOwner = actingFor !== null && actingFor !== userId && actingFor !== bot.id ? actingFor : null
  const isBot = actorUser?.bot === true

  const rows = await db
    .select({
      subjectUserId: agentGrants.subjectUserId,
      subjectSpaceId: agentGrants.subjectSpaceId,
      subjectGroupId: agentGrants.subjectGroupId,
      operations: agentGrants.operations,
    })
    .from(agentGrants)
    .where(and(eq(agentGrants.botUserId, bot.id), isNull(agentGrants.revokedAt)))

  // Space and group grants reach people only; a bot gets them through its owner.
  const people = [...(isBot ? [] : [userId]), ...(viaOwner === null ? [] : [viaOwner])]
  const memberships = await spaceAndGroupMemberships(people, rows)
  const opsFor = (subject: number) =>
    rows.reduce((mask, row) => {
      const applies =
        row.subjectUserId === subject ||
        (row.subjectSpaceId !== null && memberships.spaces.get(subject)?.has(row.subjectSpaceId) === true) ||
        (row.subjectGroupId !== null && memberships.groups.get(subject)?.has(row.subjectGroupId) === true)
      return applies ? mask | row.operations : mask
    }, 0)

  const own = opsFor(userId)
  const inherited = viaOwner === null
    ? 0
    : viaOwner === ownerUserId
      ? actingForMask
      : opsFor(viaOwner) & actingForMask
  return { botUserId: bot.id, ownerUserId, isOwner: false, operations: own | inherited }
}

/** Which of the grants' spaces and groups each person currently belongs to. */
async function spaceAndGroupMemberships(
  people: number[],
  rows: Array<{ subjectSpaceId: number | null; subjectGroupId: number | null }>,
): Promise<{ spaces: Map<number, Set<number>>; groups: Map<number, Set<number>> }> {
  const spaceIds = [...new Set(rows.flatMap((row) => row.subjectSpaceId === null ? [] : [row.subjectSpaceId]))]
  const groupIds = [...new Set(rows.flatMap((row) => row.subjectGroupId === null ? [] : [row.subjectGroupId]))]
  const result = { spaces: new Map<number, Set<number>>(), groups: new Map<number, Set<number>>() }
  if (people.length === 0) return result
  const add = (map: Map<number, Set<number>>, userId: number, id: number) => {
    const set = map.get(userId) ?? new Set<number>()
    set.add(id)
    map.set(userId, set)
  }
  if (spaceIds.length > 0) {
    const inSpaces = await db
      .select({ userId: members.userId, spaceId: members.spaceId })
      .from(members)
      .innerJoin(spaces, and(eq(spaces.id, members.spaceId), isNull(spaces.deleted)))
      .where(and(inArray(members.spaceId, spaceIds), inArray(members.userId, people)))
    for (const row of inSpaces) add(result.spaces, row.userId, row.spaceId)
  }
  if (groupIds.length > 0) {
    const inGroups = await db
      .select({ userId: userGroupMembers.userId, groupId: userGroupMembers.groupId })
      .from(userGroupMembers)
      .innerJoin(userGroups, eq(userGroups.id, userGroupMembers.groupId))
      .innerJoin(members, and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)))
      .innerJoin(spaces, and(eq(spaces.id, userGroups.spaceId), isNull(spaces.deleted)))
      .where(and(inArray(userGroupMembers.groupId, groupIds), inArray(userGroupMembers.userId, people)))
    for (const row of inGroups) add(result.groups, row.userId, row.groupId)
  }
  return result
}

/** What `userId` may do with a bot, for the bot itself, its owner, or the user asking about themselves. */
export async function getAgentAccess(input: GetAgentAccessInput, currentUserId: number): Promise<GetAgentAccessResult> {
  const botUserId = input.botUserId === 0n ? currentUserId : Number(input.botUserId)
  const userId = Number(input.userId)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  if (!Number.isSafeInteger(userId) || userId <= 0) throw RealtimeRpcError.UserIdInvalid()
  const bot = await UsersModel.getUserById(botUserId)
  const ownerUserId = activeBotOwner(bot)
  if (!bot || ownerUserId === null) throw RealtimeRpcError.UserIdInvalid()
  if (currentUserId !== bot.id && currentUserId !== ownerUserId && currentUserId !== userId) {
    throw RealtimeRpcError.UserIdInvalid()
  }
  const access = await resolveAgentAccess(bot, userId)
  return {
    isOwner: access.isOwner,
    operations: access.isOwner ? [...grantableOperations] : maskToOperations(access.operations),
  }
}

export async function grantsRevision(botUserId: number, query: Pick<Transaction, "select"> = db): Promise<bigint> {
  const [row] = await query
    .select({ revision: max(agentGrants.revision) })
    .from(agentGrants)
    .where(eq(agentGrants.botUserId, botUserId))
  return row?.revision ?? 0n
}

type GrantSubject = { kind: "user" | "space" | "group"; id: number }

function subjectOf(row: Pick<DbAgentGrant, "subjectUserId" | "subjectSpaceId" | "subjectGroupId">): GrantSubject {
  if (row.subjectUserId !== null) return { kind: "user", id: row.subjectUserId }
  if (row.subjectSpaceId !== null) return { kind: "space", id: row.subjectSpaceId }
  return { kind: "group", id: row.subjectGroupId ?? 0 }
}

function encodeSubject(subject: GrantSubject): AccessSubject {
  switch (subject.kind) {
    case "user":
      return { subject: { oneofKind: "userId", userId: BigInt(subject.id) } }
    case "space":
      return { subject: { oneofKind: "spaceId", spaceId: BigInt(subject.id) } }
    case "group":
      return { subject: { oneofKind: "groupId", groupId: BigInt(subject.id) } }
  }
}

function subjectFromInput(subject: AccessSubject | undefined, userId: bigint): GrantSubject {
  const raw = subject?.subject
  const [kind, id]: [GrantSubject["kind"], bigint] =
    raw?.oneofKind === "spaceId" ? ["space", raw.spaceId]
      : raw?.oneofKind === "groupId" ? ["group", raw.groupId]
        : raw?.oneofKind === "userId" ? ["user", raw.userId]
          : ["user", userId]
  const value = Number(id)
  if (!Number.isSafeInteger(value) || value <= 0) throw RealtimeRpcError.BadRequest()
  return { kind, id: value }
}

function subjectColumn(kind: GrantSubject["kind"]) {
  return kind === "user" ? agentGrants.subjectUserId : kind === "space" ? agentGrants.subjectSpaceId : agentGrants.subjectGroupId
}

function subjectValues(subject: GrantSubject) {
  return {
    subjectUserId: subject.kind === "user" ? subject.id : null,
    subjectSpaceId: subject.kind === "space" ? subject.id : null,
    subjectGroupId: subject.kind === "group" ? subject.id : null,
  }
}

function encodeGrant(row: DbAgentGrant): AgentGrant {
  return {
    id: row.id,
    botUserId: BigInt(row.botUserId),
    userId: BigInt(row.subjectUserId ?? 0),
    subject: encodeSubject(subjectOf(row)),
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

async function validSubject(subject: GrantSubject, editor: GrantEditor): Promise<GrantSubject> {
  if (subject.kind === "user") {
    // The owner needs no grant, and a bot's grant on itself means nothing.
    if (subject.id === editor.ownerUserId || subject.id === editor.bot.id) throw RealtimeRpcError.BadRequest()
    const user = await UsersModel.getUserById(subject.id)
    if (!user || UsersModel.isDeleted(user)) throw RealtimeRpcError.UserIdInvalid()
    return subject
  }
  // Only the owner opens a bot to a whole space or group, and only one they're in.
  if (editor.actor !== "owner") throw RealtimeRpcError.UserIdInvalid()
  const spaceId = subject.kind === "space"
    ? subject.id
    : (await db.select({ spaceId: userGroups.spaceId }).from(userGroups).where(eq(userGroups.id, subject.id)).limit(1))[0]?.spaceId
  if (spaceId === undefined) throw RealtimeRpcError.BadRequest()
  if (!(await getCurrentSpaceMembership(spaceId, editor.ownerUserId))) throw RealtimeRpcError.SpaceIdInvalid()
  return subject
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
      input.includeAllSubjects === true ? undefined : isNotNull(agentGrants.subjectUserId),
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
  const subject = await validSubject(subjectFromInput(input.subject, input.userId), editor)
  const operations = operationsToMask(input.operations)
  if (editor.actor === "bot" && (operations & ~botGrantableMask) !== 0) throw RealtimeRpcError.UserIdInvalid()
  // A bot opening itself to someone notifies them, so it may only do that for its contacts.
  if (editor.actor === "bot" && subject.kind === "user") {
    await ensureBotCanReach(editor.bot, subject.id, { action: "grant" })
  }

  const live: LiveGrantUpdate[] = []
  const row = await db.transaction(async (tx) => {
    await lockBotGrants(tx, editor.bot.id)
    const [saved] = await tx
      .insert(agentGrants)
      .values({
        botUserId: editor.bot.id,
        ...subjectValues(subject),
        operations,
        revision: nextRevision(),
        grantedBy: currentUserId,
      })
      .onConflictDoUpdate({
        target: [agentGrants.botUserId, subjectColumn(subject.kind)],
        targetWhere: sql`${subjectColumn(subject.kind)} is not null`,
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
    live.push(...await enqueueGrantUpdates(tx, editor, subject, saved))
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
  const subject = subjectFromInput(input.subject, input.userId)
  if (subject.kind !== "user" && editor.actor !== "owner") throw RealtimeRpcError.UserIdInvalid()

  const live: LiveGrantUpdate[] = []
  await db.transaction(async (tx) => {
    await lockBotGrants(tx, editor.bot.id)
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
        eq(subjectColumn(subject.kind), subject.id),
        isNull(agentGrants.revokedAt),
      ))
      .returning()
    if (revoked) live.push(...await enqueueGrantUpdates(tx, editor, subject, revoked))
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
    await lockBotGrants(tx, editor.bot.id)
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
        // Sent by the bot, so it isn't the owner's choice of who the bot may reach.
        grantedBy: editor.bot.id,
      })))
      .onConflictDoNothing()
      .returning()
    for (const row of saved) live.push(...await enqueueGrantUpdates(tx, editor, subjectOf(row), row))
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
  subject: GrantSubject,
  row: DbAgentGrant,
): Promise<LiveGrantUpdate[]> {
  const live: LiveGrantUpdate[] = []
  const payload = {
    botUserId: BigInt(editor.bot.id),
    userId: BigInt(subject.kind === "user" ? subject.id : 0),
    grant: row.revokedAt === null ? encodeGrant(row) : undefined,
    revision: row.revision,
    subject: encodeSubject(subject),
  }
  // A space or group grant reaches its members through access checks, not updates,
  // and only the bot hears about it: current apps would show it as a grant for user 0.
  const recipients = subject.kind === "user"
    ? [editor.ownerUserId, editor.bot.id, subject.id]
    : [editor.bot.id]
  for (const userId of new Set(recipients)) {
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
  getAccess: getAgentAccess,
  resolveAccess: resolveAgentAccess,
  satisfies: satisfiesGrantRequirement,
  revision: grantsRevision,
}
