import { describe, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import { and, eq, lte, sql } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../../__tests__/setup"
import { db } from "@in/server/db"
import { chats, members, messages, mcpEventSubscriptions, oauthGrants, updates, UpdateBucket } from "@in/server/db/schema"
import { OauthModel } from "@in/server/db/models/oauth"
import { SessionsModel } from "@in/server/db/models/sessions"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { oauthConfig } from "@in/server/modules/oauth/config"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { persistChatMetadataUpdates } from "@in/server/modules/chatMetadataUpdates"
import { authorizeSelector, validateGrant } from "./authorization"
import { decodeCursor, encodeCursor, signature, subscriptionId } from "./crypto"
import { claimSubscriptions, purgeExpiredSubscriptions, readSubscription } from "./repository"
import { executeEventMethod, handleMcpEvents } from "./service"
import { nextOccurrence } from "./source"
import { runMcpEventsOnce } from "./worker"
import type { CallbackTransport } from "./webhook"
import type { EventOccurrence, SubscribeResult } from "./types"

const secret = `whsec_${Buffer.alloc(32, 0x42).toString("base64")}`
const destination = { mode: "webhook", url: "https://receiver.test/events", secret }
const received: { body: string; headers: Record<string, string> }[] = []
const receiver = (status = 200, before?: () => Promise<void>): CallbackTransport => async (input) => {
  await before?.()
  await input.beforeConnect?.()
  const body = JSON.parse(input.body) as { type?: string; challenge?: string }
  if (body.type === "verification") return { status: 200, body: JSON.stringify({ challenge: body.challenge }) }
  received.push({ body: input.body, headers: input.headers })
  return { status, body: "" }
}

async function fixture() {
  received.length = 0
  const owner = await testUtils.createUser("owner@events.test")
  const teammate = await testUtils.createUser("teammate@events.test")
  const chat = await testUtils.createPrivateChat(owner, teammate)
  if (!chat) throw new Error("Test chat missing")
  const session = await testUtils.createSessionForUser(owner.id)
  await OauthModel.createClient({ clientId: "events-client", clientName: "MCP events test", redirectUris: ["https://client.test/callback"], nowMs: Date.now() })
  const grant = await OauthModel.createGrant({ id: "events-grant", clientId: "events-client", inlineUserId: owner.id,
    scope: "messages:read messages:write spaces:read offline_access", resource: oauthConfig().resource, spaceIds: [], allowDms: true, allowHomeThreads: true,
    inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(session.token)), nowMs: Date.now() })
  const principal = await validateGrant(grant)
  const args = { chatId: String(chat.id), excludeSelf: true }
  const binding = { grantId: grant.id, name: "message.created", selector: args, bucket: { kind: "chat" as const, entityId: chat.id } }
  const checkpoint = async () => (await executeEventMethod(principal, "events/cursor", { name: "message.created", arguments: args }) as { cursor: string }).cursor
  const subscribe = async (cursor?: string, signingSecret = secret) => await executeEventMethod(principal, "events/subscribe", {
    name: "message.created", arguments: args, delivery: { ...destination, secret: signingSecret }, ...(cursor ? { cursor } : {}),
  }, receiver()) as SubscribeResult
  const reply = async (body = "teammate content that must never enter webhook payload") => {
    const result = await sendMessage({ peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }, message: body },
      testUtils.functionContext({ userId: teammate.id, sessionId: session.session.id }))
    const update = result.updates.find((value) => value.update.oneofKind === "newMessage")
    if (update?.update.oneofKind !== "newMessage" || !update.update.newMessage.message) throw new Error("Committed reply missing")
    return update.update.newMessage.message.id.toString()
  }
  return { owner, teammate, chat, session, grant, principal, args, binding, checkpoint, subscribe, reply }
}

const due = async (id: string) => { await db.update(mcpEventSubscriptions).set({ nextAttemptAt: new Date(0) }).where(eq(mcpEventSubscriptions.id, id)) }
const occurrence = (index = -1) => JSON.parse(received.at(index)!.body) as EventOccurrence

describe("durable MCP events with real PostgreSQL and committed Inline messages", () => {
  setupTestLifecycle()

  test("captures a reply between cursor creation and subscribe, emits references and acknowledges only after callback", async () => {
    const f = await fixture()
    const checkpoint = await f.checkpoint()
    const messageId = await f.reply()
    const subscription = await f.subscribe(checkpoint)
    expect(subscription.truncated).toBe(false)
    expect(await runMcpEventsOnce(25, receiver())).toBe(1)
    const event = occurrence()
    expect(event.data).toEqual({ kind: "newMessage", chatId: String(f.chat.id), messageId })
    expect(received[0]?.body).not.toContain("teammate content")
    expect(event.eventId).toBe(String(received[0]?.headers["webhook-id"]))
    expect(received[0]?.headers["webhook-signature"]).toBe(signature(secret, event.eventId, Number(received[0]?.headers["webhook-timestamp"]), received[0]!.body))
    const row = await readSubscription(subscription.id)
    expect(row?.pendingEncrypted).toBeNull()
    expect(row?.cursorSeq).toBe(decodeCursor(event.cursor, f.binding))
    const status = await executeEventMethod(f.principal, "events/status", { chatId: String(f.chat.id) })
    expect(status).toEqual({ subscriptions: [{ id: subscription.id, name: "message.created", refreshBefore: subscription.refreshBefore }] })
  })

  test("retry after worker restart preserves exact body/event ID, refresh cannot fast-forward pending, rotation signs both keys", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply("first reply")
    await runMcpEventsOnce(25, receiver(503))
    const first = received[0]!
    const failed = await readSubscription(subscription.id)
    expect(failed?.cursorSeq).toBe(0)
    expect(failed?.pendingEncrypted).not.toBeNull()
    const secondId = await f.reply("second reply")
    const nextSecret = `whsec_${Buffer.alloc(32, 0x43).toString("base64")}`
    const refreshed = await f.subscribe(await f.checkpoint(), nextSecret)
    expect(refreshed.id).toBe(subscription.id)
    expect(decodeCursor(refreshed.cursor, f.binding)).toBe(0)
    expect((await readSubscription(subscription.id))?.attemptCount).toBe(1)
    await due(subscription.id)
    await runMcpEventsOnce(25, receiver())
    expect(received[1]?.body).toBe(first.body)
    const seconds = Number(received[1]?.headers["webhook-timestamp"])
    expect(received[1]?.headers["webhook-signature"]?.split(" ")).toEqual([signature(nextSecret, occurrence(1).eventId, seconds, first.body), signature(secret, occurrence(1).eventId, seconds, first.body)])
    await runMcpEventsOnce(25, receiver())
    expect(occurrence().data.messageId).toBe(secondId)
    expect(occurrence().eventId).not.toBe(occurrence(0).eventId)
  })

  test("concurrent worker instances claim one subscription once", async () => {
    const f = await fixture()
    await f.subscribe(await f.checkpoint())
    await f.reply()
    await Promise.all([runMcpEventsOnce(25, receiver()), runMcpEventsOnce(25, receiver())])
    expect(received).toHaveLength(1)
  })

  for (const status of [429, 503]) test(`active renewal preserves HTTP ${status} Retry-After and pending delivery`, async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply()
    const busy: CallbackTransport = async (input) => ({ ...await receiver(status)(input), retryAfter: "3600" })
    await runMcpEventsOnce(25, busy)
    const before = await readSubscription(subscription.id)
    expect(before?.nextAttemptAt.getTime()).toBeGreaterThan(Date.now() + 59 * 60_000)
    await f.subscribe(subscription.cursor)
    const after = await readSubscription(subscription.id)
    expect(after?.nextAttemptAt).toEqual(before?.nextAttemptAt)
    expect(after?.pendingEncrypted).toEqual(before?.pendingEncrypted)
    expect(after?.attemptCount).toBe(1)
    expect(await runMcpEventsOnce(25, receiver())).toBe(0)
    expect(received).toHaveLength(1)
  })

  test("metadata refresh of an existing chat is available through chat.updated and the legacy chat.created event", async () => {
    const f = await fixture()
    const args = { chatId: String(f.chat.id) }
    for (const name of ["chat.created", "chat.updated"]) {
      const checkpoint = await executeEventMethod(f.principal, "events/cursor", { name, arguments: args }) as { cursor: string }
      await executeEventMethod(f.principal, "events/subscribe", { name, arguments: args, delivery: destination, cursor: checkpoint.cursor }, receiver())
    }
    // Parent-message deletion and history clearing reuse this journal marker
    // to refresh surviving orphaned/detached chats; they do not create a chat.
    await db.transaction(async (tx) => { await persistChatMetadataUpdates(tx, [f.chat.id]) })
    await runMcpEventsOnce(25, receiver())
    expect(received.map((entry) => (JSON.parse(entry.body) as EventOccurrence).name).sort()).toEqual(["chat.created", "chat.updated"])
    expect(received.every((entry) => (JSON.parse(entry.body) as EventOccurrence).data.kind === "newChat")).toBe(true)
    expect((await db.select({ id: chats.id }).from(chats))).toEqual([{ id: f.chat.id }])
  })

  test("unsubscribe succeeds for absent identities and remains scoped to the authenticated grant", async () => {
    const f = await fixture()
    const params = { name: "message.created", arguments: f.args, delivery: { mode: "webhook", url: destination.url } }
    expect(await executeEventMethod(f.principal, "events/unsubscribe", params)).toEqual({})
    const subscription = await f.subscribe(await f.checkpoint())
    const otherGrant = await OauthModel.createGrant({ id: "other-events-grant", clientId: "events-client", inlineUserId: f.owner.id,
      scope: f.grant.scope, resource: f.grant.resource, spaceIds: [], allowDms: true, allowHomeThreads: true,
      inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(f.session.token)), nowMs: Date.now() })
    expect(await executeEventMethod(await validateGrant(otherGrant), "events/unsubscribe", params)).toEqual({})
    expect((await readSubscription(subscription.id))?.stopped).toBe(false)
    expect(await executeEventMethod(f.principal, "events/unsubscribe", params)).toEqual({})
    expect(await executeEventMethod(f.principal, "events/unsubscribe", params)).toEqual({})
    expect((await readSubscription(subscription.id))?.stopped).toBe(true)
  })

  test("locked replay uses the same pool connection with all other query slots occupied", async () => {
    const f = await fixture()
    const cursor = await f.checkpoint()
    const release = Promise.withResolvers<void>()
    const acquired = Array.from({ length: 9 }, () => Promise.withResolvers<void>())
    const holders = acquired.map((ready) => db.transaction(async (transaction) => {
      await transaction.execute(sql`select 1`)
      ready.resolve()
      await release.promise
    }))
    await Promise.all(acquired.map((ready) => ready.promise))
    const save = f.subscribe(cursor)
    let timeout: ReturnType<typeof setTimeout> | undefined
    try {
      const result = await Promise.race([save, new Promise<null>((resolve) => { timeout = setTimeout(() => resolve(null), 5000) })])
      expect(result).not.toBeNull()
    } finally {
      if (timeout) clearTimeout(timeout)
      release.resolve()
      await Promise.all(holders)
      await save
    }
  })

  test("a signed checkpoint ahead of the restored journal tail is rejected", async () => {
    const f = await fixture()
    await expect(f.subscribe(encodeCursor(f.binding, 1000))).rejects.toMatchObject({ code: -32602 })
  })

  test("unsubscribe between claim and opening socket fences delivery and preserves unacknowledged occurrence", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply()
    await runMcpEventsOnce(25, receiver(200, async () => {
      await executeEventMethod(f.principal, "events/unsubscribe", { name: "message.created", arguments: f.args, delivery: { mode: "webhook", url: destination.url } })
    }))
    expect(received).toHaveLength(0)
    const row = await readSubscription(subscription.id)
    expect(row?.stopped).toBe(true)
    expect(row?.cursorSeq).toBe(0)
    expect(row?.pendingSeq).toBeGreaterThan(0)
    expect(await executeEventMethod(f.principal, "events/status", { chatId: String(f.chat.id) })).toEqual({ subscriptions: [] })
  })

  test("grant revocation after callback reception fences ACK and never resumes on another worker", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply()
    const transport: CallbackTransport = async (input) => {
      await input.beforeConnect?.()
      received.push({ body: input.body, headers: input.headers })
      await OauthModel.revokeGrant(f.grant.id, Date.now())
      return { status: 200, body: "" }
    }
    await runMcpEventsOnce(25, transport)
    expect(received).toHaveLength(1)
    expect((await readSubscription(subscription.id))?.cursorSeq).toBe(0)
    expect((await readSubscription(subscription.id))?.stopped).toBe(true)
    expect(await runMcpEventsOnce(25, receiver())).toBe(0)
  })

  test("backing session revocation fences durable delivery even when OAuth grant is still active", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply()
    await SessionsModel.revoke(f.session.session.id)
    await runMcpEventsOnce(25, receiver())
    expect(received).toHaveLength(0)
    expect((await readSubscription(subscription.id))?.stopped).toBe(true)
  })

  test("a real journal gap pauses without ACK; refresh reports truncation and a fresh recoverable cursor", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply()
    const [{ seq } = { seq: 0 }] = await db.select({ seq: chats.updateSeq }).from(chats).where(eq(chats.id, f.chat.id))
    await db.delete(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, f.chat.id)))
    await runMcpEventsOnce(25, receiver())
    const paused = await readSubscription(subscription.id)
    expect(paused?.gapSeq).toBe(seq)
    expect(paused?.cursorSeq).toBe(0)
    expect(received).toHaveLength(0)
    expect(await executeEventMethod(f.principal, "events/status", { chatId: String(f.chat.id) })).toEqual({ subscriptions: [] })
    const refreshed = await f.subscribe(subscription.cursor)
    expect(refreshed.truncated).toBe(true)
    expect(decodeCursor(refreshed.cursor, f.binding)).toBe(seq ?? 0)
    const messageId = await f.reply("after recovery")
    await runMcpEventsOnce(25, receiver())
    expect(occurrence().data.messageId).toBe(messageId)
  })

  test("stale cursor at first subscribe reports truncation immediately", async () => {
    const f = await fixture()
    const cursor = await f.checkpoint()
    await f.reply()
    await db.delete(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, f.chat.id)))
    const subscription = await f.subscribe(cursor)
    expect(subscription.truncated).toBe(true)
    expect(decodeCursor(subscription.cursor, f.binding)).toBeGreaterThan(0)
  })

  test("expired identity probes the requested rewind below retention and reports the fresh tail", async () => {
    const f = await fixture()
    const oldCursor = await f.checkpoint()
    for (let index = 0; index < 3; index += 1) await f.reply(`reply ${index}`)
    const subscription = await f.subscribe()
    const tail = decodeCursor(subscription.cursor, f.binding)
    await db.update(mcpEventSubscriptions).set({ expiresAt: new Date(0) }).where(eq(mcpEventSubscriptions.id, subscription.id))
    await db.delete(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, f.chat.id), lte(updates.seq, tail - 1)))
    const refreshed = await f.subscribe(oldCursor)
    expect(refreshed.truncated).toBe(true)
    expect(decodeCursor(refreshed.cursor, f.binding)).toBe(tail)
  })

  test("a paused gap refresh uses current tail after retention advances again", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply("first lost update")
    await db.delete(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, f.chat.id)))
    await runMcpEventsOnce(25, receiver())
    const firstGap = (await readSubscription(subscription.id))?.gapSeq ?? 0
    await f.reply("second lost update")
    await db.delete(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, f.chat.id)))
    const currentTail = decodeCursor(await f.checkpoint(), f.binding)
    expect(currentTail).toBeGreaterThan(firstGap)
    const refreshed = await f.subscribe(subscription.cursor)
    expect(refreshed.truncated).toBe(true)
    expect(decodeCursor(refreshed.cursor, f.binding)).toBe(currentTail)
    const messageId = await f.reply("fresh reply")
    await runMcpEventsOnce(25, receiver())
    expect(occurrence().data.messageId).toBe(messageId)
  })

  test("concurrent initial requests cannot apply an obsolete gap probe to an active identity", async () => {
    const f = await fixture()
    const oldCursor = await f.checkpoint()
    await f.reply("already unavailable")
    await db.delete(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, f.chat.id)))
    const verified = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const older = executeEventMethod(f.principal, "events/subscribe", { name: "message.created", arguments: f.args, delivery: destination, cursor: oldCursor },
      receiver(200, async () => { verified.resolve(); await release.promise })) as Promise<SubscribeResult>
    await verified.promise
    try {
      const newer = await f.subscribe(await f.checkpoint())
      const messageId = await f.reply("must survive concurrent refresh")
      release.resolve()
      const refreshed = await older
      expect(refreshed.id).toBe(newer.id)
      expect(refreshed.truncated).toBe(false)
      expect(decodeCursor(refreshed.cursor, f.binding)).toBe(decodeCursor(newer.cursor, f.binding))
      await runMcpEventsOnce(25, receiver())
      expect(occurrence().data.messageId).toBe(messageId)
    } finally { release.resolve(); await older }
  })

  test("active quota also covers reactivation, and expiry cleanup retains live pending state", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    const row = await readSubscription(subscription.id)
    if (!row) throw new Error("Subscription missing")
    await db.update(mcpEventSubscriptions).set({ stopped: true }).where(eq(mcpEventSubscriptions.id, row.id))
    const copies = Array.from({ length: 64 }, (_, index) => {
      const url = `https://receiver.test/events?identity=${index}`
      return { ...row, id: subscriptionId(f.grant.id, row.name, row.selector, url), callbackUrl: url, nextAttemptAt: new Date(Date.now() + 60_000) }
    })
    await db.insert(mcpEventSubscriptions).values(copies)
    await expect(f.subscribe(subscription.cursor)).rejects.toMatchObject({ code: -32013, data: { limit: "subscriptions", max: 64 } })
    const expiredId = copies[0]!.id
    await db.update(mcpEventSubscriptions).set({ expiresAt: new Date(Date.now() - 25 * 60 * 60_000) }).where(eq(mcpEventSubscriptions.id, expiredId))
    await f.reply()
    await db.update(mcpEventSubscriptions).set({ stopped: false }).where(eq(mcpEventSubscriptions.id, row.id))
    await runMcpEventsOnce(1, receiver(503))
    expect((await readSubscription(row.id))?.pendingEncrypted).not.toBeNull()
    expect(await purgeExpiredSubscriptions()).toBe(1)
    expect(await readSubscription(expiredId)).toBeUndefined()
    expect(await readSubscription(row.id)).toBeDefined()
    expect(await purgeExpiredSubscriptions()).toBe(0)
  })

  test("retained encrypted callback state has a finite per-grant row budget", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    const row = await readSubscription(subscription.id)
    if (!row) throw new Error("Subscription missing")
    await db.update(mcpEventSubscriptions).set({ expiresAt: new Date(0) }).where(eq(mcpEventSubscriptions.id, row.id))
    await db.insert(mcpEventSubscriptions).values(Array.from({ length: 1023 }, (_, index) => {
      const url = `https://receiver.test/events?retained=${index}`
      return { ...row, id: subscriptionId(f.grant.id, row.name, row.selector, url), callbackUrl: url, expiresAt: new Date(0) }
    }))
    await expect(executeEventMethod(f.principal, "events/subscribe", { name: "message.created", arguments: f.args, delivery: { ...destination, url: `${destination.url}?new` } }, receiver()))
      .rejects.toMatchObject({ code: -32013, data: { limit: "retainedSubscriptions", max: 1024 } })
    expect(await purgeExpiredSubscriptions()).toBe(100)
  })

  for (const status of [410, 413]) test(`terminal HTTP ${status} settles only that delivery and allows later replies`, async () => {
      const f = await fixture()
      const subscription = await f.subscribe(await f.checkpoint())
      await f.reply()
      await runMcpEventsOnce(25, receiver(status))
      const row = await readSubscription(subscription.id)
      expect(row?.stopped).toBe(false)
      expect(row?.pendingEncrypted).toBeNull()
      expect(row?.cursorSeq).toBeGreaterThan(0)
      const nextId = await f.reply("after nonretryable delivery")
      await runMcpEventsOnce(25, receiver())
      expect(occurrence().data.messageId).toBe(nextId)
  })

  test("internal route binds current access token instead of accepting a caller-supplied grant", async () => {
    const f = await fixture()
    const token = "events-test-access-token"
    await OauthModel.createAccessToken({ tokenHash: createHash("sha256").update(token).digest("hex"), grantId: f.grant.id, nowMs: Date.now(), expiresAtMs: Date.now() + 60_000 })
    const previous = process.env["MCP_INTERNAL_SHARED_SECRET"]
    process.env["MCP_INTERNAL_SHARED_SECRET"] = "test-events-shared-secret"
    try {
      const request = new Request("https://api.inline.chat/oauth/mcp-events", { method: "POST", headers: { "x-inline-mcp-secret": "test-events-shared-secret" } })
      const valid = await handleMcpEvents(request, { method: "events/cursor", params: { name: "message.created", arguments: f.args }, token })
      expect(valid.status).toBe(200)
      expect((await valid.json() as { cursor: string }).cursor).toStartWith("mcpe1_")
      const invented = await handleMcpEvents(request, { method: "events/list", params: {}, token, grantId: "another-grant" })
      expect((await invented.json() as { error: { code: number } }).error.code).toBe(-32602)
      const unauthenticated = await handleMcpEvents(new Request(request.url), { method: "events/list", token })
      expect(unauthenticated.status).toBe(401)
      await OauthModel.revokeGrant(f.grant.id, Date.now())
      const revoked = await handleMcpEvents(request, { method: "events/list", token })
      expect((await revoked.json() as { error: { code: number } }).error.code).toBe(-32012)
    } finally {
      if (previous === undefined) delete process.env["MCP_INTERNAL_SHARED_SECRET"]
      else process.env["MCP_INTERNAL_SHARED_SECRET"] = previous
    }
  })

  test("source retains occurrence references after deletion and does not hydrate historical text", async () => {
    const f = await fixture()
    const messageId = await f.reply()
    await db.update(chats).set({ lastMsgId: null }).where(eq(chats.id, f.chat.id))
    await db.delete(messages).where(and(eq(messages.chatId, f.chat.id), eq(messages.messageId, Number(messageId))))
    const page = await nextOccurrence(f.principal, "message.created", { chatId: String(f.chat.id) }, 0)
    expect("occurrence" in page && page.occurrence?.data.messageId).toBe(messageId)
    expect(JSON.stringify(page)).not.toContain("teammate content")
  })

  test("selected grant prevents following inherited child chats into an unselected space", async () => {
    const f = await fixture()
    const space = await testUtils.createSpace("Not selected")
    if (!space) throw new Error("Space missing")
    await db.insert(members).values({ userId: f.owner.id, spaceId: space.id, role: "member" })
    const parent = await testUtils.createChat(space.id, "Parent", "thread", true, f.owner.id)
    if (!parent) throw new Error("Parent missing")
    const [child] = await db.insert(chats).values({ type: "thread", parentChatId: parent.id, spaceId: null, createdBy: f.owner.id }).returning()
    if (!child) throw new Error("Child missing")
    await expect(authorizeSelector(f.principal, "message.created", { chatId: String(child.id) })).rejects.toThrow()
  })

  test("current scopes are rechecked before delivery and expired leases can be recovered", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply()
    expect(await claimSubscriptions()).toHaveLength(1)
    expect(await claimSubscriptions()).toHaveLength(0)
    await db.update(mcpEventSubscriptions).set({ leaseUntil: new Date(0) }).where(eq(mcpEventSubscriptions.id, subscription.id))
    await db.update(oauthGrants).set({ scope: "spaces:read offline_access" }).where(eq(oauthGrants.id, f.grant.id))
    await runMcpEventsOnce(25, receiver())
    expect(received).toHaveLength(0)
    expect((await readSubscription(subscription.id))?.stopped).toBe(true)
  })

  test("explicit refresh resumes an exhausted delivery without dropping pending bytes", async () => {
    const f = await fixture()
    const subscription = await f.subscribe(await f.checkpoint())
    await f.reply()
    await runMcpEventsOnce(25, receiver(503))
    const failedBody = received[0]!.body
    await db.update(mcpEventSubscriptions).set({ attemptCount: 12, stopped: true }).where(eq(mcpEventSubscriptions.id, subscription.id))
    const refreshed = await f.subscribe(subscription.cursor)
    expect(decodeCursor(refreshed.cursor, f.binding)).toBe(0)
    expect((await readSubscription(subscription.id))?.attemptCount).toBe(0)
    await runMcpEventsOnce(25, receiver())
    expect(received.at(-1)?.body).toBe(failedBody)
    expect((await readSubscription(subscription.id))?.pendingEncrypted).toBeNull()
  })

  test("real MCP HTTP modern discovery/list/subscribe/unsubscribe pairs with current OAuth backend and committed message source", async () => {
    const f = await fixture()
    const token = "paired-events-access-token"
    await OauthModel.createAccessToken({ tokenHash: createHash("sha256").update(token).digest("hex"), grantId: f.grant.id, nowMs: Date.now(), expiresAtMs: Date.now() + 60_000 })
    const previous = process.env["MCP_INTERNAL_SHARED_SECRET"]
    process.env["MCP_INTERNAL_SHARED_SECRET"] = "paired-test-secret"
    const { handleIntrospect } = await import("@in/server/modules/oauth/httpHandlers")
    const api = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: async (request) => {
      const path = new URL(request.url).pathname
      const body: unknown = await request.json()
      if (path === "/oauth/introspect") return handleIntrospect(request, body)
      if (path === "/oauth/mcp-events") return handleMcpEvents(request, body, receiver())
      return new Response(null, { status: 404 })
    } })
    // Import the independently built MCP boundary, avoiding a duplicate test implementation.
    const { createApp } = await import("../../../../packages/mcp/dist/server/app.js")
    const app = createApp({ issuer: oauthConfig().resource, allowedHosts: ["127.0.0.1"], oauthInternalSharedSecret: "paired-test-secret",
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
      const discover = await call("server/discover")
      expect(discover.result["resultType"]).toBe("complete")
      expect(discover.result["capabilities"]).toMatchObject({ events: {} })
      const list = await call("events/list")
      expect(list.result["events"]).toEqual(expect.arrayContaining([expect.objectContaining({ name: "message.created" })]))
      const cursor = await f.checkpoint()
      const registration = await call("events/subscribe", { name: "message.created", arguments: f.args, delivery: destination, cursor })
      expect(registration.result["resultType"]).toBe("complete")
      expect(registration.result["truncated"]).toBe(false)
      const messageId = await f.reply("cross-service actual reply")
      await runMcpEventsOnce(25, receiver())
      expect(occurrence().data.messageId).toBe(messageId)
      expect(occurrence().data.chatId).toBe(String(f.chat.id))
      const stopped = await call("events/unsubscribe", { name: "message.created", arguments: f.args, delivery: { mode: "webhook", url: destination.url } })
      expect(stopped.result["resultType"]).toBe("complete")
      expect((await readSubscription(String(registration.result["id"])))?.stopped).toBe(true)
      await f.reply("after unsubscribe")
      expect(await runMcpEventsOnce(25, receiver())).toBe(0)
    } finally {
      await mcp.stop(true)
      await api.stop(true)
      if (previous === undefined) delete process.env["MCP_INTERNAL_SHARED_SECRET"]
      else process.env["MCP_INTERNAL_SHARED_SECRET"] = previous
    }
  })
})
