import { describe, expect, test } from "bun:test"
import { AgentGrantOperation, ContactKind, ContactRelation } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { actingForMask, resolveAgentAccess } from "@in/server/modules/agents/grants"
import { BOT_CHAIN_LIMIT, botChainExhausted } from "@in/server/modules/agents/botChain"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { ensureBotCanReach, getContacts, isContactOf } from "@in/server/modules/contacts/contacts"
import { foreignBotActivationAllowed } from "@in/server/modules/botUpdates/projector"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const context = (userId: number): any => ({ currentUserId: userId, currentSessionId: 1 })
const bit = (operation: AgentGrantOperation) => 1 << operation

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

async function grant(botUser: schema.DbUser, subject: schema.DbUser, operations: AgentGrantOperation[]) {
  await db.insert(schema.agentGrants).values({
    botUserId: botUser.id,
    subjectUserId: subject.id,
    operations: operations.reduce((mask, op) => mask | bit(op), 0),
    revision: 1n,
  })
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

describe("bots act for their owner", () => {
  setupTestLifecycle()

  test("a bot's owner is public on the user", async () => {
    const mo = await person("Mo")
    const claude = await bot("Claude", mo)
    expect(encodeUser({ user: claude, min: true }).botInfo?.owner).toEqual({
      oneofKind: "ownerUserId",
      ownerUserId: BigInt(mo.id),
    })
    expect(encodeUser({ user: mo, min: true }).botInfo).toBeUndefined()
  })

  test("same-owner and owner-granted bots may use and steer, never approve", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const moClaude = await bot("Mo Claude", mo)
    const moCodex = await bot("Mo Codex", mo)
    const denaCodex = await bot("Dena Codex", dena)
    const eveBot = await bot("Eve Bot", await person("Eve"))

    const sibling = await resolveAgentAccess(moCodex, moClaude.id)
    expect(sibling.isOwner).toBe(false)
    expect(sibling.operations).toBe(actingForMask)

    expect((await resolveAgentAccess(denaCodex, moClaude.id)).operations).toBe(0)
    await grant(denaCodex, mo, [AgentGrantOperation.INVOKE, AgentGrantOperation.APPROVE, AgentGrantOperation.CONFIGURE])
    expect((await resolveAgentAccess(denaCodex, moClaude.id)).operations).toBe(bit(AgentGrantOperation.INVOKE))
    // The person keeps their full grant.
    expect((await resolveAgentAccess(denaCodex, mo.id)).operations & bit(AgentGrantOperation.APPROVE)).not.toBe(0)
    // A bot's own grant isn't capped.
    await grant(denaCodex, moClaude, [AgentGrantOperation.APPROVE])
    expect((await resolveAgentAccess(denaCodex, moClaude.id)).operations).toBe(
      bit(AgentGrantOperation.INVOKE) | bit(AgentGrantOperation.APPROVE),
    )
    expect((await resolveAgentAccess(denaCodex, eveBot.id)).operations).toBe(0)
  })

  test("the bot API wakes a foreign bot when the sender may invoke it", () => {
    const base = { senderBotOwnerId: 1, targetBotOwnerId: 2, recipientUserIds: [1] }
    expect(foreignBotActivationAllowed(base)).toBe(false)
    expect(foreignBotActivationAllowed({ ...base, senderCanInvoke: true })).toBe(true)
    expect(foreignBotActivationAllowed({ ...base, recipientUserIds: [2] })).toBe(true)
  })

  test("bots stop waking each other after a long run without a person", async () => {
    const mo = await person("Mo")
    const a = await bot("A", mo)
    const b = await bot("B", mo)
    const chat = await thread("Loop", mo, [mo, a, b])
    const rows = Array.from({ length: BOT_CHAIN_LIMIT }, (_, i) => ({
      messageId: i + 2,
      chatId: chat.id,
      fromId: i % 2 === 0 ? a.id : b.id,
    }))
    await db.insert(schema.messages).values({ messageId: 1, chatId: chat.id, fromId: mo.id })
    await db.insert(schema.messages).values(rows.slice(0, BOT_CHAIN_LIMIT - 1))
    expect(await botChainExhausted(chat.id)).toBe(false)
    await db.insert(schema.messages).values(rows.slice(BOT_CHAIN_LIMIT - 1))
    expect(await botChainExhausted(chat.id)).toBe(true)
    await db.insert(schema.messages).values({ messageId: BOT_CHAIN_LIMIT + 2, chatId: chat.id, fromId: mo.id })
    expect(await botChainExhausted(chat.id)).toBe(false)
  })
})

describe("contacts", () => {
  setupTestLifecycle()

  test("a bot's contacts are its own plus its owner's", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const sam = await person("Sam")
    const stranger = await person("Stranger")
    const moClaude = await bot("Mo Claude", mo)
    const moCodex = await bot("Mo Codex", mo)
    const denaCodex = await bot("Dena Codex", dena)
    await bot("Stranger Bot", stranger)

    await testUtils.createDMWithDialogAndMessage({ spaceId: null as any, userA: mo, userB: dena })
    await grant(denaCodex, mo, [AgentGrantOperation.INVOKE])
    const shared = await thread("Claude and Sam", moClaude, [moClaude, sam])
    expect(shared).toBeDefined()

    const result = await getContacts({}, moClaude)
    const byId = new Map(result.contacts.map((contact) => [Number(contact.userId), contact]))
    expect(byId.get(mo.id)?.relations).toContain(ContactRelation.OWNER)
    expect(byId.get(moCodex.id)).toMatchObject({ viaOwner: true, managesBot: true })
    expect(byId.get(moCodex.id)?.botOperations).toEqual([AgentGrantOperation.INVOKE, AgentGrantOperation.STEER])
    expect(byId.get(dena.id)).toMatchObject({ viaOwner: true, relations: [ContactRelation.SHARED_CHAT] })
    expect(byId.get(denaCodex.id)?.relations).toContain(ContactRelation.CAN_USE)
    expect(byId.get(denaCodex.id)?.botOperations).toEqual([AgentGrantOperation.INVOKE])
    expect(byId.get(sam.id)).toMatchObject({ viaOwner: false, relations: [ContactRelation.SHARED_CHAT] })
    expect(byId.has(stranger.id)).toBe(false)
    expect(result.contacts[0]?.userId).toBe(BigInt(mo.id))

    const bots = await getContacts({ kind: ContactKind.BOTS, query: "dena" }, moClaude)
    expect(bots.contacts.map((contact) => Number(contact.userId))).toEqual([denaCodex.id])
    expect(bots.users[0]?.botInfo?.owner).toEqual({ oneofKind: "ownerUserId", ownerUserId: BigInt(dena.id) })
  })

  test("space members are contacts when searched", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Acme", ["mo@x.com", "zed@x.com"] as const)
    const [mo, zed] = users
    await db.update(schema.users).set({ firstName: "Zed" }).where(eq(schema.users.id, zed.id))
    const moClaude = await bot("Mo Claude", mo)
    expect(space).toBeDefined()

    expect((await getContacts({}, moClaude)).contacts.some((c) => Number(c.userId) === zed.id)).toBe(false)
    const found = await getContacts({ query: "zed" }, moClaude)
    expect(found.contacts.map((c) => [Number(c.userId), c.relations, c.viaOwner])).toEqual([
      [zed.id, [ContactRelation.SHARED_SPACE], true],
    ])
  })

  test("bots reach only contacts; an empty DM they opened doesn't count", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const stranger = await person("Stranger")
    const moClaude = await bot("Mo Claude", mo)
    await testUtils.createDMWithDialogAndMessage({ spaceId: null as any, userA: mo, userB: dena })

    expect(await isContactOf(moClaude, dena.id)).toBe(true)
    expect(await isContactOf(moClaude, mo.id)).toBe(true)
    expect(await isContactOf(moClaude, stranger.id)).toBe(false)

    const empty = await testUtils.createPrivateChat(moClaude, stranger)
    expect(await isContactOf(moClaude, stranger.id, { ignoreDmChatId: empty!.id })).toBe(false)

    await expect(
      ensureBotCanReach(moClaude, stranger.id, { action: "dm", mode: "enforce" }),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
    await ensureBotCanReach(moClaude, stranger.id, { action: "dm", mode: "observe" })
    await ensureBotCanReach(moClaude, dena.id, { action: "dm", mode: "enforce" })
    // People are never limited.
    await ensureBotCanReach(mo, stranger.id, { action: "dm", mode: "enforce" })
  })
})

describe("owners open their bot's threads read-only", () => {
  setupTestLifecycle()

  test("through a bot in the thread, or in the chat above it; never the DM itself", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const denaCodex = await bot("Dena Codex", dena)
    const moClaude = await bot("Mo Claude", mo)
    const eve = await person("Eve")

    const dm = await testUtils.createPrivateChat(mo, moClaude)
    const reply = await thread("Ask Dena's Codex", moClaude, [moClaude, denaCodex], dm!.id)
    const eveThread = await thread("Eve's", eve, [eve])

    expect(await AccessGuards.hasChatAccess(reply, dena.id)).toBe(false)
    await AccessGuards.ensureChatReadAccess(reply, dena.id)
    await expect(AccessGuards.ensureChatReadAccess(eveThread, dena.id)).rejects.toBeInstanceOf(RealtimeRpcError)

    // A thread under the bot's DM: its owner reads it through the DM peer.
    const child = await thread("Child", moClaude, [], dm!.id)
    await AccessGuards.ensureChatReadAccess(child, mo.id)

    // The bot's DM with someone else stays private to them.
    const denaDm = await testUtils.createPrivateChat(eve, denaCodex)
    await expect(AccessGuards.ensureChatReadAccess(denaDm!, dena.id)).rejects.toBeInstanceOf(RealtimeRpcError)
  })
})

describe("mentioning someone brings them in", () => {
  setupTestLifecycle()

  test("adds mentioned users to a private thread and reports who couldn't be added", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const chat = await thread("Plan", mo, [mo])

    const result = await sendMessage(
      {
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
        message: `[@Dena](inline://user?id=${dena.id}) can you check?`,
        parseMarkdown: true,
        addMentionedUsers: true,
      },
      context(mo.id),
    )
    expect(result.mentionAdds).toEqual({ addedUserIds: [dena.id], unaddedUserIds: [] })
    expect(await AccessGuards.hasChatAccess(chat, dena.id)).toBe(true)

    const sam = await person("Sam")
    const dm = await testUtils.createPrivateChat(mo, dena)
    const inDm = await sendMessage(
      {
        peerId: { type: { oneofKind: "user", user: { userId: BigInt(dena.id) } } },
        message: `[@Sam](inline://user?id=${sam.id}) hi`,
        parseMarkdown: true,
        addMentionedUsers: true,
      },
      context(mo.id),
    )
    expect(dm).toBeDefined()
    expect(inDm.mentionAdds).toEqual({ addedUserIds: [], unaddedUserIds: [sam.id] })
  })
})

describe("getChat through a managed bot", () => {
  setupTestLifecycle()

  test("opens read-only without creating a dialog", async () => {
    const { getChat } = await import("@in/server/functions/messages.getChat")
    const dena = await person("Dena")
    const denaCodex = await bot("Dena Codex", dena)
    const mo = await person("Mo")
    const reply = await thread("Ask", mo, [mo, denaCodex])

    const result = await getChat({ peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(reply.id) } } } }, context(dena.id))
    expect(result.readOnlyViaBotUserId).toBe(denaCodex.id)
    expect(result.dialog).toBeUndefined()
    const dialogs = await db.select().from(schema.dialogs).where(eq(schema.dialogs.userId, dena.id))
    expect(dialogs).toHaveLength(0)

    const own = await getChat({ peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(reply.id) } } } }, context(mo.id))
    expect(own.readOnlyViaBotUserId).toBeUndefined()
  })
})

describe("bot access for a space or a user group", () => {
  setupTestLifecycle()

  const ops = (operations: AgentGrantOperation[]) => operations

  test("members of a granted space or group may use the bot; their bots get it capped", async () => {
    const { deleteAgentGrant, getAgentAccess, listAgentGrants, setAgentGrant } = await import("@in/server/modules/agents/grants")
    const { space, users } = await testUtils.createSpaceWithMembers("Acme", ["dena@acme.com", "mo@acme.com", "zed@acme.com"] as const)
    const [dena, mo, zed] = users
    const outsider = await person("Outsider")
    const denaCodex = await bot("Dena Codex", dena)
    const moClaude = await bot("Mo Claude", mo)
    const strayBot = await bot("Stray", outsider)
    await db.insert(schema.members).values({ spaceId: space.id, userId: strayBot.id, role: "member" })

    await setAgentGrant(
      {
        botUserId: BigInt(denaCodex.id),
        userId: 0n,
        operations: ops([AgentGrantOperation.INVOKE, AgentGrantOperation.APPROVE]),
        subject: { subject: { oneofKind: "spaceId", spaceId: BigInt(space.id) } },
      },
      dena.id,
    )
    expect((await resolveAgentAccess(denaCodex, mo.id)).operations).toBe(
      bit(AgentGrantOperation.INVOKE) | bit(AgentGrantOperation.APPROVE),
    )
    expect((await resolveAgentAccess(denaCodex, moClaude.id)).operations).toBe(bit(AgentGrantOperation.INVOKE))
    expect((await resolveAgentAccess(denaCodex, outsider.id)).operations).toBe(0)
    // A bot in the space doesn't get space grants itself, only through its owner.
    expect((await resolveAgentAccess(denaCodex, strayBot.id)).operations).toBe(0)

    // Older clients see person grants only.
    expect((await listAgentGrants({ botUserId: BigInt(denaCodex.id) }, dena.id)).grants).toHaveLength(0)
    const all = await listAgentGrants({ botUserId: BigInt(denaCodex.id), includeAllSubjects: true }, dena.id)
    expect(all.grants.map((g) => [g.userId, g.subject?.subject])).toEqual([
      [0n, { oneofKind: "spaceId", spaceId: BigInt(space.id) }],
    ])

    expect(await getAgentAccess({ botUserId: BigInt(denaCodex.id), userId: BigInt(moClaude.id) }, moClaude.id)).toEqual({
      isOwner: false,
      operations: [AgentGrantOperation.INVOKE],
    })
    await expect(
      getAgentAccess({ botUserId: BigInt(denaCodex.id), userId: BigInt(mo.id) }, zed.id),
    ).rejects.toBeInstanceOf(RealtimeRpcError)

    const contacts = await getContacts({ kind: ContactKind.BOTS }, moClaude)
    expect(contacts.contacts.find((c) => Number(c.userId) === denaCodex.id)?.relations).toContain(ContactRelation.CAN_USE)

    await deleteAgentGrant(
      { botUserId: BigInt(denaCodex.id), userId: 0n, subject: { subject: { oneofKind: "spaceId", spaceId: BigInt(space.id) } } },
      dena.id,
    )
    expect((await resolveAgentAccess(denaCodex, mo.id)).operations).toBe(0)

    const [group] = await db.insert(schema.userGroups).values({ spaceId: space.id, name: "Eng", createdBy: dena.id }).returning()
    await db.insert(schema.userGroupMembers).values({ groupId: group!.id, userId: zed.id })
    await setAgentGrant(
      {
        botUserId: BigInt(denaCodex.id),
        userId: 0n,
        operations: ops([AgentGrantOperation.INVOKE]),
        subject: { subject: { oneofKind: "groupId", groupId: BigInt(group!.id) } },
      },
      dena.id,
    )
    expect((await resolveAgentAccess(denaCodex, zed.id)).operations).toBe(bit(AgentGrantOperation.INVOKE))
    expect((await resolveAgentAccess(denaCodex, mo.id)).operations).toBe(0)
  })

  test("only the owner opens a bot to a space, and only one they're in", async () => {
    const { setAgentGrant } = await import("@in/server/modules/agents/grants")
    const { space } = await testUtils.createSpaceWithMembers("Other", ["someone@other.com"] as const)
    const dena = await person("Dena")
    const denaCodex = await bot("Dena Codex", dena)
    const subject = { subject: { oneofKind: "spaceId" as const, spaceId: BigInt(space.id) } }
    await expect(
      setAgentGrant({ botUserId: BigInt(denaCodex.id), userId: 0n, operations: [AgentGrantOperation.INVOKE], subject }, dena.id),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
    await db.insert(schema.members).values({ spaceId: space.id, userId: dena.id, role: "member" })
    await expect(
      setAgentGrant({ botUserId: BigInt(denaCodex.id), userId: 0n, operations: [AgentGrantOperation.INVOKE], subject }, denaCodex.id),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
    await setAgentGrant({ botUserId: BigInt(denaCodex.id), userId: 0n, operations: [AgentGrantOperation.INVOKE], subject }, dena.id)
  })
})

describe("review fixes", () => {
  setupTestLifecycle()

  test("a bot can't make a stranger its contact by granting itself to them", async () => {
    const { setAgentGrant } = await import("@in/server/modules/agents/grants")
    const mo = await person("Mo")
    const stranger = await person("Stranger")
    const moClaude = await bot("Mo Claude", mo)

    // Observe mode: the self-grant goes through, but it isn't a tie.
    await setAgentGrant({ botUserId: 0n, userId: BigInt(stranger.id), operations: [AgentGrantOperation.INVOKE] }, moClaude.id)
    expect(await isContactOf(moClaude, stranger.id)).toBe(false)

    // The owner opening the bot to someone is the owner's choice: a tie.
    await setAgentGrant({ botUserId: BigInt(moClaude.id), userId: BigInt(stranger.id), operations: [AgentGrantOperation.INVOKE] }, mo.id)
    expect(await isContactOf(moClaude, stranger.id)).toBe(true)
  })

  test("a bot usable through a space grant is a contact", async () => {
    const { setAgentGrant } = await import("@in/server/modules/agents/grants")
    const { space, users } = await testUtils.createSpaceWithMembers("Acme", ["dena@a.com", "mo@a.com"] as const)
    const [dena, mo] = users
    const denaCodex = await bot("Dena Codex", dena)
    const moClaude = await bot("Mo Claude", mo)
    expect(await isContactOf(moClaude, denaCodex.id)).toBe(false)
    await setAgentGrant(
      {
        botUserId: BigInt(denaCodex.id),
        userId: 0n,
        operations: [AgentGrantOperation.INVOKE],
        subject: { subject: { oneofKind: "spaceId", spaceId: BigInt(space.id) } },
      },
      dena.id,
    )
    expect(await isContactOf(moClaude, denaCodex.id)).toBe(true)
  })

  test("ties that are only the owner's don't tell the bot when", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const moClaude = await bot("Mo Claude", mo)
    await testUtils.createDMWithDialogAndMessage({ spaceId: null as any, userA: mo, userB: dena })
    const result = await getContacts({}, moClaude)
    const row = result.contacts.find((contact) => Number(contact.userId) === dena.id)
    expect(row?.viaOwner).toBe(true)
    expect(row?.lastInteractionDate).toBeUndefined()
  })

  test("a send that fails validation adds nobody", async () => {
    const mo = await person("Mo")
    const dena = await person("Dena")
    const chat = await thread("Plan", mo, [mo])
    await expect(
      sendMessage(
        {
          peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
          message: `[@Dena](inline://user?id=${dena.id}) hi`,
          parseMarkdown: true,
          addMentionedUsers: true,
          botBlockContent: { blocks: [] } as any,
        },
        context(mo.id),
      ),
    ).rejects.toBeInstanceOf(RealtimeRpcError)
    expect(await AccessGuards.hasChatAccess(chat, dena.id)).toBe(false)
  })
})
