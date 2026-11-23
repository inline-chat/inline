import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import { Cause, Effect } from "effect"
import { HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import type { HttpMethod } from "effect/unstable/http/HttpMethod"
import { CreateSubthreadInput, InputPeer, Method, RpcCall, SendMessageInput } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { executeOAuth } from "@in/server/controllers/oauth.effect"
import { ErrorReporter } from "@in/server/core/errors/errorReporter"
import { generateRequestId } from "@in/server/core/helpers/requestId"
import { HttpRequestContext } from "@in/server/core/http/requestContext"
import { OauthModel } from "@in/server/db/models/oauth"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { oauthConfig } from "@in/server/modules/oauth/config"
import { OAuthHttpService } from "@in/server/modules/oauth/httpService.effect"
import { makeOAuthHttpService } from "@in/server/modules/oauth/httpServiceAdapter.effect"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { countTransferWork } from "@in/server/modules/transfers/trace"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { HTTP_RPC_PATH, handleHttpRpcRequest, resetHttpRpcLimitsForTests } from "@in/server/realtime/httpRpc"
import type { HandlerContext } from "@in/server/realtime/types"

/**
 * Database cost of one MCP tool call, end to end: the independently built MCP
 * HTTP app introspects through the real OAuth route and reads through the real
 * /v1/rpc handler, and every SQL statement either one issues is counted. Shaped
 * like an archive client (msgvault): catalog pages, then per chat the details
 * and newest-first history pages.
 * Build packages/mcp first (bun run --cwd packages/mcp build).
 */
setupTestLifecycle()

const INTERNAL_SECRET = "test-read-cost-shared-secret"
const ACCESS_TOKEN = "read-cost-access-token"
// A variable keeps the server typecheck independent of the MCP build output.
const MCP_APP_MODULE = "../../../../packages/mcp/dist/server/app.js"

const chatPeer = (chatId: number) => InputPeer.create({ type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } })
const context = (userId: number): HandlerContext => ({ userId, sessionId: 1, isBot: false, connectionId: "", sendRaw() {}, sendRpcReply() {} })
const rpc = (userId: number, call: RpcCall) => handleRpcCall(call, context(userId))
let randomId = 1n
const send = (userId: number, chatId: number, text: string) => rpc(userId, RpcCall.create({
  method: Method.SEND_MESSAGE,
  input: { oneofKind: "sendMessage", sendMessage: SendMessageInput.create({ peerId: chatPeer(chatId), message: text, randomId: randomId++ }) },
}))

const introspect = async (request: Request) => {
  const { makeOAuthHttpHandlers } = await import("@in/server/modules/oauth/httpServiceLive.effect")
  const service = makeOAuthHttpService(makeOAuthHttpHandlers(new InMemoryRateLimiter()))
  const reports: string[] = []
  const response = await Effect.runPromise(executeOAuth("introspect", HttpServerRequest.fromWeb(request)).pipe(
    Effect.provideService(OAuthHttpService, service),
    Effect.provideService(HttpRequestContext, {
      clientIp: "127.0.0.1", requestId: generateRequestId(), method: request.method as HttpMethod,
      path: new URL(request.url).pathname, startedAtMillis: Date.now(),
    }),
    Effect.provideService(ErrorReporter, { report: (report) => Effect.sync(() => { reports.push(Cause.pretty(report.cause)) }) }),
  ))
  expect(reports).toEqual([])
  return HttpServerResponse.toWeb(response)
}

/** Statements and RPCs the API served since the last reset, across both routes. */
const tally = { statements: 0, introspections: 0, rpcs: [] as string[] }

type Fixture = Awaited<ReturnType<typeof createFixture>>

async function createFixture() {
  const suffix = crypto.randomUUID()
  const { space, users: [viewer, alice, bob] } = await testUtils.createSpaceWithMembers("Archive", [
    `viewer-${suffix}@example.com`, `alice-${suffix}@example.com`, `bob-${suffix}@example.com`,
  ] as const)
  const { chat } = await testUtils.createThreadWithDialogAndMessage({ spaceId: space.id, user: viewer, title: "General" })
  const senders = [viewer, alice, bob]
  for (let index = 0; index < 60; index++) await send(senders[index % 3]!.id, chat.id, `message ${index}`)
  // A reply thread under a recent message, so app history pages carry thread badges.
  await rpc(alice.id, RpcCall.create({
    method: Method.CREATE_SUBTHREAD,
    input: { oneofKind: "createSubthread", createSubthread: CreateSubthreadInput.create({ parentChatId: BigInt(chat.id), parentMessageId: 55n }) },
  }))
  for (let index = 0; index < 5; index++) await testUtils.createChat(space.id, `Other ${index}`, "thread", true)
  // DMs whose peer is deleted or has not finished signing up keep their names.
  const dms: number[] = []
  for (const state of [{ deleted: true }, { pendingSetup: true }] as const) {
    const peer = await testUtils.createUser(`peer-${crypto.randomUUID()}@example.com`)
    await db.update(schema.users).set({ firstName: "Gone", lastName: "Peer", username: `gone${peer.id}`, ...state }).where(eq(schema.users.id, peer.id))
    const { chat: dm } = await testUtils.createDMWithDialogAndMessage({ spaceId: null as unknown as number, userA: viewer, userB: peer })
    dms.push(dm.id)
  }

  const session = await testUtils.createSessionForUser(viewer.id, { clientType: "api" })
  await OauthModel.createClient({ clientId: `cost-${suffix}`, clientName: "msgvault", redirectUris: ["http://127.0.0.1:8089/callback"], nowMs: Date.now() })
  const grant = await OauthModel.createGrant({
    id: crypto.randomUUID(), clientId: `cost-${suffix}`, inlineUserId: viewer.id,
    scope: "messages:read offline_access", resource: oauthConfig().resource, spaceIds: [BigInt(space.id)], allowDms: true, allowHomeThreads: true,
    inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(session.token)), nowMs: Date.now(),
  })
  await OauthModel.createAccessToken({
    tokenHash: createHash("sha256").update(ACCESS_TOKEN).digest("hex"), grantId: grant.id, nowMs: Date.now(), expiresAtMs: Date.now() + 600_000,
  })
  return { space, viewer, chat, dms }
}

type Mcp = Awaited<ReturnType<typeof startMcp>>

/** The built MCP app against this server. */
async function startMcp() {
  const api = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: async (request) => {
      const path = new URL(request.url).pathname
      if (path === "/oauth/introspect") {
        const { value, counters } = await countTransferWork(() => introspect(request))
        tally.statements += counters.sqlStatements
        tally.introspections += 1
        return value
      }
      if (path === HTTP_RPC_PATH) {
        const body = new Uint8Array(await request.arrayBuffer())
        const call = RpcCall.fromBinary(body)
        const replay = new Request(request.url, { method: "POST", headers: request.headers, body })
        tally.rpcs.push(Method[call.method] ?? "?")
        const { value, counters } = await countTransferWork(() => handleHttpRpcRequest(replay, { clientIp: "127.0.0.1" }))
        tally.statements += counters.sqlStatements
        return value
      }
      return new Response(null, { status: 404 })
    },
  })
  const { createApp } = await import(MCP_APP_MODULE) as { createApp: (options: Record<string, unknown>) => { fetch: (request: Request) => Promise<Response> } }
  const app = createApp({
    issuer: oauthConfig().resource, allowedHosts: ["127.0.0.1"], oauthInternalSharedSecret: INTERNAL_SECRET,
    oauthProxyBaseUrl: `http://127.0.0.1:${api.port}`, oauthIntrospectionUrl: `http://127.0.0.1:${api.port}/oauth/introspect`,
    inlineApiBaseUrl: `http://127.0.0.1:${api.port}`,
  })
  const mcp = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: (request) => app.fetch(request) })

  let id = 1
  /** One stateless tools/call; returns its structured result and what it cost. */
  const tool = async (name: string, args: Record<string, unknown>) => {
    tally.statements = 0
    tally.introspections = 0
    tally.rpcs = []
    const response = await fetch(`http://127.0.0.1:${mcp.port}/mcp/v2`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${ACCESS_TOKEN}`, "content-type": "application/json", accept: "application/json",
        "mcp-protocol-version": "2026-07-28", "mcp-method": "tools/call", "mcp-name": name,
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: id++, method: "tools/call", params: {
        name, arguments: args,
        _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {} },
      } }),
    })
    if (response.status !== 200) throw new Error(`${name}: HTTP ${response.status} ${await response.text()}`)
    const body = await response.json() as { result?: { structuredContent?: Record<string, unknown>; isError?: boolean; content?: unknown }; error?: unknown }
    if (!body.result || body.result.isError) throw new Error(`${name} failed: ${JSON.stringify(body.error ?? body.result?.content)}`)
    return {
      result: body.result.structuredContent as Record<string, unknown>,
      statements: tally.statements,
      introspections: tally.introspections,
      rpcs: [...tally.rpcs],
    }
  }
  const stop = async () => {
    await mcp.stop(true)
    await api.stop(true)
  }
  return { tool, stop }
}

/** Statements per call, introspection included; lower them as reads get cheaper. */
const BUDGET = {
  "conversations.get": 33,
  "messages.list newest page": 34,
  "messages.list older page": 40,
}

type Measured = Awaited<ReturnType<Mcp["tool"]>>

/** The calls of one archive pass over one chat, in msgvault's order. */
async function archivePass(mcp: Mcp, fixture: Fixture) {
  const chatId = String(fixture.chat.id)
  // Warm process-local caches (space labels, attribution) like a running server.
  await mcp.tool("conversations.get", { chatId })
  await mcp.tool("messages.list", { chatId, limit: 50 })

  const list = await mcp.tool("conversations.list", { includeSubthreads: true, sort: "id", limit: 50 })
  const get = await mcp.tool("conversations.get", { chatId })
  const newest = await mcp.tool("messages.list", { chatId, limit: 50 })
  const older = await mcp.tool("messages.list", { chatId, limit: 50, offsetId: newest.result["nextOffsetId"] })
  const deletedPeer = String(fixture.dms[0])
  const pendingPeer = String(fixture.dms[1])
  return {
    "DM with a deleted peer: conversations.get": await mcp.tool("conversations.get", { chatId: deletedPeer }),
    "DM with a deleted peer: messages.list": await mcp.tool("messages.list", { chatId: deletedPeer, limit: 50 }),
    "DM with a pending peer: conversations.get": await mcp.tool("conversations.get", { chatId: pendingPeer }),
    "DM with a pending peer: messages.list": await mcp.tool("messages.list", { chatId: pendingPeer, limit: 50 }),
    "conversations.list archive page": list,
    "conversations.get": get,
    "messages.list newest page": newest,
    "messages.list older page": older,
  } satisfies Record<string, Measured>
}

const summary = (pass: Record<string, Measured>) => Object.fromEntries(Object.entries(pass).map(([key, value]) => [key, {
  statements: value.statements, introspections: value.introspections, rpcs: value.rpcs.join(" "),
}]))

describe("MCP read cost per tool call", () => {
  const stops: Array<() => Promise<void>> = []
  let previousSecret: string | undefined
  beforeEach(() => {
    resetHttpRpcLimitsForTests()
    previousSecret = process.env["MCP_INTERNAL_SHARED_SECRET"]
    process.env["MCP_INTERNAL_SHARED_SECRET"] = INTERNAL_SECRET
  })
  // The test lifecycle empties the database before each test, so each test
  // builds its own fixture and servers.
  afterEach(async () => {
    for (const stop of stops.splice(0)) await stop()
    if (previousSecret === undefined) delete process.env["MCP_INTERNAL_SHARED_SECRET"]
    else process.env["MCP_INTERNAL_SHARED_SECRET"] = previousSecret
  })

  test("an archive pass stays within its statement budget", async () => {
    const fixture = await createFixture()
    const mcp = await startMcp()
    stops.push(mcp.stop)
    const pass = await archivePass(mcp, fixture)
    console.log("MCP_READ_COST", JSON.stringify(summary(pass), null, 1))

    expect((pass["messages.list newest page"].result["messages"] as unknown[]).length).toBe(50)
    expect(pass["DM with a deleted peer: messages.list"].result["chat"]).toMatchObject({ title: "Gone Peer" })
    expect(pass["conversations.get"].rpcs).toEqual(["GET_CHAT", "GET_MESSAGES", "GET_CHAT_PARTICIPANTS"])
    expect(pass["messages.list newest page"].rpcs).toEqual(["GET_CHAT", "GET_CHAT_HISTORY", "GET_USERS"])
    expect(pass["conversations.get"].statements).toBeLessThanOrEqual(BUDGET["conversations.get"])
    expect(pass["messages.list newest page"].statements).toBeLessThanOrEqual(BUDGET["messages.list newest page"])
    expect(pass["messages.list older page"].statements).toBeLessThanOrEqual(BUDGET["messages.list older page"])
  }, 120_000)
})
