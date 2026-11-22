import { AgentRuntimeStatus } from "@inline-chat/protocol/core"
import { agentRuntimes, agentSettings, members, spaces, users } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { grantsRevision, insertSystemGrants, lockBotGrants, revokeSystemGrants, sharedGrantMask, type GrantSubject } from "@in/server/modules/agents/grants"
import { effectiveRuntimeStatus } from "@in/server/modules/agents/runtime"
import { setOpenToEveryoneBySystem } from "@in/server/modules/agents/settings"
import { and, eq, inArray, sql } from "drizzle-orm"
import { DataTaskSkip, defineDataTask, type DataTaskItem, type Json } from "../dataTask"

/**
 * Migration 0173 opened every bot that existed on 2026-11-14 and had no recent
 * bridge to everyone, so old bots kept working once access lists were
 * enforced. Owners never chose that, and "Shared with Everyone" confuses them.
 *
 * For each bot still exactly as 0173 left it (open, never changed by anyone):
 * - keep-open: anyone besides the owner ever wrote to it or in a thread where
 *   it posted. Real people use it, so nothing changes; its owner decides.
 *   Better to leave "Everyone" on a used bot than to cut anyone off.
 * - share-and-close: nobody else ever wrote to it, but it sits in the owner's
 *   private spaces or in threads with other people. Grant those spaces and
 *   people what an app share grants, then close it, so none of them lose it.
 * - close: nobody but the owner ever used it or shares a chat with it.
 *
 * Each item re-runs these rules for its bot when it applies and skips if
 * they no longer give its plan, so a later run replans it. Revert restores
 * "Everyone" only while the owner has changed neither the bot's settings nor
 * its access list since.
 *
 * Production dry run on 2026-11-21: 222 bots; 10 keep-open (bobabot among
 * them), 11 share-and-close (10 space grants, largest space 6 people, and 1
 * person grant), 201 close. The limits below sit just above that, so a cohort
 * that grew or a query that went wrong blocks the run instead of applying.
 */

/**
 * One row per bot in the cohort. "Used by" means a person (not the owner, not
 * a bot) wrote to it in its DM or wrote in a thread where it posted
 * (`usedByOthers`), or is in a thread with it. Shared spaces are private
 * spaces the owner and the bot are both in with someone else. People already covered by a grant, a granted
 * space, or any earlier grant row of their own (a revoke is the owner's
 * choice) are left out.
 */
export const cohortSql = `
with cohort as (
  select s.bot_user_id as bot_id, u.bot_creator_id as owner_id
  from agent_settings s
  join users u on u.id = s.bot_user_id
  where s.open_to_everyone is true
    and s.updated_by is null
    and u.bot is true
    and u.deleted is not true
    and u.bot_creator_id is not null
    /* one bot */
),
humans as (
  select id from users where bot is not true and deleted is not true
),
dm_users as (
  select c.bot_id, m.from_id as user_id, max(m.date) as last_at
  from cohort c
  join chats ch on ch.type = 'private' and c.bot_id in (ch.min_user_id, ch.max_user_id)
  join messages m on m.chat_id = ch.id
  where m.from_id not in (c.bot_id, c.owner_id) and m.from_id in (select id from humans)
  group by 1, 2
),
bot_threads as (
  select distinct c.bot_id, c.owner_id, m.chat_id
  from cohort c
  join messages m on m.from_id = c.bot_id
  join chats ch on ch.id = m.chat_id and ch.type = 'thread'
),
thread_users as (
  select t.bot_id, m.from_id as user_id, max(m.date) as last_at
  from bot_threads t
  join messages m on m.chat_id = t.chat_id
  where m.from_id not in (t.bot_id, t.owner_id) and m.from_id in (select id from humans)
  group by 1, 2
),
participant_users as (
  select c.bot_id, p2.user_id, null::timestamp as last_at
  from cohort c
  join chat_participants p on p.user_id = c.bot_id
  join chats ch on ch.id = p.chat_id and ch.type = 'thread'
  join chat_participants p2 on p2.chat_id = p.chat_id
  where p2.user_id not in (c.bot_id, c.owner_id) and p2.user_id in (select id from humans)
),
used_by as (
  select bot_id, user_id, max(last_at) as last_at
  from (
    select * from dm_users
    union all select * from thread_users
    union all select * from participant_users
  ) x
  group by 1, 2
),
shared_spaces as (
  select c.bot_id, m.space_id
  from cohort c
  join members m on m.user_id = c.bot_id
  join spaces sp on sp.id = m.space_id and sp.is_public is not true and sp.deleted is null
  where exists (select 1 from members o where o.space_id = m.space_id and o.user_id = c.owner_id)
    and exists (
      select 1 from members x join humans h on h.id = x.user_id
      where x.space_id = m.space_id and x.user_id <> c.owner_id
    )
),
to_grant as (
  select u.bot_id, u.user_id
  from used_by u
  where not exists (
      select 1 from agent_grants g
      where g.bot_user_id = u.bot_id and (
        g.subject_user_id = u.user_id
        or (g.revoked_at is null and g.subject_space_id in (select space_id from members where user_id = u.user_id))
        or (g.revoked_at is null and g.subject_group_id in (select group_id from user_group_members where user_id = u.user_id))
      )
    )
    and not exists (
      select 1 from shared_spaces s join members mm on mm.space_id = s.space_id and mm.user_id = u.user_id
      where s.bot_id = u.bot_id
    )
)
select
  c.bot_id::int as "botUserId",
  c.owner_id::int as "ownerUserId",
  coalesce((select array_agg(t.user_id::int order by t.user_id) from to_grant t where t.bot_id = c.bot_id), '{}') as "userIds",
  coalesce((
    select array_agg(s.space_id::int order by s.space_id) from shared_spaces s
    where s.bot_id = c.bot_id
      and not exists (
        select 1 from agent_grants g
        where g.bot_user_id = c.bot_id and g.subject_space_id = s.space_id
      )
  ), '{}') as "spaceIds",
  (
    -- Participants carry no last_at: being in a thread with a bot is not using it.
    select count(*)::int from used_by u where u.bot_id = c.bot_id and u.last_at is not null
  ) as "usedByOthers"
from cohort c
order by c.bot_id
`

const ONE_BOT = "/* one bot */"

/** The cohort query narrowed to one bot, so apply can re-run the plan's own rules on current data. */
function cohortRowSql(botUserId: number) {
  const [head, tail] = cohortSql.split(ONE_BOT)
  return sql.join([sql.raw(head!), sql`and s.bot_user_id = ${botUserId}`, sql.raw(tail!)], sql.raw(" "))
}

export type CohortRow = {
  botUserId: number
  ownerUserId: number
  userIds: number[]
  spaceIds: number[]
  usedByOthers: number
}

type BotPlan = { botUserId: number; ownerUserId: number; userIds: number[]; spaceIds: number[]; usedByOthers: number }

export function itemsFromRows(rows: readonly CohortRow[]): DataTaskItem[] {
  return rows.map((row) => {
    const plan: BotPlan = {
      botUserId: Number(row.botUserId),
      ownerUserId: Number(row.ownerUserId),
      userIds: row.userIds.map(Number),
      spaceIds: row.spaceIds.map(Number),
      usedByOthers: Number(row.usedByOthers),
    }
    const tier = plan.usedByOthers > 0
      ? "keep-open"
      : plan.userIds.length > 0 || plan.spaceIds.length > 0 ? "share-and-close" : "close"
    return { key: `bot:${plan.botUserId}`, tier, noop: tier === "keep-open", plan }
  })
}

function botPlan(value: Json): BotPlan {
  const plan = value as BotPlan
  if (!Number.isSafeInteger(plan?.botUserId) || !Number.isSafeInteger(plan?.ownerUserId)) throw new DataTaskSkip("malformed plan")
  return plan
}

type Applied = { openToEveryone: false; settingsRevision: string; grantsRevision: string; grantIds: string[] }

async function lockedSettings(tx: Transaction, botUserId: number) {
  const [row] = await tx.select().from(agentSettings).where(eq(agentSettings.botUserId, botUserId)).for("update").limit(1)
  return row
}

async function ownedBot(tx: Transaction, plan: BotPlan) {
  const [bot] = await tx.select().from(users).where(eq(users.id, plan.botUserId)).limit(1)
  if (!bot?.bot || bot.deleted === true || bot.botCreatorId !== plan.ownerUserId) throw new DataTaskSkip("bot deleted or owner changed")
  return bot
}

const sameIds = (a: readonly number[], b: readonly number[]) =>
  a.length === b.length && a.every((id, index) => id === Number(b[index]))

/**
 * Re-runs the cohort rules for this bot on current data and skips it unless
 * they still give the reviewed plan: a bot someone used since stays open, and
 * one that left a planned space, a space made public, or a person who got
 * their own grant since all replan on a later run instead of applying stale
 * grants. The planned spaces and the bot's and owner's memberships in them stay
 * locked until commit, so they can't change under the grants.
 */
async function recheckSharing(tx: Transaction, plan: BotPlan): Promise<void> {
  await lockBotGrants(tx, plan.botUserId)
  if (plan.spaceIds.length > 0) {
    await tx.select({ id: spaces.id }).from(spaces).where(inArray(spaces.id, plan.spaceIds)).for("share")
    await tx
      .select({ id: members.id })
      .from(members)
      .where(and(inArray(members.spaceId, plan.spaceIds), inArray(members.userId, [plan.botUserId, plan.ownerUserId])))
      .for("share")
  }
  const [current] = (await tx.execute(cohortRowSql(plan.botUserId))) as unknown as CohortRow[]
  if (!current || Number(current.ownerUserId) !== plan.ownerUserId) throw new DataTaskSkip("left the cohort since the plan")
  if (Number(current.usedByOthers) > 0) throw new DataTaskSkip("used by others since the plan")
  if (!sameIds(plan.userIds, current.userIds) || !sameIds(plan.spaceIds, current.spaceIds)) {
    throw new DataTaskSkip("sharing changed since the plan")
  }
}

const MAX_PERSON_GRANTS = 10
const MAX_SPACE_GRANTS = 20

/** Every planned person and space still reaches the bot through an active grant. */
async function unreachableAfterApply(tx: Transaction, plan: BotPlan): Promise<string | undefined> {
  const [settings] = await tx.select({ open: agentSettings.openToEveryone }).from(agentSettings).where(eq(agentSettings.botUserId, plan.botUserId))
  if (settings?.open !== false) return "bot is still open"
  for (const userId of plan.userIds) {
    const rows = await tx.execute(sql`
      select 1 from users u
      where u.id = ${userId} and (u.deleted is true or exists (
        select 1 from agent_grants g
        where g.bot_user_id = ${plan.botUserId} and g.revoked_at is null and (
          g.subject_user_id = u.id
          or g.subject_space_id in (select space_id from members where user_id = u.id)
        )
      ))`)
    if (rows.length === 0) return `user ${userId} lost access`
  }
  for (const spaceId of plan.spaceIds) {
    const rows = await tx.execute(sql`
      select 1 from spaces sp
      where sp.id = ${spaceId} and (sp.deleted is not null or exists (
        select 1 from agent_grants g
        where g.bot_user_id = ${plan.botUserId} and g.subject_space_id = sp.id and g.revoked_at is null
      ))`)
    if (rows.length === 0) return `space ${spaceId} has no grant`
  }
  return undefined
}

export default defineDataTask({
  id: "2026-11-21-close-grandfathered-bots",
  description: "Close bots migration 0173 opened to everyone that nobody but their owner used; bots others used stay open.",

  limits: {
    maxItems: 240,
    maxPerTier: { close: 230, "share-and-close": 20, "keep-open": 20 },
    maxSkips: 5,
  },

  check(plan) {
    let people = 0
    let spaceGrants = 0
    for (const item of plan.items) {
      const bot = item.plan as BotPlan
      if (item.tier === "keep-open") {
        if (!item.noop || bot.usedByOthers === 0) return `${item.key} is kept open without being used by others`
        continue
      }
      if (bot.usedByOthers > 0) return `${item.key} is used by others but would close`
      people += bot.userIds.length
      spaceGrants += bot.spaceIds.length
      if (item.tier === "share-and-close" && bot.userIds.length + bot.spaceIds.length === 0) return `${item.key} shares with nobody`
      if (item.tier === "close" && bot.userIds.length + bot.spaceIds.length > 0) return `${item.key} closes without its grants`
    }
    if (people > MAX_PERSON_GRANTS) return `${people} person grants exceed ${MAX_PERSON_GRANTS}`
    if (spaceGrants > MAX_SPACE_GRANTS) return `${spaceGrants} space grants exceed ${MAX_SPACE_GRANTS}`
    return undefined
  },

  pauseMs: 50,

  async select(query) {
    const rows = await query.execute(sql.raw(cohortSql))
    return itemsFromRows(rows as unknown as CohortRow[])
  },

  async apply(tx, item) {
    const plan = botPlan(item.plan)
    const settings = await lockedSettings(tx, plan.botUserId)
    if (!settings?.openToEveryone || settings.updatedBy !== null) throw new DataTaskSkip("settings changed since the plan")
    const bot = await ownedBot(tx, plan)
    await recheckSharing(tx, plan)

    const subjects: GrantSubject[] = [
      ...plan.userIds.map((id) => ({ kind: "user" as const, id })),
      ...plan.spaceIds.map((id) => ({ kind: "space" as const, id })),
    ]
    // Grants first, so the settings update reaches the new grantees too.
    const grants = await insertSystemGrants(tx, bot, plan.ownerUserId, subjects, sharedGrantMask)
    const closed = await setOpenToEveryoneBySystem(tx, bot.id, plan.ownerUserId, false)
    const after: Applied = {
      openToEveryone: false,
      settingsRevision: closed.row.revision.toString(),
      // Revert compares it: any later grant edit, a revoke included, keeps the bot closed.
      grantsRevision: (await grantsRevision(bot.id, tx)).toString(),
      grantIds: grants.rows.map((row) => row.id.toString()),
    }
    return {
      before: { openToEveryone: true, settingsRevision: settings.revision.toString() },
      after,
      publish: () => { grants.publish(); closed.publish() },
    }
  },

  verify: (tx, item) => unreachableAfterApply(tx, botPlan(item.plan)),

  async revert(tx, entry) {
    const plan = botPlan(entry.plan)
    const after = entry.after as Applied
    const settings = await lockedSettings(tx, plan.botUserId)
    if (!settings || settings.openToEveryone || settings.revision.toString() !== after.settingsRevision) {
      throw new DataTaskSkip("settings changed since apply")
    }
    // An owner who granted, edited or revoked access since chose who reaches the bot; reopening it would undo that.
    await lockBotGrants(tx, plan.botUserId)
    if ((await grantsRevision(plan.botUserId, tx)).toString() !== after.grantsRevision) {
      throw new DataTaskSkip("access list changed since apply")
    }
    // A running bridge answers only its access list; opening it would show a composer it refuses.
    const [runtime] = await tx.select().from(agentRuntimes).where(eq(agentRuntimes.botUserId, plan.botUserId)).limit(1)
    if (runtime && effectiveRuntimeStatus(runtime) !== AgentRuntimeStatus.OFFLINE) throw new DataTaskSkip("bridge is running")
    const bot = await ownedBot(tx, plan)

    const grants = await revokeSystemGrants(tx, bot, plan.ownerUserId, after.grantIds.map(BigInt))
    const opened = await setOpenToEveryoneBySystem(tx, bot.id, plan.ownerUserId, true)
    return { publish: () => { grants.publish(); opened.publish() } }
  },
})
