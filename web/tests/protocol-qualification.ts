/**
 * Manual transport/persistence qualification against protocol-server.ts.
 * From web/: bun --no-env-file tests/protocol-qualification.ts
 * Uses production owners and real loopback WebSockets with synthetic data.
 * fake-indexeddb is isolated in this process: this is not browser, physical
 * disk/crash, DOM, Web Locks, or production acceptance evidence.
 */
import "fake-indexeddb/auto"
import { strict as assert } from "node:assert"
import {
  AuthStore, Db, DbObjectKind, DbQueryPlanType, MessageSendingStatus,
  RealtimeClient, createIndexedDbPersistenceStore, getChats, getMe,
  messageDraftKey,
  type AuthSession, type Chat, type Message, type PendingTransaction,
} from "@inline/client/core"
import { chatId, protocolId, userId } from "@inline/ids"
import { Log } from "@inline/log"
import { Conversation, CONVERSATION_PAGE_SIZE } from "../src/conversation/Conversation"
import { TEST_CODE, TEST_DESIGN_CHAT_ID, TEST_EMAIL, TEST_USER_ID } from "./protocol-server"

const origin = "http://127.0.0.1:8012"
const targetChat = chatId(TEST_DESIGN_CHAT_ID)
type FixtureState = {
  online: boolean
  methods: Record<string, number>
  sendAttempts: number
  uniqueSentMessages: number
  injectedMessages: number
  chats: { id: string; messageCount: number }[]
}
type Owner = { db: Db; client: RealtimeClient; auth: AuthStore; conversation?: Conversation; closed: boolean }

async function deadline<T>(task: Promise<T>, label: string, ms = 12_000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([task, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), ms)
    })])
  } finally { if (timer) clearTimeout(timer) }
}

async function waitFor(predicate: () => boolean, label: string, ms = 12_000) {
  const end = Date.now() + ms
  while (!predicate()) {
    if (Date.now() >= end) throw new Error(`Timed out: ${label}`)
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
}

async function assertLatestCoverage(db: Db, conversation: Conversation, message: Message, label: string) {
  await waitFor(() => {
    const snapshot = conversation.getSnapshot()
    return !snapshot.loading && !snapshot.sending && !snapshot.refreshingLatest && !snapshot.loadingOlder
  }, `${label} history settling`)
  const snapshot = conversation.getSnapshot()
  assert.equal(snapshot.error, undefined, `${label} must settle without a conversation error`)
  assert.equal(snapshot.historyCertified, true, `${label} must retain certified server history`)
  assert.equal(snapshot.atLatest, true, `${label} must present the latest history window`)
  assert.equal(snapshot.messages.filter((row) => row.messageId === message.messageId).length, 1, `${label} must show the canonical sent message exactly once`)
  assert.equal(snapshot.messages.filter((row) => row.message === message.message).length, 1, `${label} must not display a resurrected temporary copy`)
  const residentMessages = messages(db)
  assert.equal(residentMessages.filter((row) => row.message === message.message).length, 1, `${label} must retain one Db row for the acknowledged send`)
  assert.equal(pending(db).length, 0, `${label} must keep the acknowledged outbox empty after history settles`)
  const orphanSendingMessages = residentMessages.filter((row) => row.status === MessageSendingStatus.Sending).length
  assert.equal(orphanSendingMessages, 0, `${label} must not resurrect a Sending row without an outbox operation`)
  return { historyCertified: snapshot.historyCertified, error: snapshot.error ?? null, atLatest: snapshot.atLatest, orphanSendingMessages }
}

async function fixtureRequest<T>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(`${origin}${path}`, {
    method: body === undefined ? "GET" : "POST",
    ...(body === undefined ? {} : { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(5_000),
  })
  if (!response.ok) throw new Error(`Local fixture request failed (${response.status}): ${path}`)
  return await response.json() as T
}

const pending = (db: Db) => db.queryCollection<DbObjectKind.PendingTransaction, PendingTransaction, DbQueryPlanType.Objects>(
  DbQueryPlanType.Objects, DbObjectKind.PendingTransaction,
)
const messages = (db: Db) => db.queryCollection<DbObjectKind.Message, Message, DbQueryPlanType.Objects>(
  DbQueryPlanType.Objects, DbObjectKind.Message, (message) => message.chatId === targetChat,
)

export async function qualifyProtocol() {
  const owners: Owner[] = []
  const namespace = `inline-protocol-qualification:${crypto.randomUUID()}`
  const marker = `qualification-${crypto.randomUUID()}`
  const logger = new Log("ProtocolQualification", { sink: false })
  const cleanupMilliseconds: number[] = []
  let failure: unknown
  const evidence: Record<string, unknown> = {
    scope: "loopback WebSocket + production client/conversation + fake IndexedDB",
    browserAcceptance: false,
  }

  async function createOwner(session: AuthSession, offline = false) {
    const auth = new AuthStore({ persistence: "memory" })
    await auth.ready
    await auth.login(session)
    const store = createIndexedDbPersistenceStore(namespace)
    assert.ok(store, "The production IndexedDB adapter must be available")
    const db = new Db({ autoHydrate: false, persistenceStore: store, logger })
    const client = new RealtimeClient({
      auth, db, url: "ws://127.0.0.1:8012/realtime", logger,
      connection: { backoffDelayMs: () => 100 },
    })
    const owner: Owner = { db, client, auth, closed: false }
    owners.push(owner)
    await deadline(db.openPersistence(), "open IndexedDB adapter")
    await deadline(db.hydrate(), "hydrate cached navigation")
    if (offline) await client.connection.setNetworkAvailable(false)
    await deadline(client.start(), "start production realtime owner")
    if (!offline) await waitFor(() => client.connectionState === "connected", "real WebSocket authentication")
    return owner
  }

  async function closeOwner(owner: Owner) {
    if (owner.closed) return
    const started = Date.now()
    owner.conversation?.stop()
    if (owner.conversation) await deadline(owner.conversation.drain(), "drain conversation drafts")
    await deadline(owner.client.stop(), "stop and drain realtime owner")
    await deadline(owner.db.closePersistence(), "close IndexedDB adapter")
    owner.auth.dispose()
    owner.closed = true
    cleanupMilliseconds.push(Date.now() - started)
  }

  async function openConversation(owner: Owner) {
    const chat = owner.db.get(owner.db.ref(DbObjectKind.Chat, targetChat))
    assert.ok(chat, "The exact large chat ID must exist in the production Db")
    assert.equal(chat.id, "9007199254741101", "Chat IDs must remain exact decimal strings")
    const conversation = new Conversation(owner.db, owner.client, chat as Chat)
    owner.conversation = conversation
    await deadline(conversation.start(), "prepare conversation cached state")
    return conversation
  }

  try {
    await fixtureRequest("/test/network", { online: true })
    const baseline = await fixtureRequest<FixtureState>("/test/state")
    const initialHistoryCount = baseline.chats.find((chat) => chat.id === String(TEST_DESIGN_CHAT_ID))?.messageCount
    assert.ok(initialHistoryCount != null && initialHistoryCount >= 160, "The local synthetic history fixture must be running")
    await fixtureRequest("/v1/sendEmailCode", { email: TEST_EMAIL })
    const verification = await fixtureRequest<{ ok: boolean; result: { userId: string; token: string } }>("/v1/verifyEmailCode", { email: TEST_EMAIL, code: TEST_CODE })
    assert.ok(verification.ok && verification.result.userId === String(TEST_USER_ID), "Synthetic POST authentication must return the exact fixture user")
    const session: AuthSession = { userId: userId(verification.result.userId), token: verification.result.token }

    const first = await createOwner(session)
    await deadline(Promise.all([first.client.query(getMe()), first.client.query(getChats())]), "real initial RPC queries")
    assert.ok(first.db.get(first.db.ref(DbObjectKind.User, session.userId)), "getMe must populate the exact synthetic user")
    const conversation = await openConversation(first)
    await waitFor(() => !conversation.getSnapshot().refreshingLatest, "latest history RPC")
    assert.ok(!conversation.getSnapshot().error, "Initial history must settle without an error")
    assert.equal(conversation.getSnapshot().messages.length, CONVERSATION_PAGE_SIZE)
    assert.ok(conversation.getSnapshot().hasOlder, "A 160-row fixture must certify older history")
    assert.ok(conversation.getSnapshot().historyCertified, "Network history must be certified before pagination")
    assert.ok(conversation.getSnapshot().messages.every((message) => protocolId(message.messageId) > BigInt(Number.MAX_SAFE_INTEGER)), "Large message IDs must retain exact precision")
    await deadline(conversation.loadOlder(), "first older history RPC")
    assert.equal(conversation.getSnapshot().messages.length, 120)
    await deadline(conversation.loadOlder(), "second older history RPC")
    assert.equal(conversation.getSnapshot().messages.length, initialHistoryCount)
    assert.equal(new Set(conversation.getSnapshot().messages.map((message) => message.messageId)).size, initialHistoryCount)
    assert.equal(conversation.getSnapshot().hasOlder, false)
    evidence.historyRows = initialHistoryCount
    evidence.exactChatId = String(targetChat)

    const onlineText = `${marker} online`
    let onlineRandomId: bigint | undefined
    const detach = first.db.subscribeToResidentChanges((batch) => {
      for (const change of batch.changes) {
        if (change.object?.kind !== DbObjectKind.PendingTransaction || change.object.type !== "send_message") continue
        const context = change.object.context as { text?: string; randomId?: bigint }
        if (context.text === onlineText) onlineRandomId = context.randomId
      }
    })
    await conversation.setDraft(onlineText)
    await deadline(conversation.send(), "online local durable acceptance")
    assert.equal(conversation.getSnapshot().draft, "")
    assert.equal(first.db.get(first.db.ref(DbObjectKind.MessageDraft, messageDraftKey({ peerKind: "chat", peerThreadId: targetChat }))), undefined)
    await waitFor(() => pending(first.db).length === 0 && messages(first.db).some((message) => message.message === onlineText && message.status === MessageSendingStatus.Sent), "online send server acknowledgement")
    detach()
    assert.ok(onlineRandomId != null, "The production outbox must expose its persisted retry identity")
    const onlineRows = messages(first.db).filter((message) => message.message === onlineText)
    assert.equal(onlineRows.length, 1, "Online send must reconcile to one local message")
    assert.ok(protocolId(onlineRows[0]!.messageId) > BigInt(Number.MAX_SAFE_INTEGER))
    // send() owns the latest-history refresh. Do not hide a reconciliation
    // invalidation by manually loading history before this assertion.
    const onlineCoverage = await assertLatestCoverage(first.db, conversation, onlineRows[0]!, "Online send")
    const afterOnline = await fixtureRequest<FixtureState>("/test/state")
    assert.equal(afterOnline.uniqueSentMessages - baseline.uniqueSentMessages, 1)
    evidence.onlineDelivery = "one acknowledged server message; one reconciled local message"

    await fixtureRequest("/test/network", { online: false })
    await waitFor(() => first.client.connectionState !== "connected", "real socket drop from backend network control")
    await first.client.connection.setNetworkAvailable(false)
    const offlineText = `${marker} offline restart`
    await conversation.setDraft(offlineText)
    await deadline(conversation.send(), "offline local durable acceptance")
    assert.equal(conversation.getSnapshot().draft, "")
    const queued = pending(first.db).filter((record) => record.type === "send_message")
    assert.equal(queued.length, 1)
    const queuedContext = queued[0]!.context as { randomId: bigint; temporaryMessageId: string; text: string }
    assert.ok(typeof queuedContext.randomId === "bigint", "Offline retry identity must persist as bigint")
    assert.equal(queuedContext.text, offlineText)
    assert.equal(messages(first.db).filter((message) => message.message === offlineText && message.status === MessageSendingStatus.Sending).length, 1)
    await first.db.flushPersistence()
    const beforeReopen = await fixtureRequest<FixtureState>("/test/state")
    assert.equal(beforeReopen.uniqueSentMessages, afterOnline.uniqueSentMessages, "Offline acceptance must not deliver to the unavailable backend")
    await closeOwner(first)

    const second = await createOwner(session, true)
    const restored = pending(second.db).filter((record) => record.type === "send_message")
    assert.equal(restored.length, 1)
    const restoredContext = restored[0]!.context as { randomId: bigint; temporaryMessageId: string }
    assert.equal(restoredContext.randomId, queuedContext.randomId)
    assert.equal(restoredContext.temporaryMessageId, queuedContext.temporaryMessageId)
    const reopened = await openConversation(second)
    assert.equal(reopened.getSnapshot().loading, false)
    assert.ok(reopened.getSnapshot().messages.some((message) => message.message === offlineText), "Cached reopen must include the accepted pending message before reconnection")
    await fixtureRequest("/test/network", { online: true })
    await second.client.connection.setNetworkAvailable(true)
    await waitFor(() => second.client.connectionState === "connected", "reopened real WebSocket authentication")
    await waitFor(() => pending(second.db).length === 0 && messages(second.db).some((message) => message.message === offlineText && message.status === MessageSendingStatus.Sent), "restored send acknowledgement")
    const restoredRows = messages(second.db).filter((message) => message.message === offlineText)
    assert.equal(restoredRows.length, 1)
    // Reopen already queued latest history while offline. Reconnection must
    // settle that query (or its quiet reconciliation refresh) without a manual
    // loadLatest clearing an erroneous invalidation.
    const reconnectCoverage = await assertLatestCoverage(second.db, reopened, restoredRows[0]!, "Offline reopened reconnect")
    const afterReopen = await fixtureRequest<FixtureState>("/test/state")
    assert.equal(afterReopen.uniqueSentMessages - afterOnline.uniqueSentMessages, 1)
    assert.equal(afterReopen.sendAttempts - beforeReopen.sendAttempts, 1, "The restored operation should make exactly one delivery attempt")
    evidence.offlineRestart = "persisted retry identity restored; one delivery; outbox empty"
    evidence.historyCoverage = { afterOnlineSend: onlineCoverage, afterOfflineReconnect: reconnectCoverage }

    const liveText = `${marker} live event`
    const injected = await fixtureRequest<{ chatId: string; messageId: string }>("/test/message", { chatId: String(targetChat), message: liveText })
    await waitFor(() => reopened.getSnapshot().messages.some((message) => message.message === liveText), "live WebSocket update in Conversation")
    const liveRows = reopened.getSnapshot().messages.filter((message) => message.message === liveText)
    assert.equal(liveRows.length, 1)
    assert.equal(liveRows[0]!.messageId, injected.messageId)
    assert.ok(protocolId(liveRows[0]!.messageId) > BigInt(Number.MAX_SAFE_INTEGER))
    await closeOwner(second)
    const final = await fixtureRequest<FixtureState>("/test/state")
    assert.equal(final.uniqueSentMessages - baseline.uniqueSentMessages, 2)
    assert.equal(final.injectedMessages - baseline.injectedMessages, 1)
    evidence.liveDelivery = "one exact-ID message observed through the production Conversation subscription"
    evidence.uniqueSentMessages = final.uniqueSentMessages - baseline.uniqueSentMessages
    evidence.sendRpcAttempts = final.sendAttempts - baseline.sendAttempts
    evidence.rpcCounts = Object.fromEntries(Object.entries(final.methods).map(([method, count]) => [method, count - (baseline.methods[method] ?? 0)]).filter(([, count]) => Number(count) > 0))
  } catch (error) { failure = error }
  finally {
    const cleanupErrors: string[] = []
    try { await fixtureRequest("/test/network", { online: true }) } catch { cleanupErrors.push("restore fixture network") }
    for (const owner of owners) {
      try { await closeOwner(owner) } catch { cleanupErrors.push("drain and close owner") }
    }
    if (cleanupErrors.length) failure = new Error(`Qualification cleanup failed: ${cleanupErrors.join(", ")}`)
    evidence.closeMilliseconds = cleanupMilliseconds
  }
  if (failure) throw failure
  return evidence
}

if (import.meta.main) {
  qualifyProtocol().then(
    (evidence) => { console.log(JSON.stringify({ ok: true, ...evidence }, null, 2)) },
    (error: unknown) => {
      console.error(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : "Protocol qualification failed", browserAcceptance: false }))
      process.exitCode = 1
    },
  )
}
