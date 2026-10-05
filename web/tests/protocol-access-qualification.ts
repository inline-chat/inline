/**
 * Run from web/: bun --no-env-file tests/protocol-access-qualification.ts
 * Owns an isolated loopback server. Exercises production Db/Realtime/Conversation
 * through binary WebSockets and the production IndexedDB adapter with fake-IDB.
 * This does not qualify browser UI, Web Locks, physical disk/crash, or production.
 */
import "fake-indexeddb/auto"
import { strict as assert } from "node:assert"
import {
  AuthStore, Db, DbObjectKind, DbQueryPlanType, RealtimeClient, TransactionFailure,
  createIndexedDbPersistenceStore, getChatHistory, getChats, getMe,
  messageDraftKey,
  type AuthSession, type Chat,
} from "@inline/client/core"
import { chatId, protocolId, spaceId, userId } from "@inline/ids"
import { Update } from "@inline-chat/protocol/core"
import { Log } from "@inline/log"
import { Conversation } from "../src/conversation/Conversation"
import {
  startProtocolTestServer, TEST_ACCESS_CHAT_ID, TEST_ACCESS_CHILD_ID,
  TEST_ACCESS_SPACE_ID, TEST_CODE, TEST_EMAIL, TEST_USER_ID,
} from "./protocol-server"

const parentId = chatId(TEST_ACCESS_CHAT_ID)
const childId = chatId(TEST_ACCESS_CHILD_ID)
const targetSpace = spaceId(TEST_ACCESS_SPACE_ID)
const draftKey = messageDraftKey({ peerKind: "chat", peerThreadId: childId })
const peer = { type: { oneofKind: "chat" as const, chat: { chatId: TEST_ACCESS_CHILD_ID } } }
type Owner = { db: Db; client: RealtimeClient; auth: AuthStore; conversation?: Conversation; closed: boolean }
type State = { openSockets: number; heldHistoryCount: number; heldUserReplayCount: number; heldUserReplayPages: { seq: string; updateCount: number; hasSidecars: boolean }[]; methods: Record<string, number>; replays: Record<string, number>; sendAttempts: number; uniqueSentMessages: number; chats: { id: string; messageCount: number }[] }
type Access = { memberId: string | null; previousMemberId: string | null; userSeq: number }

async function deadline<T>(task: Promise<T>, label: string, ms = 12_000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([task, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), ms)
    })])
  } finally { if (timer) clearTimeout(timer) }
}

async function waitFor(predicate: () => boolean | Promise<boolean>, label: string) {
  const end = Date.now() + 12_000
  while (!await predicate()) {
    if (Date.now() >= end) throw new Error(`Timed out: ${label}`)
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
}

const messages = (db: Db) => db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message,
  (message) => message.chatId === parentId || message.chatId === childId)
const userSeq = (db: Db) => db.get(db.ref(DbObjectKind.SyncBucketState, "user"))?.seq ?? 0

function assertExcluded(db: Db, draft: string) {
  assert.equal(db.get(db.ref(DbObjectKind.Space, targetSpace)), undefined, "Removed Space must be absent")
  for (const id of [parentId, childId]) {
    assert.equal(db.get(db.ref(DbObjectKind.Chat, id)), undefined, "Removed parent and inherited child must be absent")
    assert.equal(db.fullChatWindows.isActive(id), false, "Removal must release the old history window")
  }
  assert.equal(db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Dialog,
    (dialog) => dialog.chatId === parentId || dialog.chatId === childId).length, 0, "Removed dialogs must be absent")
  assert.equal(messages(db).length, 0, "Removed parent and inherited history must be absent")
  assert.equal(db.get(db.ref(DbObjectKind.MessageDraft, draftKey))?.text, draft, "An unsent local draft must survive access removal")
}

export async function qualifyProtocolAccess() {
  const server = startProtocolTestServer({ port: 0 })
  const origin = server.url.origin
  const owners: Owner[] = []
  const namespace = `inline-protocol-access:${crypto.randomUUID()}`
  const draft = `Preserved local draft ${crypto.randomUUID()}`
  const logger = new Log("ProtocolAccessQualification", { sink: false })
  const closeMilliseconds: number[] = []
  const evidence: Record<string, unknown> = {
    scope: "isolated loopback binary WebSocket + production Db/Realtime/Conversation + fake IndexedDB",
    browserAcceptance: false,
    productionAcceptance: false,
  }
  let failure: unknown

  async function request<T>(path: string, body?: unknown): Promise<T> {
    const response = await fetch(`${origin}${path}`, {
      method: body === undefined ? "GET" : "POST",
      ...(body === undefined ? {} : { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(5_000),
    })
    assert.ok(response.ok, `Local fixture request must succeed: ${path} (${response.status})`)
    return await response.json() as T
  }

  async function createOwner(session: AuthSession, offline = false) {
    const auth = new AuthStore({ persistence: "memory" })
    await auth.ready
    await auth.login(session)
    const store = createIndexedDbPersistenceStore(namespace)
    assert.ok(store, "The real IndexedDB adapter must be available")
    const db = new Db({ autoHydrate: false, persistenceStore: store, logger })
    const client = new RealtimeClient({ auth, db, url: `${origin.replace(/^http/, "ws")}/realtime`, logger,
      connection: { backoffDelayMs: () => 100 },
    })
    const owner: Owner = { auth, db, client, closed: false }
    owners.push(owner)
    await deadline(db.openPersistence(), "open IndexedDB")
    await deadline(db.hydrate(), "hydrate cached navigation and drafts")
    if (offline) await client.connection.setNetworkAvailable(false)
    await deadline(client.start(), "start real realtime owner")
    if (!offline) await waitFor(() => client.connectionState === "connected", "authenticate loopback WebSocket")
    return owner
  }

  async function openConversation(owner: Owner) {
    const chat = owner.db.get(owner.db.ref(DbObjectKind.Chat, childId))
    assert.ok(chat, "The currently granted legacy child must exist")
    assert.equal(chat.spaceId, undefined, "The child intentionally has legacy inherited Space ownership")
    assert.equal(chat.parentChatId, parentId)
    const conversation = new Conversation(owner.db, owner.client, chat as Chat)
    owner.conversation = conversation
    await deadline(conversation.start(), "prepare child cached state")
    return conversation
  }

  async function closeOwner(owner: Owner) {
    if (owner.closed) return
    const started = Date.now()
    owner.conversation?.stop()
    if (owner.conversation) await deadline(owner.conversation.drain(), "drain accepted drafts")
    await deadline(owner.client.stop(), "stop and drain realtime")
    await deadline(owner.db.closePersistence(), "close IndexedDB")
    owner.auth.dispose()
    owner.closed = true
    closeMilliseconds.push(Date.now() - started)
  }

  try {
    const baseline = await request<State>("/test/state")
    assert.equal(baseline.chats.length, 5, "The default browser fixture keeps its existing five chats")
    assert.equal(baseline.chats.find((chat) => chat.id === "9007199254741101")?.messageCount, 160)
    const initialAccess = await request<Access>("/test/access", { action: "prepare" })
    assert.ok(initialAccess.memberId, "The initial canonical join must name its immutable member row")
    await request("/v1/sendEmailCode", { email: TEST_EMAIL })
    const verification = await request<{ result: { userId: string; token: string } }>("/v1/verifyEmailCode", { email: TEST_EMAIL, code: TEST_CODE })
    assert.equal(verification.result.userId, String(TEST_USER_ID))
    const session: AuthSession = { userId: userId(verification.result.userId), token: verification.result.token }

    const first = await createOwner(session)
    await deadline(first.client.query(getMe()), "populate authenticated user")
    await deadline(first.client.query(getChats()), "populate authorized parent and child")
    await waitFor(() => userSeq(first.db) >= initialAccess.userSeq, "commit initial canonical membership")
    await first.db.hydrateKinds([DbObjectKind.DeferredUpdate])
    assert.ok(first.db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate).some((record) => {
      if (record.payloadType !== "Update" || record.updateType !== "joinSpace") return false
      const join = Update.fromBinary(record.payload).update
      return join.oneofKind === "joinSpace" && String(join.joinSpace.member?.id) === initialAccess.memberId
    }), "The matched live eviction must start with a retained canonical membership generation")
    assert.equal(first.db.get(first.db.ref(DbObjectKind.Space, targetSpace))?.isPublic, true)
    assert.equal(first.db.get(first.db.ref(DbObjectKind.Chat, parentId))?.isPublic, true)
    const conversation = await openConversation(first)
    await waitFor(() => conversation.getSnapshot().historyCertified && !conversation.getSnapshot().refreshingLatest, "certify initial child history")
    assert.equal(conversation.getSnapshot().messages.length, 1)
    assert.ok(conversation.getSnapshot().messages.every((message) => protocolId(message.messageId) > BigInt(Number.MAX_SAFE_INTEGER)))
    await conversation.setDraft(draft)
    assert.equal(first.db.get(first.db.ref(DbObjectKind.MessageDraft, draftKey))?.text, draft)
    await first.db.flushPersistence()

    await request("/test/history", { hold: true, chatId: String(childId) })
    const lateHistory = conversation.loadLatest()
    await waitFor(async () => (await request<State>("/test/state")).heldHistoryCount === 1, "capture immutable in-flight history page")
    await request("/test/replay", { hold: true })
    const removal = await request<Access>("/test/access", { action: "remove" })
    assert.equal(removal.previousMemberId, initialAccess.memberId)
    assert.equal(removal.memberId, null)
    await waitFor(async () => (await request<State>("/test/state")).heldUserReplayCount > 0, "hold authoritative user removal replay")
    await first.db.flushPersistence()
    assert.ok(first.db.get(first.db.ref(DbObjectKind.Space, targetSpace)), "A matched live eviction is a hint until user replay commits")
    assert.ok(first.db.get(first.db.ref(DbObjectKind.Chat, parentId)))
    assert.ok(first.db.get(first.db.ref(DbObjectKind.Chat, childId)))
    assert.equal(conversation.getSnapshot().unavailable, false)
    assert.equal(conversation.getSnapshot().messages.length, 1)
    assert.equal(conversation.getSnapshot().draft, draft)
    assert.ok(userSeq(first.db) < removal.userSeq)
    await request("/test/replay", { hold: false })
    await waitFor(() => userSeq(first.db) >= removal.userSeq && conversation.getSnapshot().unavailable, "publish committed ordered self-Space removal")
    await first.db.flushPersistence()
    assertExcluded(first.db, draft)
    assert.equal(conversation.getSnapshot().unavailable, true)
    assert.equal(conversation.getSnapshot().messages.length, 0)
    assert.equal(conversation.getSnapshot().draft, draft)
    assert.equal(conversation.getSnapshot().historyCertified, false)
    assert.equal(first.auth.getToken(), session.token, "Access removal must preserve the authenticated session")
    await request("/test/history", { hold: false })
    await deadline(lateHistory, "settle discarded old history response")
    assertExcluded(first.db, draft)
    assert.equal(conversation.getSnapshot().messages.length, 0, "A late old page must not resurrect visible history")
    assert.equal(conversation.getSnapshot().historyCertified, false, "A late old page must not certify the removed conversation")
    await closeOwner(first)
    evidence.removal = "matched live eviction preserved access while user replay was held; authoritative user cursor then removed public Space, parent, legacy child, dialogs and history; draft/auth preserved"
    evidence.delayedHistory = "pre-removal binary RPC result released after removal; no resurrection or certification"

    const second = await createOwner(session, true)
    await second.db.hydrateKinds([DbObjectKind.Message])
    // Compose is selectively hydrated by Conversation, outside default
    // navigation hydration. A removed chat cannot construct that owner.
    await second.db.hydrateObjects(DbObjectKind.MessageDraft, [draftKey])
    await second.db.hydrateObjects(DbObjectKind.SyncBucketState, ["user"])
    assertExcluded(second.db, draft)
    assert.ok(userSeq(second.db) >= removal.userSeq, "Reload must retain the committed user cursor")
    await second.client.connection.setNetworkAvailable(true)
    await waitFor(() => second.client.connectionState === "connected", "reconnect removed account")
    await deadline(second.client.query(getChats()), "refresh still-removed public Space")
    assertExcluded(second.db, draft)
    await assert.rejects(deadline(second.client.query(getChatHistory({ peerId: peer })), "reject unauthorized public child history"),
      (error: unknown) => error instanceof TransactionFailure && error.kind === "rpc-error" && error.code === 400,
      "The removed public child must receive an actual RPC denial, rather than a timeout or stopped client")
    assertExcluded(second.db, draft)
    evidence.removedReload = "cached first frame and online snapshots exclude removed data; public inherited history RPC is denied"

    await request("/test/history", { hold: true, chatId: String(childId) })
    const rejoin = await request<Access>("/test/access", { action: "rejoin" })
    assert.ok(rejoin.memberId && rejoin.memberId !== initialAccess.memberId, "Rejoin must create a new immutable membership")
    await waitFor(() => userSeq(second.db) >= rejoin.userSeq && second.db.get(second.db.ref(DbObjectKind.Chat, childId)) != null, "commit new-member rejoin and authorized sidecars")
    await second.db.flushPersistence()
    assert.equal(messages(second.db).length, 0, "Regrant metadata cannot revive old local history")
    const reopened = await openConversation(second)
    assert.equal(reopened.getSnapshot().draft, draft, "Regrant must prepare the preserved draft before presentation")
    assert.equal(reopened.getSnapshot().messages.length, 0)
    assert.equal(reopened.getSnapshot().historyCertified, false)
    assert.equal(reopened.getSnapshot().unavailable, false)
    await waitFor(async () => (await request<State>("/test/state")).heldHistoryCount === 1, "capture newly authorized history request")
    await request("/test/history", { hold: false })
    await waitFor(() => reopened.getSnapshot().historyCertified && !reopened.getSnapshot().refreshingLatest, "certify freshly authorized history")
    assert.equal(reopened.getSnapshot().messages.length, 1)
    assert.equal(reopened.getSnapshot().error, undefined)
    await closeOwner(second)

    const third = await createOwner(session, true)
    const granted = await openConversation(third)
    assert.equal(granted.getSnapshot().draft, draft)
    assert.equal(granted.getSnapshot().messages.length, 1, "A subsequently reloaded grant can use its fresh authorized cache")
    assert.equal(granted.getSnapshot().historyCertified, false, "Cached history still requires a fresh server certificate")
    await third.client.connection.setNetworkAvailable(true)
    await waitFor(() => third.client.connectionState === "connected", "reconnect new grant")
    await waitFor(() => granted.getSnapshot().historyCertified && !granted.getSnapshot().refreshingLatest, "recertify reloaded grant")
    const beforeLate = await request<State>("/test/state")
    await request("/test/replay", { hold: true })
    let detachReplay: (() => void) | undefined
    const replayed = new Promise<void>((resolve) => {
      detachReplay = third.db.subscribeToResidentChanges((batch) => {
        if (batch.changes.some((change) => change.kind === DbObjectKind.SyncBucketState && change.id === "user")) resolve()
      })
    })
    try {
      await request("/test/access", { action: "lateRemoval" })
      await waitFor(async () => {
        const state = await request<State>("/test/state")
        return state.heldUserReplayCount > 0 && (state.replays.user ?? 0) > (beforeLate.replays.user ?? 0)
      }, "hold user-specific replay after obsolete membership eviction")
      const heldReplay = await request<State>("/test/state")
      assert.ok(heldReplay.heldUserReplayPages.every((page) => page.seq === String(rejoin.userSeq) && page.updateCount === 0 && !page.hasSidecars),
        "Obsolete eviction must replay the current cursor as EMPTY without an invented repair catalog")
      assert.ok(third.db.get(third.db.ref(DbObjectKind.Space, targetSpace)))
      assert.equal(granted.getSnapshot().unavailable, false)
      await request("/test/replay", { hold: false })
      await deadline(replayed, "commit ordered replay for obsolete live membership eviction")
    } finally { detachReplay?.() }
    const afterLate = await request<State>("/test/state")
    assert.ok((afterLate.replays.user ?? 0) > (beforeLate.replays.user ?? 0))
    assert.ok(third.db.get(third.db.ref(DbObjectKind.Space, targetSpace)), "An obsolete live membership eviction cannot purge the newer grant")
    assert.ok(third.db.get(third.db.ref(DbObjectKind.Chat, parentId)))
    assert.ok(third.db.get(third.db.ref(DbObjectKind.Chat, childId)))
    assert.equal(granted.getSnapshot().unavailable, false)
    assert.equal(granted.getSnapshot().messages.length, 1)
    assert.equal(granted.getSnapshot().draft, draft)
    assert.equal(third.auth.getToken(), session.token)
    await closeOwner(third)
    const final = await request<State>("/test/state")
    assert.equal(final.openSockets, 0)
    assert.equal(final.heldHistoryCount, 0)
    assert.equal(final.heldUserReplayCount, 0)
    assert.equal(final.uniqueSentMessages, baseline.uniqueSentMessages, "Access qualification must not send chat messages")
    assert.equal(final.sendAttempts, baseline.sendAttempts)
    evidence.regrant = "new immutable member + ordered join restored current parent/child metadata; empty cache awaited fresh history; later reload retained grant and draft"
    evidence.oldMembershipEviction = "late unsequenced old-member removal requested ordered replay and preserved the new grant"
    evidence.emptyReplay = "held current-cursor user reply contained zero updates and no sidecars before binary delivery"
    evidence.membershipIds = { removed: initialAccess.memberId, rejoined: rejoin.memberId }
    evidence.userCursors = { removal: removal.userSeq, rejoin: rejoin.userSeq }
    evidence.rpcCounts = final.methods
    evidence.replayCounts = final.replays
    evidence.chatMessagesSent = 0
  } catch (error) { failure = error }
  finally {
    const cleanupErrors: string[] = []
    try { await request("/test/history", { hold: false }) } catch { cleanupErrors.push("release held history") }
    try { await request("/test/replay", { hold: false }) } catch { cleanupErrors.push("release held user replay") }
    for (const owner of owners) {
      try { await closeOwner(owner) } catch { cleanupErrors.push("drain and close owner") }
    }
    server.stop(true)
    evidence.closeMilliseconds = closeMilliseconds
    if (cleanupErrors.length) failure = new Error(`Access qualification cleanup failed: ${cleanupErrors.join(", ")}`)
  }
  if (failure) throw failure
  return evidence
}

if (import.meta.main) {
  qualifyProtocolAccess().then(
    (evidence) => { console.log(JSON.stringify({ ok: true, ...evidence }, null, 2)) },
    (error: unknown) => {
      console.error(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : "Protocol access qualification failed", browserAcceptance: false }))
      process.exitCode = 1
    },
  )
}
