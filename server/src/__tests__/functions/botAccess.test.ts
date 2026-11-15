import { describe, expect, test } from "bun:test"
import { AgentGrantOperation, AgentRuntimeStatus, AgentSessionProvider, ContactKind } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { getPeerBots } from "@in/server/functions/bot.getPeerBots"
import { addChatParticipant } from "@in/server/functions/messages.addChatParticipant"
import { getChat } from "@in/server/functions/messages.getChat"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { canMessageBot, getAgentAccess } from "@in/server/modules/agents/access"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { setAgentGrant } from "@in/server/modules/agents/grants"
import { reportAgentRuntime } from "@in/server/modules/agents/runtime"
import { getAgentSettings, updateAgentSettings } from "@in/server/modules/agents/settings"
import { getContacts } from "@in/server/modules/contacts/contacts"
import { searchUsersHandler } from "@in/server/realtime/handlers/users.search"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { MessageModel } from "@in/server/db/models/messages"
import { desc, eq, sql } from "drizzle-orm"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { setupTestLifecycle, testUtils } from "../setup"

const context = (userId: number): any => ({ currentUserId: userId, currentSessionId: 1 })
const noAccess = { code: RealtimeRpcError.Code.AGENT_GRANT_REQUIRED }
const userPeer = (user: schema.DbUser) => ({ type: { oneofKind: "user" as const, user: { userId: BigInt(user.id) } } })
const chatPeer = (chat: schema.DbChat) => ({ type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } })

async function person(name: string) {
  const [user] = await db
    .insert(schema.users)
    .values({ firstName: name, username: name.toLowerCase(), pendingSetup: false })
    .returning()
  return user!
}

async function bot(name: string, owner: schema.DbUser | null) {
  const [user] = await db
    .insert(schema.users)
    .values({
      firstName: name,
      username: `${name.toLowerCase().replace(/\W/g, "_")}_bot`,
      bot: true,
      botCreatorId: owner?.id ?? null,
      pendingSetup: false,
    })
    .returning()
  return user!
}

async function share(botUser: schema.DbUser, owner: schema.DbUser, subject: schema.DbUser) {
  await setAgentGrant(
    { botUserId: BigInt(botUser.id), userId: BigInt(subject.id), operations: [AgentGrantOperation.INVOKE] },
    owner.id,
  )
}

async function openToEveryone(botUser: schema.DbUser, owner: schema.DbUser, open = true) {
  await updateAgentSettings({ botUserId: BigInt(botUser.id), openToEveryone: open }, owner.id)
}

async function thread(title: string, createdBy: schema.DbUser, participants: schema.DbUser[], parentChatId?: number) {
  const chat = await testUtils.createChat(null, title, "thread", false, createdBy.id)
  if (!chat) throw new Error("chat")
  if (parentChatId !== undefined) {
    await db.update(schema.chats).set({ parentChatId }).where(eq(schema.chats.id, chat.id))
  }
  for (const user of participants) await testUtils.addParticipant(chat.id, user.id)
  const [row] = await db.select().from(schema.chats).where(eq(schema.chats.id, chat.id))
  return row!
}

const say = (to: schema.DbUser, from: schema.DbUser, message = "hi") =>
  sendMessage({ peerId: userPeer(to), message }, context(from.id))

describe("who can message a bot", () => {
  setupTestLifecycle()

  test("a new bot takes messages from its owner and its access list only", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const stranger = await person("Stranger")
    const claude = await bot("Mo Claude", mo)
    for (const user of [mo, dena, stranger]) await testUtils.createPrivateChat(user, claude)

    await say(claude, mo)
    await expect(say(claude, dena)).rejects.toMatchObject(noAccess)

    await share(claude, mo, dena)
    await say(claude, dena)
    await expect(say(claude, stranger)).rejects.toMatchObject(noAccess)

    // The bot itself always answers in its DMs.
    await say(stranger, claude, "you asked earlier")
  })

  test("a space or group on the access list covers its current members", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Acme", ["mo@x.com", "zed@x.com"] as const)
    const [mo, zed] = users
    const outsider = await person("Outsider")
    const claude = await bot("Mo Claude", mo)
    await setAgentGrant(
      {
        botUserId: BigInt(claude.id),
        userId: 0n,
        operations: [AgentGrantOperation.INVOKE],
        subject: { subject: { oneofKind: "spaceId", spaceId: BigInt(space.id) } },
      },
      mo.id,
    )
    expect(await canMessageBot(claude, zed.id)).toBe(true)
    expect(await canMessageBot(claude, outsider.id)).toBe(false)

    await db.delete(schema.members).where(eq(schema.members.userId, zed.id))
    expect(await canMessageBot(claude, zed.id)).toBe(false)
  })

  test("a bot reaches another bot through the person it acts for", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const eve = await person("Eve")
    const claude = await bot("Mo Claude", mo)
    const codex = await bot("Mo Codex", mo)
    const denaBot = await bot("Dena Bot", dena)
    const eveBot = await bot("Eve Bot", eve)
    await share(claude, mo, dena)

    expect(await canMessageBot(claude, codex.id, codex)).toBe(true)
    expect(await canMessageBot(claude, denaBot.id, denaBot)).toBe(true)
    expect(await canMessageBot(claude, eveBot.id, eveBot)).toBe(false)
  })

  test("open to everyone is a manager's switch and never a grant", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const stranger = await person("Stranger")
    const hermes = await bot("Team Hermes", mo)
    await testUtils.createPrivateChat(stranger, hermes)
    await share(hermes, mo, dena)

    // Being able to use the bot doesn't let someone decide who reaches it.
    await expect(
      updateAgentSettings({ botUserId: BigInt(hermes.id), openToEveryone: true }, dena.id),
    ).rejects.toMatchObject(noAccess)

    await openToEveryone(hermes, mo)
    await say(hermes, stranger)
    expect((await getAgentSettings({ botUserId: BigInt(hermes.id) }, mo.id)).settings?.openToEveryone).toBe(true)

    // What a bridge asks before starting work on the owner's machine is unchanged.
    expect(await getAgentAccess({ botUserId: BigInt(hermes.id), userId: BigInt(stranger.id), botUserIds: [] }, hermes.id))
      .toMatchObject({ isOwner: false, operations: [] })

    // Changing another setting leaves the switch alone.
    await updateAgentSettings({ botUserId: BigInt(hermes.id), defaultOutputMode: 2 }, mo.id)
    expect(await canMessageBot(hermes, stranger.id)).toBe(true)

    await openToEveryone(hermes, mo, false)
    await expect(say(hermes, stranger)).rejects.toMatchObject(noAccess)
  })

  test("a bot that starts running on a bridge stops being open to everyone", async () => {
    const mo = await person("Mo")
    const stranger = await person("Stranger")
    const codex = await bot("Mo Codex", mo)
    await openToEveryone(codex, mo)
    expect(await canMessageBot(codex, stranger.id)).toBe(true)

    await reportAgentRuntime(
      { provider: AgentSessionProvider.CODEX, status: AgentRuntimeStatus.ONLINE },
      codex.id,
    )
    expect(await canMessageBot(codex, stranger.id)).toBe(false)
    // And it can't be opened again while it runs on a bridge.
    await expect(openToEveryone(codex, mo)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    expect(await canMessageBot(codex, stranger.id)).toBe(false)

    // The bridge is gone: the owner can open the bot, for whatever answers for it now.
    await reportAgentRuntime(
      { provider: AgentSessionProvider.CODEX, status: AgentRuntimeStatus.OFFLINE },
      codex.id,
    )
    await openToEveryone(codex, mo)
    expect(await canMessageBot(codex, stranger.id)).toBe(true)

    // It comes back: private again.
    await reportAgentRuntime(
      { provider: AgentSessionProvider.CODEX, status: AgentRuntimeStatus.ONLINE },
      codex.id,
    )
    expect(await canMessageBot(codex, stranger.id)).toBe(false)
  })

  test("a bot nobody owns stays reachable", async () => {
    const stranger = await person("Stranger")
    const system = await bot("System", null)
    await testUtils.createPrivateChat(stranger, system)
    await say(system, stranger)
  })
})

describe("bots that existed before access lists were enforced", () => {
  setupTestLifecycle()

  test("the migration keeps them reachable, and makes only running bridge bots private", async () => {
    const migration = readFileSync(join(import.meta.dir, "../../../drizzle/0173_bot-open-to-everyone.sql"), "utf8")
    const backfill = migration.split("--> statement-breakpoint")[1]
    if (!backfill?.includes("INSERT INTO")) throw new Error("backfill statement not found")

    const mo = await person("Mo")
    const stranger = await person("Stranger")
    const hermes = await bot("Team Hermes", mo)
    const configured = await bot("Notifier", mo)
    const bridge = await bot("Mo Claude", mo)
    const dormant = await bot("Old Codex", mo)
    const system = await bot("System", null)
    // A plugin bot whose owner already changed a setting keeps that setting.
    await updateAgentSettings({ botUserId: BigInt(configured.id), defaultOutputMode: 2 }, mo.id)
    const runtime = (botUser: schema.DbUser, lastSeenAt: Date) =>
      db.insert(schema.agentRuntimes).values({
        botUserId: botUser.id,
        provider: AgentSessionProvider.CLAUDE,
        status: AgentRuntimeStatus.ONLINE,
        lastSeenAt,
      })
    await runtime(bridge, new Date())
    await runtime(dormant, new Date(Date.now() - 60 * 24 * 60 * 60 * 1000))

    await db.execute(sql.raw(backfill))

    // Hermes, OpenClaw and Bot API bots: anyone who could message them still can.
    expect(await canMessageBot(hermes, stranger.id)).toBe(true)
    expect(await canMessageBot(configured, stranger.id)).toBe(true)
    expect((await getAgentSettings({ botUserId: BigInt(configured.id) }, mo.id)).settings?.defaultOutputMode).toBe(2)
    // A bot whose bridge is long gone may be serving people another way.
    expect(await canMessageBot(dormant, stranger.id)).toBe(true)
    expect(await canMessageBot(system, stranger.id)).toBe(true)
    // A bridge already refused everyone but its owner and access list.
    expect(await canMessageBot(bridge, stranger.id)).toBe(false)
    expect(await canMessageBot(bridge, mo.id)).toBe(true)

    // A bot created after the migration is private.
    const fresh = await bot("New Bot", mo)
    expect(await canMessageBot(fresh, stranger.id)).toBe(false)
  })
})

describe("opening a DM with a bot", () => {
  setupTestLifecycle()

  test("a new DM needs access; an existing one stays readable but takes no messages", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const stranger = await person("Stranger")
    const claude = await bot("Mo Claude", mo)

    await expect(getChat({ peerId: userPeer(claude) }, context(stranger.id))).rejects.toMatchObject(noAccess)
    expect(await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, stranger.id))).toHaveLength(0)

    await share(claude, mo, dena)
    const opened = await getChat({ peerId: userPeer(claude) }, context(dena.id))
    await say(claude, dena)

    const { deleteAgentGrant } = await import("@in/server/modules/agents/grants")
    await deleteAgentGrant({ botUserId: BigInt(claude.id), userId: BigInt(dena.id) }, mo.id)
    const reopened = await getChat({ peerId: userPeer(claude) }, context(dena.id))
    expect(reopened.chat.id).toBe(opened.chat.id)
    await expect(say(claude, dena)).rejects.toMatchObject(noAccess)
  })

  test("someone a bot wrote to can answer it there for a week, and nothing more", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const claude = await bot("Mo Claude", mo)
    const dm = await testUtils.createPrivateChat(dena, claude)
    const access = async () =>
      (await getAgentAccess({ botUserId: 0n, userId: 0n, botUserIds: [BigInt(claude.id)] }, dena.id)).access[0]

    await expect(say(claude, dena)).rejects.toMatchObject(noAccess)
    expect(await access()).toMatchObject({ canMessage: false, canReply: false })

    // The bot asks her something: she can answer, the way a bridge takes a hand-back with no grant.
    await say(dena, claude, "Dena, is the deploy window still Friday?")
    await say(claude, dena, "Yes, Friday.")
    expect(await access()).toMatchObject({ canMessage: false, canReply: true })

    // Answering isn't access: she still can't add the bot to a chat or find it.
    const chat = await thread("Dena's plan", dena, [dena])
    await expect(addChatParticipant({ chatId: chat.id, userId: claude.id }, context(dena.id)))
      .rejects.toMatchObject(noAccess)
    expect(await canMessageBot(claude, dena.id)).toBe(false)

    // A week after the bot's last message the invitation is over.
    await db
      .update(schema.messages)
      .set({ date: new Date(Date.now() - 8 * 24 * 60 * 60 * 1000) })
      .where(eq(schema.messages.chatId, dm!.id))
    await expect(say(claude, dena)).rejects.toMatchObject(noAccess)
    expect(await access()).toMatchObject({ canMessage: false, canReply: false })
  })

  test("a thread under the bot's DM follows the DM", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const claude = await bot("Mo Claude", mo)
    const dm = await testUtils.createPrivateChat(dena, claude)
    const reply = await thread("Earlier question", dena, [dena, claude], dm!.id)
    const send = () => sendMessage({ peerId: chatPeer(reply), message: "still there?" }, context(dena.id))

    await expect(send()).rejects.toMatchObject(noAccess)
    await share(claude, mo, dena)
    await send()
  })
})

describe("finding a bot", () => {
  setupTestLifecycle()

  test("search returns a bot only to people who can reach it, even by exact username", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const stranger = await person("Stranger")
    const claude = await bot("Mo Claude", mo)
    const hermes = await bot("Team Hermes", mo)
    await share(claude, mo, dena)
    await openToEveryone(hermes, mo)
    const found = async (viewer: schema.DbUser, query: string) =>
      (await searchUsersHandler({ query }, { userId: viewer.id } as any)).users.map((user) => Number(user.id))

    expect(await found(mo, "mo_claude_bot")).toEqual([claude.id])
    expect(await found(dena, "mo_claude_bot")).toEqual([claude.id])
    expect(await found(stranger, "mo_claude_bot")).toEqual([])
    expect(await found(stranger, "team_hermes_bot")).toEqual([hermes.id])
    // People are found as before.
    expect(await found(stranger, "dena")).toEqual([dena.id])
  })

  test("a chat's bots, their commands and contacts leave out bots the viewer can't reach", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const claude = await bot("Mo Claude", mo)
    const chat = await thread("Plan", mo, [mo, dena, claude])
    const peerBots = async (viewer: schema.DbUser) =>
      (await getPeerBots({ peerId: chatPeer(chat) }, context(viewer.id))).bots.map((entry) => Number(entry.bot?.id))
    const botContacts = async (viewer: schema.DbUser) =>
      (await getContacts({ kind: ContactKind.BOTS }, viewer)).contacts.map((contact) => Number(contact.userId))

    expect(await peerBots(mo)).toEqual([claude.id])
    expect(await peerBots(dena)).toEqual([])
    expect(await botContacts(dena)).toEqual([])

    await share(claude, mo, dena)
    expect(await peerBots(dena)).toEqual([claude.id])
    expect(await botContacts(dena)).toEqual([claude.id])
  })
})

describe("adding a bot to a chat", () => {
  setupTestLifecycle()

  test("needs access to the bot, by hand or by mention", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const claude = await bot("Mo Claude", mo)
    const chat = await thread("Dena's plan", dena, [dena])
    const add = () => addChatParticipant({ chatId: chat.id, userId: claude.id }, context(dena.id))
    const mention = () =>
      sendMessage(
        {
          peerId: chatPeer(chat),
          message: `[@Claude](inline://user?id=${claude.id}) look at this`,
          parseMarkdown: true,
          addMentionedUsers: true,
        },
        context(dena.id),
      )

    await expect(add()).rejects.toMatchObject(noAccess)
    // Without access it isn't a mention at all, so there is nobody to add.
    expect((await mention()).mentionAdds).toEqual({ addedUserIds: [], unaddedUserIds: [] })
    expect(await AccessGuards.hasChatAccess(chat, claude.id)).toBe(false)

    await share(claude, mo, dena)
    expect((await mention()).mentionAdds).toEqual({ addedUserIds: [claude.id], unaddedUserIds: [] })
  })

  test("a space takes a bot only from someone who can reach it", async () => {
    const { addSpaceMember } = await import("@in/server/functions/space.addMember.shared")
    const { space, users } = await testUtils.createSpaceWithMembers("Acme", ["admin@x.com"] as const)
    const [admin] = users
    await db.update(schema.members).set({ role: "admin" }).where(eq(schema.members.userId, admin.id))
    const mo = await person("Mo")
    const claude = await bot("Mo Claude", mo)
    const add = () =>
      addSpaceMember({
        spaceId: space.id,
        actorUserId: admin.id,
        target: { kind: "userId", userId: claude.id },
        admission: "manageMembers",
      } as any)

    await expect(add()).rejects.toMatchObject(noAccess)
    await share(claude, mo, admin)
    await add()
    const members = await db.select().from(schema.members).where(eq(schema.members.userId, claude.id))
    expect(members).toHaveLength(1)
  })
})

describe("a second admin", () => {
  setupTestLifecycle()

  const admin = [AgentGrantOperation.INVOKE, AgentGrantOperation.STEER, AgentGrantOperation.CONFIGURE]
  const grant = (botUser: schema.DbUser, actor: schema.DbUser, subject: schema.DbUser, operations: AgentGrantOperation[]) =>
    setAgentGrant({ botUserId: BigInt(botUser.id), userId: BigInt(subject.id), operations }, actor.id)

  test("manages everything the owner does except deleting the bot", async () => {
    const { updateBotProfile } = await import("@in/server/functions/bot.updateProfile")
    const { revealBotToken } = await import("@in/server/functions/bot.revealToken")
    const { deleteBot } = await import("@in/server/functions/bot.deleteBot")
    const { deleteAgentGrant, listAgentGrants } = await import("@in/server/modules/agents/grants")
    const mo = await person("Mo")
    const dena = await person("Dena")
    const eve = await person("Eve")
    const zed = await person("Zed")
    const team = await bot("Team Bot", mo)
    await share(team, mo, eve)

    // Someone who only uses the bot manages nothing.
    await expect(grant(team, eve, zed, [AgentGrantOperation.INVOKE])).rejects.toBeInstanceOf(RealtimeRpcError)
    await expect(
      updateBotProfile({ botUserId: BigInt(team.id), name: "Hijacked" }, context(eve.id)),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
    await expect(revealBotToken({ botUserId: BigInt(team.id) }, context(eve.id))).rejects.toBeInstanceOf(RealtimeRpcError)
    expect((await listAgentGrants({ botUserId: BigInt(team.id) }, eve.id)).grants.map((g) => Number(g.userId)))
      .toEqual([eve.id])

    await grant(team, mo, dena, admin)

    // The access list: sees everyone, adds and removes people, appoints another admin.
    expect((await listAgentGrants({ botUserId: BigInt(team.id) }, dena.id)).grants.map((g) => Number(g.userId)).sort())
      .toEqual([dena.id, eve.id].sort())
    await grant(team, dena, zed, admin)
    expect(await canMessageBot(team, zed.id)).toBe(true)
    await deleteAgentGrant({ botUserId: BigInt(team.id), userId: BigInt(eve.id) }, dena.id)
    expect(await canMessageBot(team, eve.id)).toBe(false)

    // Who can message, the profile and the token.
    await openToEveryone(team, dena)
    expect(await canMessageBot(team, eve.id)).toBe(true)
    const renamed = await updateBotProfile({ botUserId: BigInt(team.id), name: "Team Helper" }, context(dena.id))
    expect(renamed.bot?.firstName).toBe("Team Helper")
    expect((await revealBotToken({ botUserId: BigInt(team.id) }, context(dena.id))).token.length).toBeGreaterThan(0)

    // Approving a coding agent's requests stays the owner's to hand out, and so does deleting the bot.
    await expect(grant(team, dena, eve, [AgentGrantOperation.APPROVE])).rejects.toBeInstanceOf(RealtimeRpcError)
    await expect(deleteBot({ botUserId: BigInt(team.id) }, context(dena.id))).rejects.toBeInstanceOf(RealtimeRpcError)

    // Removed as admin: back to nothing.
    await deleteAgentGrant({ botUserId: BigInt(team.id), userId: BigInt(dena.id) }, mo.id)
    await expect(grant(team, dena, eve, [AgentGrantOperation.INVOKE])).rejects.toBeInstanceOf(RealtimeRpcError)
  })

  test("finds the bots they manage next to their own, each with its real owner", async () => {
    const { listBots } = await import("@in/server/functions/bot.listBots")
    const mo = await person("Mo")
    const dena = await person("Dena")
    const denaBot = await bot("Dena Bot", dena)
    const team = await bot("Team Bot", mo)
    const shared = await bot("Mo Claude", mo)
    await grant(team, mo, dena, admin)
    await share(shared, mo, dena)
    const listed = async (includeManaged?: boolean) =>
      (await listBots({ includeManaged }, context(dena.id))).bots.map((entry) => [
        Number(entry.id),
        entry.botInfo?.owner.oneofKind === "ownerUserId" ? Number(entry.botInfo.owner.ownerUserId) : 0,
      ])

    // Older clients ask for their own bots and get exactly those.
    expect(await listed()).toEqual([[denaBot.id, dena.id]])
    // Being able to use a bot isn't managing it.
    expect(await listed(true)).toEqual([[denaBot.id, dena.id], [team.id, mo.id]])
  })

  test("shares the bot with a space they are in, not one only the owner is in", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Acme", ["mo@x.com", "dena@x.com"] as const)
    const [mo, dena] = users
    const other = await testUtils.createSpaceWithMembers("Other", ["solo@x.com"] as const)
    await db.insert(schema.members).values({ spaceId: other.space.id, userId: mo.id, role: "member" })
    const team = await bot("Team Bot", mo)
    await grant(team, mo, dena, admin)
    const shareSpace = (spaceId: number) =>
      setAgentGrant(
        {
          botUserId: BigInt(team.id),
          userId: 0n,
          operations: [AgentGrantOperation.INVOKE],
          subject: { subject: { oneofKind: "spaceId", spaceId: BigInt(spaceId) } },
        },
        dena.id,
      )

    await shareSpace(space.id)
    await expect(shareSpace(other.space.id)).rejects.toBeInstanceOf(RealtimeRpcError)
  })
})

describe("mentioning a bot", () => {
  setupTestLifecycle()

  test("a mention of a bot the sender can't reach is sent as plain text", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const claude = await bot("Mo Claude", mo)
    const chat = await thread("Plan", mo, [mo, dena, claude])
    const mentions = async (sender: schema.DbUser) => {
      await sendMessage(
        {
          peerId: chatPeer(chat),
          message: `[@Claude](inline://user?id=${claude.id}) and [@Mo](inline://user?id=${mo.id}) look`,
          parseMarkdown: true,
        },
        context(sender.id),
      )
      const [latest] = await db
        .select()
        .from(schema.messages)
        .where(eq(schema.messages.chatId, chat.id))
        .orderBy(desc(schema.messages.messageId))
        .limit(1)
      const full = await MessageModel.getMessage(latest!.messageId, chat.id)
      return (full.entities?.entities ?? []).flatMap((entity) =>
        entity.entity.oneofKind === "mention" ? [Number(entity.entity.mention.userId)] : [])
    }

    // The words stay; only the bot's mention stops being one.
    expect(await mentions(dena)).toEqual([mo.id])
    expect(await mentions(mo)).toEqual([claude.id, mo.id])

    await share(claude, mo, dena)
    expect(await mentions(dena)).toEqual([claude.id, mo.id])
  })
})

describe("getAgentAccess for several bots", () => {
  setupTestLifecycle()

  test("answers for the caller, with whether they can message each bot", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const mine = await bot("Dena Bot", dena)
    const shared = await bot("Mo Claude", mo)
    const open = await bot("Team Hermes", mo)
    const closed = await bot("Mo Codex", mo)
    await share(shared, mo, dena)
    await openToEveryone(open, mo)

    const result = await getAgentAccess(
      { botUserId: 0n, userId: 0n, botUserIds: [mine, shared, open, closed, mo].map((user) => BigInt(user.id)).concat(999_999n) },
      dena.id,
    )
    const byBot = new Map(result.access.map((entry) => [Number(entry.botUserId), entry]))

    // People and unknown ids are left out.
    expect([...byBot.keys()].sort()).toEqual([mine.id, shared.id, open.id, closed.id].sort())
    expect(byBot.get(mine.id)).toMatchObject({ isOwner: true, canMessage: true, ownerUserId: BigInt(dena.id) })
    expect(byBot.get(shared.id)).toMatchObject({
      isOwner: false,
      canMessage: true,
      operations: [AgentGrantOperation.INVOKE],
      ownerUserId: BigInt(mo.id),
    })
    expect(byBot.get(open.id)).toMatchObject({ isOwner: false, canMessage: true, operations: [] })
    expect(byBot.get(closed.id)).toMatchObject({ isOwner: false, canMessage: false, operations: [] })

    await expect(
      getAgentAccess({ botUserId: 0n, userId: 0n, botUserIds: Array.from({ length: 201 }, (_, i) => BigInt(i + 1)) }, dena.id),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
  })
})
