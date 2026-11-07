import {
  AgentGrantOperation,
  ContactKind,
  ContactRelation,
  type Contact,
  type GetContactsInput,
  type GetContactsResult,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import { agentGrants, chatParticipants, chats, members, messages, spaces, users, type DbUser } from "@in/server/db/schema"
import { actingForUserId, maskToOperations, resolveAgentAccess } from "@in/server/modules/agents/grants"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import { encodeDate } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { aliasedTable, and, desc, eq, gt, inArray, isNull, ne, or, sql } from "drizzle-orm"

const log = new Log("contacts")

const DEFAULT_LIMIT = 20
const MAX_LIMIT = 50
/** Recent chats per principal scanned for contacts. Bounds the no-query listing. */
const RECENT_CHATS = 100

/**
 * The people a request is evaluated for: the caller, plus for a bot the person it
 * acts for. Contacts and reach are the union over both.
 */
export function principalsOf(actor: DbUser): { self: number; owner: number | null; ids: number[] } {
  const owner = actingForUserId(actor)
  const ids = owner !== null && owner !== actor.id ? [actor.id, owner] : [actor.id]
  return { self: actor.id, owner: owner !== actor.id ? owner : null, ids }
}

type Candidate = { relations: Set<ContactRelation>; direct: boolean; lastInteraction?: Date }

class Candidates {
  readonly map = new Map<number, Candidate>()
  constructor(private readonly self: number) {}

  add(userId: number, relation: ContactRelation, principal: number, lastInteraction?: Date | null) {
    if (userId === this.self) return
    const candidate = this.map.get(userId) ?? { relations: new Set<ContactRelation>(), direct: false }
    candidate.relations.add(relation)
    if (principal === this.self) candidate.direct = true
    if (lastInteraction && (!candidate.lastInteraction || lastInteraction > candidate.lastInteraction)) {
      candidate.lastInteraction = lastInteraction
    }
    this.map.set(userId, candidate)
  }
}

export async function getContacts(input: GetContactsInput, actor: DbUser): Promise<GetContactsResult> {
  const limit = Math.min(Math.max(input.limit ?? DEFAULT_LIMIT, 1), MAX_LIMIT)
  const query = (input.query ?? "").trim().replace(/^@/, "").toLowerCase()
  if (query.length > 64) throw RealtimeRpcError.BadRequest()
  const kind = input.kind ?? ContactKind.ALL
  const principals = principalsOf(actor)
  const candidates = new Candidates(actor.id)

  if (principals.owner !== null) {
    candidates.add(principals.owner, ContactRelation.OWNER, actor.id)
  }

  await Promise.all([
    addSharedChats(candidates, principals.ids),
    addManagedBots(candidates, principals.ids),
    addGrants(candidates, principals.ids),
    query.length >= 2 ? addSpaceMembers(candidates, principals.ids, query) : Promise.resolve(),
  ])

  const ids = [...candidates.map.keys()]
  const rows = ids.length === 0 ? [] : await UsersModel.getUsersWithPhotos(ids)
  const visible = rows.filter(({ user }) =>
    !UsersModel.isDeleted(user) &&
    user.pendingSetup !== true &&
    (kind !== ContactKind.PEOPLE || user.bot !== true) &&
    (kind !== ContactKind.BOTS || user.bot === true) &&
    (query.length === 0 || matches(user, query)),
  )

  visible.sort((a, b) => rank(candidates.map.get(a.user.id)!, a.user) - rank(candidates.map.get(b.user.id)!, b.user) ||
    (candidates.map.get(b.user.id)!.lastInteraction?.getTime() ?? 0) -
      (candidates.map.get(a.user.id)!.lastInteraction?.getTime() ?? 0) ||
    a.user.id - b.user.id)
  const page = visible.slice(0, limit)

  const contacts: Contact[] = []
  for (const { user } of page) {
    const candidate = candidates.map.get(user.id)!
    let botOperations: AgentGrantOperation[] = []
    let managesBot = false
    if (user.bot === true) {
      managesBot = user.botCreatorId != null && principals.ids.includes(user.botCreatorId)
      const access = await resolveAgentAccess(user, actor.id, actor)
      botOperations = access.isOwner
        ? [AgentGrantOperation.INVOKE, AgentGrantOperation.STEER, AgentGrantOperation.APPROVE, AgentGrantOperation.CONFIGURE]
        : maskToOperations(access.operations)
    }
    contacts.push({
      userId: BigInt(user.id),
      relations: [...candidate.relations].sort((a, b) => a - b),
      viaOwner: !candidate.direct,
      lastInteractionDate: candidate.lastInteraction ? encodeDate(candidate.lastInteraction) : undefined,
      botOperations,
      managesBot,
    })
  }

  return {
    contacts,
    users: page.map(({ user, photoFile }) => encodePublicUser({ user, photoFile }, { includeBotStatus: true })),
  }
}

function matches(user: DbUser, query: string): boolean {
  const name = [user.firstName, user.lastName].filter(Boolean).join(" ").toLowerCase()
  return name.includes(query) || (user.username ?? "").toLowerCase().includes(query)
}

/** The owner and managed bots first, then everyone else by recency. */
function rank(candidate: Candidate, user: DbUser): number {
  if (candidate.relations.has(ContactRelation.OWNER)) return 0
  if (user.bot === true && candidate.relations.has(ContactRelation.MANAGED)) return 1
  return 2
}

async function addSharedChats(candidates: Candidates, principals: number[]) {
  // DMs: the other side of each principal's recent private chats.
  const dms = await db
    .select({ minUserId: chats.minUserId, maxUserId: chats.maxUserId, date: chats.lastUpdateDate })
    .from(chats)
    .where(and(
      eq(chats.type, "private"),
      or(inArray(chats.minUserId, principals), inArray(chats.maxUserId, principals)),
      sql`${chats.lastMsgId} is not null`,
    ))
    .orderBy(desc(chats.lastUpdateDate))
    .limit(RECENT_CHATS * principals.length)
  for (const dm of dms) {
    if (dm.minUserId == null || dm.maxUserId == null) continue
    const principal = principals.includes(dm.minUserId) ? dm.minUserId : dm.maxUserId
    const other = principal === dm.minUserId ? dm.maxUserId : dm.minUserId
    if (principals.includes(other)) continue
    candidates.add(other, ContactRelation.SHARED_CHAT, principal, dm.date)
  }

  // Threads: the other participants of each principal's recent threads.
  const mine = aliasedTable(chatParticipants, "mine")
  const recent = await db
    .select({ chatId: mine.chatId, userId: mine.userId, date: chats.lastUpdateDate })
    .from(mine)
    .innerJoin(chats, eq(chats.id, mine.chatId))
    .where(inArray(mine.userId, principals))
    .orderBy(desc(chats.lastUpdateDate))
    .limit(RECENT_CHATS * principals.length)
  if (recent.length === 0) return
  const principalByChat = new Map<number, { principal: number; date: Date | null }>()
  for (const row of recent) {
    const existing = principalByChat.get(row.chatId)
    // Prefer the caller's own membership over the owner's for the same chat.
    if (!existing || row.userId === principals[0]) principalByChat.set(row.chatId, { principal: row.userId, date: row.date })
  }
  const others = await db
    .select({ chatId: chatParticipants.chatId, userId: chatParticipants.userId })
    .from(chatParticipants)
    .where(inArray(chatParticipants.chatId, [...principalByChat.keys()]))
  for (const row of others) {
    if (principals.includes(row.userId)) continue
    const source = principalByChat.get(row.chatId)!
    candidates.add(row.userId, ContactRelation.SHARED_CHAT, source.principal, source.date)
  }
}

async function addManagedBots(candidates: Candidates, principals: number[]) {
  const rows = await db
    .select({ id: users.id, owner: users.botCreatorId })
    .from(users)
    .where(and(inArray(users.botCreatorId, principals), eq(users.bot, true)))
  for (const row of rows) {
    if (row.owner != null) candidates.add(row.id, ContactRelation.MANAGED, row.owner)
  }
}

async function addGrants(candidates: Candidates, principals: number[]) {
  // Bots whose access list includes a principal.
  const usable = await db
    .select({ botUserId: agentGrants.botUserId, subject: agentGrants.subjectUserId })
    .from(agentGrants)
    .where(and(inArray(agentGrants.subjectUserId, principals), isNull(agentGrants.revokedAt), gt(agentGrants.operations, 0)))
  for (const row of usable) candidates.add(row.botUserId, ContactRelation.CAN_USE, row.subject)

  // People who may use a bot a principal manages.
  const usesYours = await db
    .select({ subject: agentGrants.subjectUserId, owner: users.botCreatorId })
    .from(agentGrants)
    .innerJoin(users, eq(users.id, agentGrants.botUserId))
    .where(and(inArray(users.botCreatorId, principals), isNull(agentGrants.revokedAt), gt(agentGrants.operations, 0)))
  for (const row of usesYours) {
    if (row.owner != null) candidates.add(row.subject, ContactRelation.USES_YOUR_BOT, row.owner)
  }
}

async function addSpaceMembers(candidates: Candidates, principals: number[], query: string) {
  const mine = aliasedTable(members, "mine")
  const pattern = `%${query.replace(/[\\%_]/g, (c) => `\\${c}`)}%`
  const rows = await db
    .select({ userId: members.userId, principal: mine.userId })
    .from(mine)
    .innerJoin(spaces, and(eq(spaces.id, mine.spaceId), isNull(spaces.deleted)))
    .innerJoin(members, eq(members.spaceId, mine.spaceId))
    .innerJoin(users, eq(users.id, members.userId))
    .where(and(
      inArray(mine.userId, principals),
      ne(members.userId, mine.userId),
      or(
        sql`lower(${users.username}) like ${pattern}`,
        sql`lower(concat_ws(' ', ${users.firstName}, ${users.lastName})) like ${pattern}`,
      ),
    ))
    .limit(MAX_LIMIT * 4)
  for (const row of rows) candidates.add(row.userId, ContactRelation.SHARED_SPACE, row.principal)
}

/**
 * Whether `actor` (or, for a bot, the person it acts for) has any tie to `targetUserId`:
 * a shared space, a shared thread, a DM where someone has written, a managed
 * bot, or an access-list entry either way. `ignoreDmChatId` leaves out one DM,
 * so a bot can't make a stranger a contact by opening an empty DM with them.
 */
export async function isContactOf(
  actor: DbUser,
  targetUserId: number,
  options: { ignoreDmChatId?: number } = {},
): Promise<boolean> {
  const principals = principalsOf(actor)
  if (principals.ids.includes(targetUserId)) return true
  const target = await UsersModel.getUserById(targetUserId)
  if (!target || UsersModel.isDeleted(target)) return false
  if (target.botCreatorId != null && principals.ids.includes(target.botCreatorId)) return true

  const checks: Array<() => Promise<boolean>> = [
    async () => {
      const [row] = await db
        .select({ id: chats.id })
        .from(chats)
        .where(and(
          eq(chats.type, "private"),
          sql`${chats.lastMsgId} is not null`,
          or(
            ...principals.ids.map((p) => and(
              eq(chats.minUserId, Math.min(p, targetUserId)),
              eq(chats.maxUserId, Math.max(p, targetUserId)),
            )),
          ),
          options.ignoreDmChatId !== undefined ? ne(chats.id, options.ignoreDmChatId) : undefined,
        ))
        .limit(1)
      return row !== undefined
    },
    async () => {
      const mine = aliasedTable(chatParticipants, "mine")
      const [row] = await db
        .select({ id: mine.id })
        .from(mine)
        .innerJoin(chatParticipants, and(eq(chatParticipants.chatId, mine.chatId), eq(chatParticipants.userId, targetUserId)))
        .where(inArray(mine.userId, principals.ids))
        .limit(1)
      return row !== undefined
    },
    async () => {
      const mine = aliasedTable(members, "mine")
      const [row] = await db
        .select({ id: mine.id })
        .from(mine)
        .innerJoin(spaces, and(eq(spaces.id, mine.spaceId), isNull(spaces.deleted)))
        .innerJoin(members, and(eq(members.spaceId, mine.spaceId), eq(members.userId, targetUserId)))
        .where(inArray(mine.userId, principals.ids))
        .limit(1)
      return row !== undefined
    },
    async () => {
      const [row] = await db
        .select({ id: agentGrants.id })
        .from(agentGrants)
        .innerJoin(users, eq(users.id, agentGrants.botUserId))
        .where(and(
          isNull(agentGrants.revokedAt),
          gt(agentGrants.operations, 0),
          or(
            and(eq(agentGrants.botUserId, targetUserId), inArray(agentGrants.subjectUserId, principals.ids)),
            and(eq(agentGrants.subjectUserId, targetUserId), inArray(users.botCreatorId, principals.ids)),
            and(eq(agentGrants.subjectUserId, targetUserId), inArray(agentGrants.botUserId, principals.ids)),
          ),
        ))
        .limit(1)
      return row !== undefined
    },
  ]
  for (const check of checks) {
    if (await check()) return true
  }
  return false
}

/** Whether the peer has written in this DM, which makes it a conversation they're part of. */
export async function peerHasWrittenIn(chatId: number, peerUserId: number): Promise<boolean> {
  const [row] = await db
    .select({ id: messages.globalId })
    .from(messages)
    .where(and(eq(messages.chatId, chatId), eq(messages.fromId, peerUserId)))
    .limit(1)
  return row !== undefined
}

export type BotReachMode = "enforce" | "observe" | "off"

export function botReachModeFromEnv(env: Record<string, string | undefined> = process.env): BotReachMode {
  const mode = env["BOT_REACH"]
  if (mode === "enforce" || mode === "observe" || mode === "off") return mode
  // Observe first: log who would be blocked before turning it on with BOT_REACH=enforce.
  return "observe"
}

/**
 * Bots start conversations (DM, add to a thread) only with their contacts or
 * their owner's. People are never limited by this.
 */
export async function ensureBotCanReach(
  actor: DbUser,
  targetUserId: number,
  options: { ignoreDmChatId?: number; action: string; mode?: BotReachMode },
): Promise<void> {
  if (actor.bot !== true) return
  const mode = options.mode ?? botReachModeFromEnv()
  if (mode === "off") return
  if (await isContactOf(actor, targetUserId, { ignoreDmChatId: options.ignoreDmChatId })) return
  log.warn("Bot reached outside its contacts", {
    botUserId: actor.id,
    targetUserId,
    action: options.action,
    enforced: mode === "enforce",
  })
  if (mode === "enforce") throw RealtimeRpcError.PeerIdInvalid()
}

/** `ensureBotCanReach` for each new participant, when the actor is a bot. */
export async function ensureBotReachesParticipants(actorUserId: number, userIds: readonly number[], action: string) {
  const targets = userIds.filter((id) => id !== actorUserId)
  if (targets.length === 0) return
  const actor = await UsersModel.getUserById(actorUserId)
  if (actor?.bot !== true) return
  for (const userId of targets) await ensureBotCanReach(actor, userId, { action })
}
