import {
  AgentGrantRequirement,
  type GetAgentAccessInput,
  type GetAgentAccessResult,
  type MessageEntities,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import type { Transaction } from "@in/server/db/types"
import { agentSettings, chats, messages, users, type DbChat, type DbUser } from "@in/server/db/schema"
import {
  getAgentAccess as getAgentAccessForUser,
  grantableOperations,
  maskToOperations,
  resolveAgentAccess,
  satisfiesGrantRequirement,
  type AgentAccess,
} from "@in/server/modules/agents/grants"
import { LocalCache } from "@in/server/modules/cache/localCache"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, desc, eq, inArray, or } from "drizzle-orm"

/**
 * Who can reach a bot: message it, open a DM with it, add it to a chat or a
 * space, wake it by mention, and find it in search.
 *
 * The owner and the access list (agent_grants) always can. Everyone can when
 * the owner opened the bot to everyone. A bot is checked as itself plus the
 * person it acts for, like every other grant check.
 *
 * "Open to everyone" is deliberately not a grant. Bridges ask
 * `resolveAgentAccess` who may start work on the owner's machine, and that
 * answer must never widen because the owner let people message the bot.
 */

type Query = Pick<Transaction, "select">

export async function isOpenToEveryone(botUserId: number, query: Query = db): Promise<boolean> {
  const [row] = await query
    .select({ open: agentSettings.openToEveryone })
    .from(agentSettings)
    .where(eq(agentSettings.botUserId, botUserId))
    .limit(1)
  return row?.open === true
}

async function openBotIds(botUserIds: number[]): Promise<Set<number>> {
  if (botUserIds.length === 0) return new Set()
  const rows = await db
    .select({ botUserId: agentSettings.botUserId, open: agentSettings.openToEveryone })
    .from(agentSettings)
    .where(inArray(agentSettings.botUserId, botUserIds))
  return new Set(rows.filter((row) => row.open).map((row) => row.botUserId))
}

export type BotReach = {
  canMessage: boolean
  /** The access list's answer, without the open-to-everyone setting. */
  access: AgentAccess
}

/**
 * How long after a bot writes to someone in their DM they can still answer it
 * there without access. A bot that asks a person something invited the
 * answer; bridges take such a reply with no grant (a hand-back), and the same
 * window keeps a notification bot answerable. It never lets anyone start a
 * conversation, mention the bot or add it anywhere.
 */
const REPLY_WINDOW_MS = 7 * 24 * 60 * 60 * 1000

async function botWroteRecently(chatId: number, botUserId: number): Promise<boolean> {
  const [latest] = await db
    .select({ date: messages.date })
    .from(messages)
    .where(and(eq(messages.chatId, chatId), eq(messages.fromId, botUserId)))
    .orderBy(desc(messages.messageId))
    .limit(1)
  return latest?.date != null && Date.now() - latest.date.getTime() < REPLY_WINDOW_MS
}

/** Writing in a bot's DM, or a thread under it: access, or an answer the bot invited. */
export async function ensureCanWriteInBotDm(dmChatId: number, bot: DbUser, userId: number): Promise<void> {
  if (await canMessageBot(bot, userId)) return
  if (await botWroteRecently(dmChatId, bot.id)) return
  throw RealtimeRpcError.BotAccessRequired()
}

/** The bots among `botUserIds` that wrote to `userId` in their DM recently. */
async function botsThatInvitedReply(botUserIds: number[], userId: number): Promise<Set<number>> {
  if (botUserIds.length === 0) return new Set()
  const dms = await db
    .select({ id: chats.id, minUserId: chats.minUserId, maxUserId: chats.maxUserId })
    .from(chats)
    .where(and(
      eq(chats.type, "private"),
      or(
        and(eq(chats.minUserId, userId), inArray(chats.maxUserId, botUserIds)),
        and(eq(chats.maxUserId, userId), inArray(chats.minUserId, botUserIds)),
      ),
    ))
  const invited = new Set<number>()
  for (const dm of dms) {
    const botUserId = dm.minUserId === userId ? dm.maxUserId : dm.minUserId
    if (botUserId != null && (await botWroteRecently(dm.id, botUserId))) invited.add(botUserId)
  }
  return invited
}

/** A bot with no owner has nobody to keep its list, so it stays reachable. */
function reachOf(bot: DbUser, access: AgentAccess, open: boolean): BotReach {
  const canMessage = bot.botCreatorId == null || access.isOwner || access.operations !== 0 || open
  return { canMessage, access }
}

export async function resolveBotReach(bot: DbUser, userId: number, actor?: DbUser): Promise<BotReach> {
  const access = await resolveAgentAccess(bot, userId, actor)
  if (bot.botCreatorId == null || access.isOwner || access.operations !== 0) return reachOf(bot, access, false)
  return reachOf(bot, access, await isOpenToEveryone(bot.id))
}

/** True for people, for the bot itself and for anyone who can reach the bot. */
export async function canMessageBot(target: DbUser, userId: number, actor?: DbUser): Promise<boolean> {
  if (target.bot !== true || target.id === userId) return true
  if (target.botCreatorId == null || target.botCreatorId === userId) return true
  // The cheap answer first: most bots people message are open or their own.
  if (await isOpenToEveryone(target.id)) return true
  const access = await resolveAgentAccess(target, userId, actor)
  return access.isOwner || access.operations !== 0
}

export async function ensureCanMessageBot(target: DbUser, userId: number, actor?: DbUser): Promise<void> {
  if (!(await canMessageBot(target, userId, actor))) throw RealtimeRpcError.BotAccessRequired()
}

const MAX_THREAD_DEPTH = 8

type RootDm = { chatId: number; minUserId: number; maxUserId: number } | "none"

// Which DM, if any, a thread hangs under. A chat's parent never changes, so
// this is safe to keep; it saves the parent read on every reply-thread send.
const rootDmByChatId = new LocalCache<number, RootDm>({
  ttlMs: 10 * 60_000, negativeTtlMs: 10 * 60_000, maxEntries: 20_000,
})

async function rootDmOf(chat: DbChat): Promise<RootDm> {
  return rootDmByChatId.get(chat.id, async () => {
    let current: DbChat | undefined = chat
    for (let depth = 0; current && current.type !== "private" && depth < MAX_THREAD_DEPTH; depth++) {
      if (current.parentChatId == null) return "none"
      const [parent] = await db.select().from(chats).where(eq(chats.id, current.parentChatId)).limit(1)
      current = parent
    }
    if (!current || current.type !== "private" || current.minUserId == null || current.maxUserId == null) return "none"
    return { chatId: current.id, minUserId: current.minUserId, maxUserId: current.maxUserId }
  })
}

/**
 * A thread under a bot's DM is still that DM for the person in it: writing
 * there, or starting a thread there, needs the same access as the DM. Chats
 * with no parent cost nothing here.
 */
export async function ensureCanWriteUnderBotDm(chat: DbChat, userId: number): Promise<void> {
  if (chat.type !== "private" && chat.parentChatId == null) return
  const root = await rootDmOf(chat)
  // Only the two people of the DM write under it as that DM.
  if (root === "none" || (root.minUserId !== userId && root.maxUserId !== userId)) return
  const peerUserId = root.minUserId === userId ? root.maxUserId : root.minUserId
  if (peerUserId === userId) return
  const peer = await UsersModel.getUserById(peerUserId)
  if (peer?.bot === true) await ensureCanWriteInBotDm(root.chatId, peer, userId)
}

/**
 * Adding a bot to a chat or a space is using it, and puts it in front of
 * everyone there: the actor needs to reach every bot among `userIds`.
 */
export async function ensureCanAddBots(
  actorUserId: number,
  userIds: readonly number[],
  query: Query = db,
): Promise<void> {
  const targets = [...new Set(userIds)].filter((id) => id !== actorUserId)
  if (targets.length === 0) return
  // One indexed read that is empty for the usual all-people case.
  const bots = await query.select().from(users).where(and(inArray(users.id, targets), eq(users.bot, true)))
  if (bots.length === 0) return
  const actor = await UsersModel.getUserById(actorUserId)
  for (const bot of bots) {
    if (UsersModel.isDeleted(bot)) continue
    await ensureCanMessageBot(bot, actorUserId, actor)
  }
}

/** The subset of `targets` the caller can reach. People always pass. */
export async function reachableUsers<T extends { user: DbUser }>(targets: T[], userId: number): Promise<T[]> {
  const actor = targets.some(({ user }) => user.bot === true && user.botCreatorId !== userId)
    ? await UsersModel.getUserById(userId)
    : undefined
  const kept: T[] = []
  for (const target of targets) {
    if (await canMessageBot(target.user, userId, actor)) kept.push(target)
  }
  return kept
}

/** The caller's reach for several bots at once. Unknown, deleted and non-bot ids are left out. */
export async function resolveBotReachForBots(
  botUserIds: number[],
  userId: number,
): Promise<Array<{ bot: DbUser; reach: BotReach; canReply: boolean }>> {
  const ids = [...new Set(botUserIds)]
  if (ids.length === 0) return []
  const [rows, open, actor] = await Promise.all([
    UsersModel.getUsersWithPhotos(ids),
    openBotIds(ids),
    UsersModel.getUserById(userId),
  ])
  const result: Array<{ bot: DbUser; reach: BotReach; canReply: boolean }> = []
  for (const { user: bot } of rows) {
    if (bot.bot !== true || UsersModel.isDeleted(bot)) continue
    const access = await resolveAgentAccess(bot, userId, actor)
    result.push({ bot, reach: reachOf(bot, access, open.has(bot.id)), canReply: false })
  }
  const unreachable = result.filter((entry) => !entry.reach.canMessage)
  const invited = await botsThatInvitedReply(unreachable.map((entry) => entry.bot.id), userId)
  for (const entry of unreachable) entry.canReply = invited.has(entry.bot.id)
  return result
}

const MAX_ACCESS_BOTS = 200

/**
 * `getAgentAccess`: one person's or bot's grants on one bot, or, with
 * `bot_user_ids`, the caller's own access to several bots at once.
 */
export async function getAgentAccess(input: GetAgentAccessInput, currentUserId: number): Promise<GetAgentAccessResult> {
  if (input.botUserIds.length === 0) return getAgentAccessForUser(input, currentUserId)
  if (input.botUserIds.length > MAX_ACCESS_BOTS) throw RealtimeRpcError.BadRequest()
  const ids = input.botUserIds.map(Number).filter((id) => Number.isSafeInteger(id) && id > 0)
  const resolved = await resolveBotReachForBots(ids, currentUserId)
  return {
    isOwner: false,
    operations: [],
    access: resolved.map(({ bot, reach, canReply }) => ({
      botUserId: BigInt(bot.id),
      isOwner: reach.access.isOwner,
      operations: reach.access.isOwner ? [...grantableOperations] : maskToOperations(reach.access.operations),
      ownerUserId: BigInt(reach.access.ownerUserId ?? 0),
      canMessage: reach.canMessage,
      canReply,
    })),
  }
}

/**
 * Who manages a bot: its owner, and the admins the owner (or another admin)
 * appointed, which is a CONFIGURE grant. Admins do everything the owner does
 * except delete the bot and approve its tool requests. A bot never manages
 * another bot through the person it acts for.
 */
export async function canManageBot(bot: DbUser, userId: number): Promise<boolean> {
  if (bot.bot !== true || UsersModel.isDeleted(bot) || bot.botCreatorId == null) return false
  if (bot.botCreatorId === userId) return true
  return satisfiesGrantRequirement(await resolveAgentAccess(bot, userId), AgentGrantRequirement.CONFIGURE)
}

/**
 * Mentioning a bot is addressing it, so a mention of a bot the sender can't
 * reach is sent as plain text. Bots wake only on structured addressing, which
 * makes this hold for every kind of bot: bridges, plugins and Bot API bots.
 * Replying to a bot's own message still reaches it.
 */
export async function dropUnreachableBotMentions(
  entities: MessageEntities | undefined,
  senderUserId: number,
): Promise<MessageEntities | undefined> {
  const mentioned = new Set<number>()
  for (const entity of entities?.entities ?? []) {
    if (entity.entity.oneofKind !== "mention") continue
    const userId = Number(entity.entity.mention.userId)
    if (userId > 0 && userId !== senderUserId) mentioned.add(userId)
  }
  if (!entities || mentioned.size === 0) return entities
  // One indexed read that is empty when only people are mentioned.
  const bots = await db.select().from(users).where(and(inArray(users.id, [...mentioned]), eq(users.bot, true)))
  if (bots.length === 0) return entities
  const sender = await UsersModel.getUserById(senderUserId)
  const unreachable = new Set<number>()
  for (const bot of bots) {
    if (!UsersModel.isDeleted(bot) && !(await canMessageBot(bot, senderUserId, sender))) unreachable.add(bot.id)
  }
  if (unreachable.size === 0) return entities
  return {
    ...entities,
    entities: entities.entities.filter((entity) =>
      entity.entity.oneofKind !== "mention" || !unreachable.has(Number(entity.entity.mention.userId))),
  }
}
