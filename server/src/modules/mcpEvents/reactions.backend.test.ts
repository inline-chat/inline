import { createHash } from "node:crypto"
import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { and, asc, eq, sql } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../../__tests__/setup"
import { db } from "@in/server/db"
import { chats, messages, mcpEventSubscriptions, mcpReactionEvents, oauthGrants, updates, UpdateBucket } from "@in/server/db/schema"
import { ReactionModel } from "@in/server/db/models/reactions"
import { decryptReactionEvent, purgeExpiredReactionEvents } from "@in/server/db/models/mcpReactionEvents"
import { OauthModel } from "@in/server/db/models/oauth"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { oauthConfig } from "@in/server/modules/oauth/config"
import { addReaction } from "@in/server/functions/messages.addReaction"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { deleteReaction } from "@in/server/functions/messages.deleteReaction"
import { handler as legacyAddReaction } from "@in/server/methods/addReaction"
import { validateGrant } from "./authorization"
import { decodeCursor, signature } from "./crypto"
import { executeEventMethod, handleMcpEvents } from "./service"
import { nextOccurrence } from "./source"
import { readSubscription } from "./repository"
import { runMcpEventsOnce } from "./worker"
import type { CallbackTransport } from "./webhook"
import { McpEventsError, type EventOccurrence, type McpEventSelector, type SubscribeResult } from "./types"

const secret = `whsec_${Buffer.alloc(32, 0x42).toString("base64")}`
const delivery = { mode: "webhook", url: "https://receiver.test/reactions", secret }
const received: { body: string; headers: Record<string, string> }[] = []
const receiver = (status = 200, before?: () => Promise<void>): CallbackTransport => async (input) => {
  await before?.()
  await input.beforeConnect?.()
  const body = JSON.parse(input.body) as { type?: string; challenge?: string }
  if (body.type === "verification") return { status: 200, body: JSON.stringify({ challenge: body.challenge }) }
  received.push({ body: input.body, headers: input.headers })
  return { status, body: "" }
}
const due = async (id: string) => { await db.update(mcpEventSubscriptions).set({ nextAttemptAt: new Date(0) }).where(eq(mcpEventSubscriptions.id, id)) }
const event = (index = -1): EventOccurrence => JSON.parse(received.at(index)!.body) as EventOccurrence

async function fixture() {
  received.length = 0
  const owner = await testUtils.createUser("owner@reactions.test")
  const teammate = await testUtils.createUser("teammate@reactions.test")
  const chat = await testUtils.createPrivateChat(owner, teammate)
  if (!chat) throw new Error("Reaction fixture chat missing")
  await testUtils.createTestMessage({ chatId: chat.id, messageId: 1, fromId: owner.id, text: "private message body" })
  const session = await testUtils.createSessionForUser(owner.id)
  await OauthModel.createClient({ clientId: "reaction-client", clientName: "Reaction test", redirectUris: ["https://client.test/callback"], nowMs: Date.now() })
  const grant = await OauthModel.createGrant({ id: "reaction-grant", clientId: "reaction-client", inlineUserId: owner.id,
    scope: "messages:read offline_access", resource: oauthConfig().resource, spaceIds: [], allowDms: true, allowHomeThreads: true,
    inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(session.token)), nowMs: Date.now() })
  const principal = await validateGrant(grant)
  const args = { chatId: String(chat.id) }
  const binding = (name: string, selector: McpEventSelector = args) => ({ grantId: grant.id, name, selector, bucket: { kind: "reaction" as const, entityId: chat.id } })
  const checkpoint = async (name = "reaction.added", selector: McpEventSelector = args) => (await executeEventMethod(principal, "events/cursor", { name, arguments: selector }) as { cursor: string }).cursor
  const subscribe = async (name = "reaction.added", selector: McpEventSelector = args, cursor?: string) => await executeEventMethod(principal, "events/subscribe", {
    name, arguments: selector, delivery, ...(cursor ? { cursor } : {}),
  }, receiver()) as SubscribeResult
  const input = (userId = teammate.id, emoji = "✅", messageId = 1) => ({ chatId: chat.id, messageId, userId, emoji, date: new Date() })
  const rows = async () => db.select().from(mcpReactionEvents).where(eq(mcpReactionEvents.chatId, chat.id)).orderBy(asc(mcpReactionEvents.seq))
  return { owner, teammate, chat, session, grant, principal, args, binding, checkpoint, subscribe, input, rows }
}

describe("MCP reaction transitions with real PostgreSQL", () => {
  setupTestLifecycle()
  const previous = process.env["MCP_REACTION_EVENTS_ENABLED"]
  beforeEach(() => { process.env["MCP_REACTION_EVENTS_ENABLED"] = "true" })
  afterEach(() => {
    if (previous === undefined) delete process.env["MCP_REACTION_EVENTS_ENABLED"]
    else process.env["MCP_REACTION_EVENTS_ENABLED"] = previous
  })

  test("realtime add/remove during registration produce signed minimal encrypted facts without native sequences", async () => {
    const f = await fixture()
    const addCursor = await f.checkpoint()
    const removeCursor = await f.checkpoint("reaction.removed")
    const peer = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(f.chat.id) } } }
    const context = testUtils.functionContext({ userId: f.teammate.id, sessionId: f.session.session.id })
    const [before] = await db.select().from(chats).where(eq(chats.id, f.chat.id))
    expect((await addReaction({ peer, messageId: 1n, emoji: "✅" }, context)).updates).toHaveLength(1)
    expect((await addReaction({ peer, messageId: 1n, emoji: "✅" }, context)).updates).toEqual([])
    expect((await deleteReaction({ peer, messageId: 1n, emoji: "✅" }, context)).updates).toHaveLength(1)
    expect((await deleteReaction({ peer, messageId: 1n, emoji: "✅" }, context)).updates).toEqual([])
    const added = await f.subscribe("reaction.added", f.args, addCursor)
    const removed = await f.subscribe("reaction.removed", f.args, removeCursor)
    expect(added.truncated).toBe(false)
    await runMcpEventsOnce(25, receiver())
    expect(received).toHaveLength(2)
    for (const name of ["reaction.added", "reaction.removed"]) {
      const receipt = received.find((item) => (JSON.parse(item.body) as EventOccurrence).name === name)!
      const occurrence = JSON.parse(receipt.body) as EventOccurrence
      expect(occurrence.data).toEqual({ kind: name === "reaction.added" ? "reaction" : "reactionDeleted", ...f.args,
        messageId: "1", userId: String(f.teammate.id), emoji: "✅" })
      expect(receipt.body).not.toContain("private message body")
      expect(receipt.headers["webhook-signature"]).toBe(signature(secret, occurrence.eventId, Number(receipt.headers["webhook-timestamp"]), receipt.body))
      const sub = await readSubscription(name === "reaction.added" ? added.id : removed.id)
      expect(sub?.pendingEncrypted).toBeNull()
      expect(sub?.cursorSeq).toBe(decodeCursor(occurrence.cursor, f.binding(name)))
    }
    const rows = await f.rows()
    expect(rows.map((row) => row.seq)).toEqual([1, 2])
    expect(rows.every((row) => !row.payloadEncrypted.toString().includes("✅"))).toBe(true)
    const [after] = await db.select().from(chats).where(eq(chats.id, f.chat.id))
    expect(after?.mcpReactionSeq).toBe(2)
    expect(after?.updateSeq).toBe(before?.updateSeq)
    expect(after?.lastUpdateDate).toEqual(before?.lastUpdateDate)
    expect(await db.select().from(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, f.chat.id)))).toEqual([])
    expect(await ReactionModel.getReactions(1n, BigInt(f.chat.id))).toEqual([])
  })

  test("authorized full reads reflect added, removed and deleted-message state", async () => {
    const f = await fixture()
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(f.chat.id) } } }
    const context = testUtils.functionContext({ userId: f.owner.id, sessionId: f.session.session.id })
    await ReactionModel.insertReaction(f.input())
    const current = await getMessages({ peerId, messageIds: [1n] }, context)
    expect(current.messages[0]?.reactions?.reactions).toHaveLength(1)
    expect(current.messages[0]?.reactions?.reactions[0]?.userId).toBe(BigInt(f.teammate.id))
    await ReactionModel.deleteReaction(1n, f.chat.id, "✅", f.teammate.id)
    const removed = await getMessages({ peerId, messageIds: [1n] }, context)
    expect(removed.messages).toHaveLength(1)
    expect(removed.messages[0]?.reactions).toBeUndefined()
    await db.delete(messages).where(and(eq(messages.chatId, f.chat.id), eq(messages.messageId, 1)))
    expect((await getMessages({ peerId, messageIds: [1n] }, context)).messages).toEqual([])
  })

  test("legacy HTTP additions and concurrent retries share one capture position", async () => {
    const f = await fixture()
    await legacyAddReaction({ chatId: String(f.chat.id), messageId: "1", emoji: "👍" }, { currentUserId: f.teammate.id, currentSessionId: f.session.session.id, ip: "127.0.0.1" })
    const results = await Promise.all(Array.from({ length: 12 }, () => ReactionModel.insertReaction(f.input(f.teammate.id, "👍"))))
    expect(results.filter(Boolean)).toHaveLength(0)
    expect((await f.rows()).map((row) => decryptReactionEvent(row.payloadEncrypted).emoji)).toEqual(["👍"])
  })

  test("concurrent add/remove retries serialize transitions and final state agrees with the ordered log", async () => {
    const f = await fixture()
    await ReactionModel.insertReaction(f.input())
    await Promise.all(Array.from({ length: 20 }, (_, i) => i % 2
      ? ReactionModel.insertReaction(f.input()) : ReactionModel.deleteReaction(1n, f.chat.id, "✅", f.teammate.id)))
    const rows = await f.rows()
    expect(rows.map((row) => row.seq)).toEqual(rows.map((_, i) => i + 1))
    const kinds = rows.map((row) => decryptReactionEvent(row.payloadEncrypted).kind)
    expect(kinds).toEqual(kinds.map((_, i) => i % 2 ? "reactionDeleted" : "reaction"))
    expect((await ReactionModel.getReactions(1n, BigInt(f.chat.id))).length).toBe(kinds.at(-1) === "reaction" ? 1 : 0)
  })

  test("event insert failure rolls back state and counter for additions and removals", async () => {
    const f = await fixture()
    await db.execute(sql`CREATE FUNCTION reject_mcp_reaction() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''injected event failure''; END'`)
    await db.execute(sql`CREATE TRIGGER reject_mcp_reaction BEFORE INSERT ON mcp_reaction_events FOR EACH ROW EXECUTE FUNCTION reject_mcp_reaction()`)
    try {
      await expect(ReactionModel.insertReaction(f.input())).rejects.toThrow()
      expect(await f.rows()).toEqual([])
      expect(await ReactionModel.getReactions(1n, BigInt(f.chat.id))).toEqual([])
      expect((await db.select().from(chats).where(eq(chats.id, f.chat.id)))[0]?.mcpReactionSeq).toBe(0)
      await db.execute(sql`ALTER TABLE mcp_reaction_events DISABLE TRIGGER reject_mcp_reaction`)
      await ReactionModel.insertReaction(f.input())
      await db.execute(sql`ALTER TABLE mcp_reaction_events ENABLE TRIGGER reject_mcp_reaction`)
      await expect(ReactionModel.deleteReaction(1n, f.chat.id, "✅", f.teammate.id)).rejects.toThrow()
      expect(await ReactionModel.getReactions(1n, BigInt(f.chat.id))).toHaveLength(1)
      expect(await f.rows()).toHaveLength(1)
      expect((await db.select().from(chats).where(eq(chats.id, f.chat.id)))[0]?.mcpReactionSeq).toBe(1)
    } finally {
      await db.execute(sql`DROP TRIGGER reject_mcp_reaction ON mcp_reaction_events`)
      await db.execute(sql`DROP FUNCTION reject_mcp_reaction()`)
    }
  })

  test("message, exact emoji and actor filters advance past nonmatches before a later match", async () => {
    const f = await fixture()
    await testUtils.createTestMessage({ chatId: f.chat.id, messageId: 2, fromId: f.teammate.id, text: "other" })
    const args = { ...f.args, messageId: "1", emoji: "👍🏽", excludeSelf: true }
    const sub = await f.subscribe("reaction.added", args, await f.checkpoint("reaction.added", args))
    const [stored] = await db.execute<{ emoji: string }>(sql`SELECT selector->>'emoji' AS emoji FROM mcp_event_subscriptions WHERE id = ${sub.id}`)
    expect(stored?.emoji.startsWith("inline-content:v1:")).toBe(true)
    expect(stored?.emoji).not.toContain("👍🏽")
    expect((await readSubscription(sub.id))?.selector).toEqual(args)
    await ReactionModel.insertReaction(f.input(f.owner.id, "👍🏽"))
    await ReactionModel.insertReaction(f.input(f.teammate.id, "👍"))
    await ReactionModel.insertReaction(f.input(f.teammate.id, "👍🏽", 2))
    await runMcpEventsOnce(25, receiver())
    expect(received).toEqual([])
    expect((await readSubscription(sub.id))?.cursorSeq).toBe(3)
    await ReactionModel.insertReaction(f.input(f.teammate.id, "👍🏽"))
    await due(sub.id)
    await runMcpEventsOnce(25, receiver())
    expect(event().data).toMatchObject({ userId: String(f.teammate.id), messageId: "1", emoji: "👍🏽" })
    expect((await readSubscription(sub.id))?.cursorSeq).toBe(4)
  })

  test("remove/add/remove remains separate occurrences with removal-time timestamps", async () => {
    const f = await fixture()
    await ReactionModel.insertReaction({ ...f.input(), date: new Date(0) })
    const cursor = await f.checkpoint("reaction.removed")
    await ReactionModel.deleteReaction(1n, f.chat.id, "✅", f.teammate.id)
    await ReactionModel.insertReaction(f.input())
    await ReactionModel.deleteReaction(1n, f.chat.id, "✅", f.teammate.id)
    const sub = await f.subscribe("reaction.removed", f.args, cursor)
    await runMcpEventsOnce(25, receiver())
    expect(Date.parse(event().timestamp)).toBeGreaterThan(Date.now() - 60_000)
    expect((await readSubscription(sub.id))?.cursorSeq).toBe(2)
    await runMcpEventsOnce(25, receiver())
    expect(received).toHaveLength(2)
    expect((await readSubscription(sub.id))?.cursorSeq).toBe(4)
    expect(event(0).eventId).not.toBe(event(1).eventId)
  })

  test("pending retries survive full source expiry and renewal preserves bytes and ID", async () => {
    const f = await fixture()
    const sub = await f.subscribe()
    await ReactionModel.insertReaction(f.input())
    await runMcpEventsOnce(25, receiver(503))
    const first = received[0]!
    await db.update(mcpReactionEvents).set({ occurredAt: new Date(0) })
    expect(await purgeExpiredReactionEvents()).toBe(1)
    const renewal = await f.subscribe("reaction.added", f.args, await f.checkpoint())
    expect(renewal.truncated).toBe(false)
    expect(decodeCursor(renewal.cursor, f.binding("reaction.added"))).toBe(0)
    await due(sub.id)
    await runMcpEventsOnce(25, receiver())
    expect(received[1]?.body).toBe(first.body)
    expect(received[1]?.headers["webhook-id"]).toBe(first.headers["webhook-id"])
    expect((await readSubscription(sub.id))?.cursorSeq).toBe(1)
  })

  test("full expiry gaps before filters, pauses, then refreshes with truncation; bounded cleanup catches holes", async () => {
    const f = await fixture()
    const args = { ...f.args, emoji: "👍" }
    const sub = await f.subscribe("reaction.added", args, await f.checkpoint("reaction.added", args))
    for (const emoji of ["✅", "👋", "👍"]) await ReactionModel.insertReaction(f.input(f.teammate.id, emoji))
    await db.update(mcpReactionEvents).set({ occurredAt: new Date(0) }).where(eq(mcpReactionEvents.seq, 2))
    expect(await purgeExpiredReactionEvents(1)).toBe(1)
    expect(await nextOccurrence(f.principal, "reaction.added", args, 0)).toEqual({ gapSeq: 3 })
    await db.update(mcpReactionEvents).set({ occurredAt: new Date(0) })
    expect(await purgeExpiredReactionEvents()).toBe(2)
    await runMcpEventsOnce(25, receiver())
    expect(received).toEqual([])
    expect((await readSubscription(sub.id))?.gapSeq).toBe(3)
    const renewal = await f.subscribe("reaction.added", args)
    expect(renewal.truncated).toBe(true)
    expect(decodeCursor(renewal.cursor, f.binding("reaction.added", args))).toBe(3)
  })

  test("message deletion cascades current state without synthetic removals or erased explicit events", async () => {
    const f = await fixture()
    await ReactionModel.insertReaction(f.input())
    await db.delete(messages).where(and(eq(messages.chatId, f.chat.id), eq(messages.messageId, 1)))
    expect(await ReactionModel.getReactions(1n, BigInt(f.chat.id))).toEqual([])
    expect(await f.rows()).toHaveLength(1)
    expect(await nextOccurrence(f.principal, "reaction.removed", f.args, 0)).toEqual({ through: 1 })
    expect(await nextOccurrence(f.principal, "reaction.added", f.args, 0)).toHaveProperty("occurrence.data.messageId", "1")
  })

  test("revoked grant fences a pending callback and ACK", async () => {
    const f = await fixture()
    const sub = await f.subscribe()
    await ReactionModel.insertReaction(f.input())
    await runMcpEventsOnce(25, receiver(503))
    await due(sub.id)
    await runMcpEventsOnce(25, receiver(200, async () => { await db.update(oauthGrants).set({ revokedAt: new Date() }).where(eq(oauthGrants.id, f.grant.id)) }))
    expect(received).toHaveLength(1)
    expect((await readSubscription(sub.id))?.cursorSeq).toBe(0)
    expect((await readSubscription(sub.id))?.stopped).toBe(true)
  })

  test("current chat access loss fences source, delivery and shared writes", async () => {
    const f = await fixture()
    const sub = await f.subscribe()
    await ReactionModel.insertReaction(f.input())
    await db.update(chats).set({ minUserId: f.teammate.id, maxUserId: f.teammate.id }).where(eq(chats.id, f.chat.id))
    await expect(ReactionModel.insertReaction(f.input(f.owner.id, "👍"))).rejects.toThrow()
    await expect(nextOccurrence(f.principal, "reaction.added", f.args, 0)).rejects.toThrow(McpEventsError)
    await runMcpEventsOnce(25, receiver())
    expect(received).toEqual([])
    expect((await readSubscription(sub.id))?.stopped).toBe(true)
  })

  test("a writer blocked on the chat lock rechecks access after the preceding transaction commits", async () => {
    const f = await fixture()
    const ready = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const holder = db.transaction(async (tx) => {
      await tx.select().from(chats).where(eq(chats.id, f.chat.id)).for("update")
      ready.resolve()
      await release.promise
      await tx.update(chats).set({ minUserId: f.teammate.id, maxUserId: f.teammate.id }).where(eq(chats.id, f.chat.id))
    })
    await ready.promise
    const writing = ReactionModel.insertReaction(f.input(f.owner.id)).then(() => "allowed", () => "denied")
    try {
      let waiting = false
      for (let attempt = 0; attempt < 100; attempt += 1) {
        const [row] = await db.execute<{ waiting: boolean }>(sql`SELECT EXISTS (
          SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'
          AND query LIKE '%chats%' AND pid != pg_backend_pid()
        ) AS waiting`)
        if (row?.waiting) { waiting = true; break }
        await new Promise((resolve) => setTimeout(resolve, 2))
      }
      expect(waiting).toBe(true)
      expect(await f.rows()).toEqual([])
    } finally { release.resolve(); await holder }
    expect(await writing).toBe("denied")
    expect(await f.rows()).toEqual([])
    expect((await db.select().from(chats).where(eq(chats.id, f.chat.id)))[0]?.mcpReactionSeq).toBe(0)
  })

  test("compiled MCP HTTP catalog and subscription reach the reaction source with current OAuth authority", async () => {
    const f = await fixture()
    const token = "reaction-paired-test-token"
    await OauthModel.createAccessToken({ tokenHash: createHash("sha256").update(token).digest("hex"), grantId: f.grant.id,
      nowMs: Date.now(), expiresAtMs: Date.now() + 60_000 })
    const previous = process.env["MCP_INTERNAL_SHARED_SECRET"]
    process.env["MCP_INTERNAL_SHARED_SECRET"] = "reaction-paired-test-secret"
    const { handleIntrospect } = await import("@in/server/modules/oauth/httpHandlers")
    const { createApp } = await import("../../../../packages/mcp/dist/server/app.js")
    const api = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: async (request) => {
      const body: unknown = await request.json()
      const path = new URL(request.url).pathname
      if (path === "/oauth/introspect") return handleIntrospect(request, body)
      if (path === "/oauth/mcp-events") return handleMcpEvents(request, body, receiver())
      return new Response(null, { status: 404 })
    } })
    const app = createApp({ issuer: oauthConfig().resource, allowedHosts: ["127.0.0.1"], oauthInternalSharedSecret: "reaction-paired-test-secret",
      oauthProxyBaseUrl: `http://127.0.0.1:${api.port}`, oauthIntrospectionUrl: `http://127.0.0.1:${api.port}/oauth/introspect` })
    const mcp = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: (request) => app.fetch(request) })
    const call = async (method: string, params: Record<string, unknown> = {}) => {
      const response = await fetch(`http://127.0.0.1:${mcp.port}/mcp/v2`, {
        method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json",
          "mcp-protocol-version": "2026-07-28", "mcp-method": method,
          ...(typeof params["name"] === "string" ? { "mcp-name": params["name"] } : {}) },
        body: JSON.stringify({ jsonrpc: "2.0", id: 9, method, params: { ...params, _meta: {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {},
        } } }),
      })
      expect(response.status).toBe(200)
      return await response.json() as { result: Record<string, unknown>; error?: unknown }
    }
    try {
      const catalog = await call("events/list")
      expect(catalog.result["events"]).toEqual(expect.arrayContaining([expect.objectContaining({ name: "reaction.added" })]))
      const cursor = await f.checkpoint()
      await ReactionModel.insertReaction(f.input())
      const registration = await call("events/subscribe", { name: "reaction.added", arguments: f.args, delivery, cursor })
      expect(registration.error).toBeUndefined()
      expect(registration.result["truncated"]).toBe(false)
      await runMcpEventsOnce(25, receiver())
      expect(event().data).toMatchObject({ kind: "reaction", chatId: String(f.chat.id), messageId: "1", emoji: "✅" })
      await call("events/unsubscribe", { name: "reaction.added", arguments: f.args, delivery: { mode: "webhook", url: delivery.url } })
      expect((await readSubscription(String(registration.result["id"])))?.stopped).toBe(true)
    } finally {
      await mcp.stop(true)
      await api.stop(true)
      if (previous === undefined) delete process.env["MCP_INTERNAL_SHARED_SECRET"]
      else process.env["MCP_INTERNAL_SHARED_SECRET"] = previous
    }
  })

  test("rollout off still captures, hides definitions and stops claims while permitting unsubscribe", async () => {
    const f = await fixture()
    const sub = await f.subscribe()
    delete process.env["MCP_REACTION_EVENTS_ENABLED"]
    await ReactionModel.insertReaction(f.input())
    expect(await f.rows()).toHaveLength(1)
    const catalog = await executeEventMethod(f.principal, "events/list", {}) as { events: { name: string }[] }
    expect(catalog.events.some((entry) => entry.name.startsWith("reaction."))).toBe(false)
    expect(catalog.events.some((entry) => entry.name === "message.created")).toBe(true)
    await expect(f.subscribe()).rejects.toThrow(McpEventsError)
    expect(await runMcpEventsOnce(25, receiver())).toBe(0)
    expect(received).toEqual([])
    expect(await executeEventMethod(f.principal, "events/unsubscribe", { name: "reaction.added", arguments: f.args,
      delivery: { mode: "webhook", url: delivery.url } })).toEqual({})
    expect((await readSubscription(sub.id))?.stopped).toBe(true)
  })

  test("two workers claim one identity and cursors cannot cross event, filter or message source", async () => {
    const f = await fixture()
    await f.subscribe()
    await ReactionModel.insertReaction(f.input())
    await Promise.all([runMcpEventsOnce(25, receiver()), runMcpEventsOnce(25, receiver())])
    expect(received).toHaveLength(1)
    const cursor = await f.checkpoint()
    await expect(f.subscribe("reaction.removed", f.args, cursor)).rejects.toThrow(McpEventsError)
    await expect(f.subscribe("reaction.added", { ...f.args, emoji: "✅" }, cursor)).rejects.toThrow(McpEventsError)
    const messageCursor = await f.checkpoint("message.created")
    await expect(f.subscribe("reaction.added", f.args, messageCursor)).rejects.toThrow(McpEventsError)
  })
})
