import { beforeEach, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import {
  GetChatHistoryInput,
  GetMeInput,
  InputPeer,
  Method,
  RpcCall,
  RpcError,
  RpcError_Code,
  RpcResult,
} from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { sessions, users } from "@in/server/db/schema"
import { makeCandidateHttpApplication } from "@in/server/core/http/candidateApplication"
import { startCoreHttpServer } from "@in/server/core/http/host"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import {
  HTTP_RPC_AUTH_FAILURE_LIMIT,
  HTTP_RPC_AUTH_REASON_HEADER,
  HTTP_RPC_CONTENT_TYPE,
  HTTP_RPC_MAX_BODY_BYTES,
  HTTP_RPC_PATH,
  handleHttpRpcRequest,
  resetHttpRpcLimitsForTests,
} from "@in/server/realtime/httpRpc"
import { toRealtimeRpcError } from "@in/server/realtime/rpcErrorBoundary"
import type { HandlerContext } from "@in/server/realtime/types"
import { connectionManager } from "@in/server/ws/connections"

setupTestLifecycle()

const CLIENT_IP = "203.0.113.7"

const chatPeer = (chatId: number) => InputPeer.create({ type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } })

const historyCall = (chatId: number): RpcCall => RpcCall.create({
  method: Method.GET_CHAT_HISTORY,
  input: { oneofKind: "getChatHistory", getChatHistory: GetChatHistoryInput.create({ peerId: chatPeer(chatId), limit: 10 }) },
})

const rpcRequest = (
  body: BodyInit | null,
  options: { token?: string; contentType?: string; headers?: Record<string, string> } = {},
) => new Request(`http://localhost${HTTP_RPC_PATH}`, {
  method: "POST",
  headers: {
    ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
    "content-type": options.contentType ?? HTTP_RPC_CONTENT_TYPE,
    ...options.headers,
  },
  body,
})

const encode = (call: RpcCall) => RpcCall.toBinary(call) as Uint8Array<ArrayBuffer>

const invoke = (call: RpcCall, token?: string) =>
  handleHttpRpcRequest(rpcRequest(encode(call), { token }), { clientIp: CLIENT_IP })

const decodeError = async (response: Response) => RpcError.fromBinary(new Uint8Array(await response.arrayBuffer()))
const decodeResult = async (response: Response) => RpcResult.fromBinary(new Uint8Array(await response.arrayBuffer()))

const realtimeContext = (userId: number, sessionId: number): HandlerContext => ({
  userId,
  sessionId,
  isBot: false,
  connectionId: "realtime-reference",
  sendRaw() {},
  sendRpcReply() {},
})

/** One member, one space thread holding one message, and a socket-free session. */
const fixture = async () => {
  const { space, users: [member] } = await testUtils.createSpaceWithMembers("Http RPC", [`http-rpc-${crypto.randomUUID()}@example.com`] as const)
  const { chat } = await testUtils.createThreadWithDialogAndMessage({ spaceId: space.id, user: member, messageText: "hello over http" })
  const { token, session } = await testUtils.createSessionForUser(member.id, {
    clientType: "api",
    clientVersion: "1.2.3",
    osVersion: "14.0",
  })
  return { member, chat, token, session }
}

describe("stateless HTTP RPC", () => {
  beforeEach(() => resetHttpRpcLimitsForTests())

  test("returns the same result as the realtime path for allowed reads", async () => {
    const { member, chat, token, session } = await fixture()

    for (const call of [
      historyCall(chat.id),
      RpcCall.create({ method: Method.GET_ME, input: { oneofKind: "getMe", getMe: GetMeInput.create({}) } }),
    ]) {
      const response = await invoke(call, token)
      expect(response.status).toBe(200)
      expect(response.headers.get("content-type")).toBe(HTTP_RPC_CONTENT_TYPE)
      const viaHttp = await decodeResult(response)
      const viaRealtime = await handleRpcCall(call, realtimeContext(member.id, session.id))
      expect(viaHttp.result).toEqual(RpcResult.fromBinary(RpcResult.toBinary({ reqMsgId: 0n, result: viaRealtime })).result)
    }
  })

  test("executes an allowed write without a socket", async () => {
    const { chat, token } = await fixture()
    const response = await invoke(RpcCall.create({
      method: Method.SEND_MESSAGE,
      input: { oneofKind: "sendMessage", sendMessage: { peerId: chatPeer(chat.id), message: "sent over http", randomId: 77n } },
    }), token)
    expect(response.status).toBe(200)
    const { result } = await decodeResult(response)
    if (result.oneofKind !== "sendMessage") throw new Error("expected sendMessage result")
    expect(result.sendMessage.updates.length).toBeGreaterThan(0)
  })

  test("rejects missing, invalid, revoked and deactivated credentials like realtime init", async () => {
    const { member, chat, token, session } = await fixture()
    const call = historyCall(chat.id)

    const cases: Array<[string | undefined, string]> = [
      [undefined, "INVALID_AUTH"],
      [`${member.id}:not-a-real-token`, "INVALID_AUTH"],
    ]
    for (const [candidate, reason] of cases) {
      const response = await invoke(call, candidate)
      expect(response.status).toBe(401)
      expect(response.headers.get(HTTP_RPC_AUTH_REASON_HEADER)).toBe(reason)
      const error = await decodeError(response)
      expect(error.errorCode).toBe(RpcError_Code.UNAUTHENTICATED)
      expect(error.code).toBe(401)
      expect(error.message).toBe("Unauthenticated")
    }

    await db.update(sessions).set({ revoked: new Date() }).where(eq(sessions.id, session.id))
    const revoked = await invoke(call, token)
    expect(revoked.status).toBe(401)
    expect(revoked.headers.get(HTTP_RPC_AUTH_REASON_HEADER)).toBe("SESSION_REVOKED")
    expect((await decodeError(revoked)).errorCode).toBe(RpcError_Code.UNAUTHENTICATED)

    const other = await fixture()
    await db.update(users).set({ deleted: true }).where(eq(users.id, other.member.id))
    const deactivated = await invoke(historyCall(other.chat.id), other.token)
    expect(deactivated.status).toBe(401)
    expect(deactivated.headers.get(HTTP_RPC_AUTH_REASON_HEADER)).toBe("UNAUTHORIZED")
  })

  test("rejects methods that need a socket", async () => {
    const { token } = await fixture()
    for (const call of [
      RpcCall.create({ method: Method.GET_UPDATES, input: { oneofKind: "getUpdates", getUpdates: {} as never } }),
      RpcCall.create({ method: Method.GET_UPDATES_STATE, input: { oneofKind: "getUpdatesState", getUpdatesState: {} as never } }),
    ]) {
      const response = await invoke(call, token)
      expect(response.status).toBe(400)
      const error = await decodeError(response)
      expect(error.errorCode).toBe(RpcError_Code.BAD_REQUEST)
      expect(error.message).toBe(`Unsupported RPC method: ${call.method}`)
    }
  })

  test("rejects malformed bodies and the wrong content type", async () => {
    const { token } = await fixture()
    const malformed = await handleHttpRpcRequest(
      rpcRequest(new Uint8Array([0xff, 0xff, 0xff, 0xff, 0xff]), { token }),
      { clientIp: CLIENT_IP },
    )
    expect(malformed.status).toBe(400)
    expect((await decodeError(malformed)).errorCode).toBe(RpcError_Code.BAD_REQUEST)

    const json = await handleHttpRpcRequest(rpcRequest("{}", { token, contentType: "application/json" }), { clientIp: CLIENT_IP })
    expect(json.status).toBe(415)
  })

  test("rejects oversized bodies by declared length and while streaming", async () => {
    const { token } = await fixture()
    const declared = await handleHttpRpcRequest(
      rpcRequest(new Uint8Array(HTTP_RPC_MAX_BODY_BYTES + 1), { token }),
      { clientIp: CLIENT_IP },
    )
    expect(declared.status).toBe(413)

    const chunk = new Uint8Array(64 * 1024)
    let sent = 0
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent > HTTP_RPC_MAX_BODY_BYTES) return controller.close()
        sent += chunk.byteLength
        controller.enqueue(chunk)
      },
    })
    const streamed = await handleHttpRpcRequest(
      new Request(`http://localhost${HTTP_RPC_PATH}`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": HTTP_RPC_CONTENT_TYPE },
        body: stream,
        duplex: "half",
      } as RequestInit),
      { clientIp: CLIENT_IP },
    )
    expect(streamed.status).toBe(413)
    expect((await decodeError(streamed)).message).toBe("Request body too large")
  })

  test("surfaces mapped handler errors exactly like the realtime boundary", async () => {
    const { member, token, session } = await fixture()
    const call = historyCall(2_000_000_000)
    const response = await invoke(call, token)
    const expected = await handleRpcCall(call, realtimeContext(member.id, session.id)).then(
      () => { throw new Error("expected realtime failure") },
      (error: unknown) => toRealtimeRpcError(error),
    )
    expect(expected.codeNumber).toBeLessThan(500)
    expect(response.status).toBe(expected.codeNumber)
    const error = await decodeError(response)
    expect(error.errorCode).toBe(expected.code)
    expect(error.message).toBe(expected.message)
    expect(error.code).toBe(expected.codeNumber)
  })

  test("never registers a connection, presence, or session client metadata", async () => {
    const { member, chat, token, session } = await fixture()
    const authenticatedBefore = connectionManager.getAuthenticatedConnectionCount()
    const [userBefore] = await db.select({ online: users.online, lastOnline: users.lastOnline }).from(users).where(eq(users.id, member.id))

    const response = await invoke(historyCall(chat.id), token)
    expect(response.status).toBe(200)
    // Let any detached work (there should be none) settle.
    await new Promise((resolve) => setTimeout(resolve, 50))

    expect(connectionManager.getUserConnections(member.id)).toHaveLength(0)
    expect(connectionManager.getConnectionBySession(member.id, session.id)).toBeUndefined()
    expect(connectionManager.getAuthenticatedConnectionCount()).toBe(authenticatedBefore)
    const [after] = await db
      .select({ clientVersion: sessions.clientVersion, osVersion: sessions.osVersion })
      .from(sessions)
      .where(eq(sessions.id, session.id))
    expect(after).toEqual({ clientVersion: "1.2.3", osVersion: "14.0" })
    const [userAfter] = await db.select({ online: users.online, lastOnline: users.lastOnline }).from(users).where(eq(users.id, member.id))
    expect(userAfter).toEqual(userBefore!)
  })

  test("throttles one address after repeated credential failures", async () => {
    const { chat, token } = await fixture()
    for (let attempt = 0; attempt < HTTP_RPC_AUTH_FAILURE_LIMIT.max; attempt++) {
      expect((await invoke(historyCall(chat.id))).status).toBe(401)
    }
    const blocked = await invoke(historyCall(chat.id), token)
    expect(blocked.status).toBe(429)
    expect(Number(blocked.headers.get("retry-after"))).toBeGreaterThan(0)
    expect((await decodeError(blocked)).errorCode).toBe(RpcError_Code.RATE_LIMIT)

    const elsewhere = await handleHttpRpcRequest(rpcRequest(encode(historyCall(chat.id)), { token }), { clientIp: "198.51.100.9" })
    expect(elsewhere.status).toBe(200)
  })

  test("is mounted on the production application without the per-IP legacy budget", async () => {
    const { chat, token } = await fixture()
    const host = await startCoreHttpServer({
      application: makeCandidateHttpApplication({ middleware: { isProduction: false } }),
      hostname: "127.0.0.1",
      installSignalHandlers: false,
    })
    try {
      const response = await fetch(`http://127.0.0.1:${host.port}${HTTP_RPC_PATH}`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": HTTP_RPC_CONTENT_TYPE },
        body: encode(historyCall(chat.id)),
      })
      expect(response.status).toBe(200)
      expect(response.headers.get("cache-control")).toBe("no-store")
      expect(response.headers.get("ratelimit-limit")).toBeNull()
      const { result } = await decodeResult(response)
      expect(result.oneofKind).toBe("getChatHistory")

      const unauthenticated = await fetch(`http://127.0.0.1:${host.port}${HTTP_RPC_PATH}`, {
        method: "POST",
        headers: { "content-type": HTTP_RPC_CONTENT_TYPE },
        body: encode(historyCall(chat.id)),
      })
      expect(unauthenticated.status).toBe(401)
      expect(unauthenticated.headers.get(HTTP_RPC_AUTH_REASON_HEADER)).toBe("INVALID_AUTH")
    } finally {
      await host.shutdown()
    }
  })
})
