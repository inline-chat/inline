import { describe, expect, spyOn, test } from "bun:test"
import { Method, RealtimeV3Request, RealtimeV3Response, RpcCall, RpcError_Code } from "@inline-chat/protocol/core"
import { InlineProtocolApplicationOutputOverloaded, type LoadedServerAuthorizationKey } from "@inline-chat/protocol/server"
import * as rpcHandlers from "@in/server/realtime/handlers/_rpc"
import {
  InlineProtocolApplicationLanes,
  inlineProtocolRpcExecutionLane,
  makeInlineProtocolApplicationDispatcher,
} from "./application"

const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((done) => { resolve = done })
  return { promise, resolve }
}

describe("Inline Protocol application ordering", () => {
  test("lets an authorized permanent key collect its browser-login result", async () => {
    let statusCalls = 0
    const dispatcher = makeInlineProtocolApplicationDispatcher({
      connectionId: "browser-status-after-auth-test",
      authorizationKeys: { load: async () => undefined },
      operations: {
        authBegin: async () => { throw new Error("unexpected auth") },
        authComplete: async () => { throw new Error("unexpected auth") },
        authBeginBrowser: async () => { throw new Error("unexpected auth") },
        authBrowserStatus: async () => {
          statusCalls += 1
          return { state: { oneofKind: "authorized", authorized: { accountSessionId: 9n } } }
        },
      },
    })
    const dispatched = await dispatcher.dispatch({
      payload: RealtimeV3Request.toBinary({
        body: {
          oneofKind: "authBrowserStatus",
          authBrowserStatus: { loginTransactionId: "transaction" },
        },
      }),
      authorization: {
        authKeyId: new Uint8Array(8),
        permanent: true,
        temporaryBound: false,
        userId: 7,
        accountSessionId: 9,
      },
      messageId: 1n,
      sessionId: 2n,
      signal: new AbortController().signal,
      markExecutionStarted: () => {},
      sendUpdate: () => {},
    })

    expect(statusCalls).toBe(1)
    expect(dispatched.kind).toBe("result")
    if (dispatched.kind !== "result") throw new Error("expected browser status result")
    expect(RealtimeV3Response.fromBinary(dispatched.payload).body.oneofKind)
      .toBe("authBrowserStatus")
  })

  test.each(["getFilePart", "transcribeVoiceDraft"] as const)("returns private %s content once and a compact replay response", async (methodName) => {
    const authorization = {
      authKeyId: new Uint8Array(8).fill(1),
      permanentAuthKeyId: new Uint8Array(8).fill(2),
      permanent: false, temporaryBound: true, userId: 1, accountSessionId: 2,
    }
    const active: LoadedServerAuthorizationKey = {
      key: new Uint8Array(256),
      keyId: authorization.authKeyId,
      temporary: true,
      currentServerSalt: 1n,
      expiresAt: Math.floor(Date.now() / 1000) + 3600,
      binding: {
        permanentAuthKeyId: authorization.permanentAuthKeyId,
        temporarySessionId: 3n,
        nonce: 4n,
        expiresAt: Math.floor(Date.now() / 1000) + 3600,
        userId: 1,
        accountSessionId: 2,
      },
    }
    const handler = spyOn(rpcHandlers, "handleRpcCall").mockImplementation(async () => methodName === "transcribeVoiceDraft" ? {
      oneofKind: "transcribeVoiceDraft", transcribeVoiceDraft: { text: "private dictation" },
    } : ({
      oneofKind: "getFilePart",
      getFilePart: {
        offset: 0n,
        totalSize: 3n,
        data: Uint8Array.of(1, 2, 3),
        sha256: new Uint8Array(32),
      },
    }))
    try {
      const dispatcher = makeInlineProtocolApplicationDispatcher({
        connectionId: "file-part-replay-test",
        authorizationKeys: { load: async () => active },
        operations: {
          authBegin: async () => { throw new Error("unexpected auth") },
          authComplete: async () => { throw new Error("unexpected auth") },
          authBeginBrowser: async () => { throw new Error("unexpected auth") },
          authBrowserStatus: async () => { throw new Error("unexpected auth") },
        },
      })
      const dispatched = await dispatcher.dispatch({
        payload: RealtimeV3Request.toBinary({
          body: { oneofKind: "rpc", rpc: RpcCall.create(methodName === "transcribeVoiceDraft" ? {
            method: Method.TRANSCRIBE_VOICE_DRAFT,
            input: { oneofKind: "transcribeVoiceDraft", transcribeVoiceDraft: { audio: Uint8Array.of(1), mimeType: "audio/mp4", duration: 1 } },
          } : {
            method: Method.GET_FILE_PART,
            input: { oneofKind: "getFilePart", getFilePart: {
              fileUniqueId: "IND_replay",
              offset: 0n,
              limit: 524_288,
            } },
          }) },
        }),
        authorization,
        messageId: 11n,
        sessionId: 3n,
        signal: new AbortController().signal,
        markExecutionStarted: () => {},
        sendUpdate: () => {},
      })
      expect(dispatched.kind).toBe("result")
      if (dispatched.kind !== "result") throw new Error("expected application result")
      expect(RealtimeV3Response.fromBinary(dispatched.payload).body.oneofKind).toBe("rpcResult")
      expect(dispatched.replayPayload).toBeDefined()
      const replay = RealtimeV3Response.fromBinary(dispatched.replayPayload!)
      expect(replay.body.oneofKind).toBe("rpcError")
      if (replay.body.oneofKind === "rpcError") {
        expect(replay.body.rpcError.reqMsgId).toBe(0n)
        expect(replay.body.rpcError.errorCode).toBe(RpcError_Code.RATE_LIMIT)
        expect(replay.body.rpcError.code).toBe(429)
        expect(replay.body.rpcError.message).toBe(`Retry ${methodName} with a fresh request ID`)
        expect(new TextDecoder().decode(dispatched.replayPayload)).not.toContain("private dictation")
      }
    } finally {
      handler.mockRestore()
    }
  })

  test.each(["revoked", "user", "session", "permanent"] as const)(
    "does not execute queued RPCs after authority is %s",
    async (change) => {
      const entered = deferred()
      const release = deferred()
      const authorization = {
        authKeyId: new Uint8Array(8).fill(1),
        permanentAuthKeyId: new Uint8Array(8).fill(2),
        permanent: false, temporaryBound: true, userId: 1, accountSessionId: 2,
      }
      const binding = {
        permanentAuthKeyId: authorization.permanentAuthKeyId,
        temporarySessionId: 3n, nonce: 4n, expiresAt: Math.floor(Date.now() / 1000) + 3600,
        userId: 1, accountSessionId: 2,
      }
      const active: LoadedServerAuthorizationKey = {
        key: new Uint8Array(256), keyId: authorization.authKeyId,
        temporary: true, currentServerSalt: 1n, expiresAt: binding.expiresAt, binding,
      }
      let current: LoadedServerAuthorizationKey | undefined = active
      let executions = 0
      let registrations = 0
      const handler = spyOn(rpcHandlers, "handleRpcCall").mockImplementation(async () => {
        executions++
        entered.resolve()
        await release.promise
        return { oneofKind: "updateUserSettings", updateUserSettings: { updates: [] } }
      })
      const dispatcher = makeInlineProtocolApplicationDispatcher({
        connectionId: "queued-auth-test",
        authorizationKeys: { load: async () => current },
        onAuthorized: () => { registrations++; return true },
        operations: {
          authBegin: async () => { throw new Error("unexpected auth") },
          authComplete: async () => { throw new Error("unexpected auth") },
          authBeginBrowser: async () => { throw new Error("unexpected auth") },
          authBrowserStatus: async () => { throw new Error("unexpected auth") },
        },
      })
      const marked: bigint[] = []
      const dispatch = (messageId: bigint) => dispatcher.dispatch({
        payload: RealtimeV3Request.toBinary({ body: { oneofKind: "rpc", rpc: RpcCall.create({
          method: Method.UPDATE_USER_SETTINGS,
          input: { oneofKind: "updateUserSettings", updateUserSettings: {} },
        }) } }),
        authorization, messageId, sessionId: 3n, signal: new AbortController().signal,
        markExecutionStarted: () => { marked.push(messageId) }, sendUpdate: () => {},
      })
      const inFlight: Promise<unknown>[] = []
      try {
        const first = dispatch(1n)
        inFlight.push(first)
        await entered.promise
        const second = dispatch(2n)
        inFlight.push(second)
        current = change === "revoked" ? undefined : {
          ...active,
          binding: {
            ...binding,
            ...(change === "user" ? { userId: 9 } : {}),
            ...(change === "session" ? { accountSessionId: 9 } : {}),
            ...(change === "permanent" ? { permanentAuthKeyId: new Uint8Array(8).fill(9) } : {}),
          },
        }
        release.resolve()
        await first
        const denied = await second
        expect(denied.kind).toBe("result")
        if (denied.kind !== "result") throw new Error("expected settled RPC error")
        const response = RealtimeV3Response.fromBinary(denied.payload)
        expect(response.body.oneofKind).toBe("rpcError")
        if (response.body.oneofKind === "rpcError") expect(response.body.rpcError.code).toBe(401)
        expect(executions).toBe(1)
        expect(registrations).toBe(1)
        expect(marked).toEqual([1n])
        current = active
        await dispatch(3n)
        expect(executions).toBe(2)
        expect(marked).toEqual([1n, 3n])
      } finally {
        release.resolve()
        await Promise.allSettled(inFlight)
        handler.mockRestore()
      }
    },
  )

  test("does not execute the first RPC when realtime admission rejects a revoked session", async () => {
    const authorization = {
      authKeyId: new Uint8Array(8).fill(1),
      permanentAuthKeyId: new Uint8Array(8).fill(2),
      permanent: false,
      temporaryBound: true,
      userId: 1,
      accountSessionId: 2,
    }
    const active: LoadedServerAuthorizationKey = {
      key: new Uint8Array(256),
      keyId: authorization.authKeyId,
      temporary: true,
      currentServerSalt: 1n,
      expiresAt: Math.floor(Date.now() / 1000) + 3600,
      binding: {
        permanentAuthKeyId: authorization.permanentAuthKeyId,
        temporarySessionId: 3n,
        nonce: 4n,
        expiresAt: Math.floor(Date.now() / 1000) + 3600,
        userId: authorization.userId,
        accountSessionId: authorization.accountSessionId,
      },
    }
    const handler = spyOn(rpcHandlers, "handleRpcCall")
    let executionStarted = false
    try {
      const dispatcher = makeInlineProtocolApplicationDispatcher({
        connectionId: "revoked-first-rpc-admission",
        authorizationKeys: { load: async () => active },
        // This is the result from V3 registration when the revoke event wins
        // after temporary-key validation but before application execution.
        onAuthorized: () => false,
        operations: {
          authBegin: async () => { throw new Error("unexpected auth") },
          authComplete: async () => { throw new Error("unexpected auth") },
          authBeginBrowser: async () => { throw new Error("unexpected auth") },
          authBrowserStatus: async () => { throw new Error("unexpected auth") },
        },
      })
      const result = await dispatcher.dispatch({
        payload: RealtimeV3Request.toBinary({ body: { oneofKind: "rpc", rpc: RpcCall.create({
          method: Method.UPDATE_USER_SETTINGS,
          input: { oneofKind: "updateUserSettings", updateUserSettings: {} },
        }) } }),
        authorization,
        messageId: 1n,
        sessionId: 3n,
        signal: new AbortController().signal,
        markExecutionStarted: () => { executionStarted = true },
        sendUpdate: () => {},
      })

      expect(result.kind).toBe("result")
      if (result.kind !== "result") throw new Error("expected RPC error")
      const response = RealtimeV3Response.fromBinary(result.payload)
      expect(response.body.oneofKind).toBe("rpcError")
      if (response.body.oneofKind === "rpcError") expect(response.body.rpcError.code).toBe(401)
      expect(executionStarted).toBeFalse()
      expect(handler).not.toHaveBeenCalled()
    } finally {
      handler.mockRestore()
    }
  })

  test("marks execution at the application boundary and preserves output overload", async () => {
    const dispatcher = makeInlineProtocolApplicationDispatcher({
      connectionId: "test",
      authorizationKeys: { load: async () => undefined },
      operations: {
        authBegin: async () => { throw new InlineProtocolApplicationOutputOverloaded() },
        authComplete: async () => ({ state: { oneofKind: undefined } }),
        authBeginBrowser: async () => ({ loginTransactionId: "", browserUrl: "", verificationCode: "", expiresAt: 0n }),
        authBrowserStatus: async () => ({ state: { oneofKind: undefined } }),
      },
    })
    let executionStarted = false
    const dispatched = dispatcher.dispatch({
      payload: RealtimeV3Request.toBinary({
        body: {
          oneofKind: "authBegin",
          authBegin: { identifier: { oneofKind: undefined } },
        },
      }),
      authorization: {
        authKeyId: new Uint8Array(8),
        permanent: true,
        temporaryBound: false,
      },
      messageId: 1n,
      sessionId: 2n,
      signal: new AbortController().signal,
      markExecutionStarted: () => { executionStarted = true },
      sendUpdate: () => {},
    })

    await expect(dispatched).rejects.toBeInstanceOf(InlineProtocolApplicationOutputOverloaded)
    expect(executionStarted).toBeTrue()
  })

  test("preserves an aborted handler for secure-session outcome classification", async () => {
    const controller = new AbortController()
    const reason = new DOMException("Application deadline exceeded", "AbortError")
    const dispatcher = makeInlineProtocolApplicationDispatcher({
      connectionId: "test",
      authorizationKeys: { load: async () => undefined },
      operations: {
        authBegin: async () => {
          controller.abort(reason)
          throw reason
        },
        authComplete: async () => ({ state: { oneofKind: undefined } }),
        authBeginBrowser: async () => ({ loginTransactionId: "", browserUrl: "", verificationCode: "", expiresAt: 0n }),
        authBrowserStatus: async () => ({ state: { oneofKind: undefined } }),
      },
    })
    let executionStarted = false

    const dispatched = dispatcher.dispatch({
      payload: RealtimeV3Request.toBinary({
        body: {
          oneofKind: "authBegin",
          authBegin: { identifier: { oneofKind: undefined } },
        },
      }),
      authorization: {
        authKeyId: new Uint8Array(8),
        permanent: true,
        temporaryBound: false,
      },
      messageId: 1n,
      sessionId: 2n,
      signal: controller.signal,
      markExecutionStarted: () => { executionStarted = true },
      sendUpdate: () => {},
    })

    await expect(dispatched).rejects.toBe(reason)
    expect(executionStarted).toBeTrue()
  })

  test("serializes one conversation while unrelated work bypasses it", async () => {
    const lanes = new InlineProtocolApplicationLanes()
    const controller = new AbortController()
    const firstGate = deferred()
    const order: string[] = []
    const first = lanes.run("chat:1", controller.signal, async () => {
      order.push("first:start")
      await firstGate.promise
      order.push("first:end")
    })
    const second = lanes.run("chat:1", controller.signal, async () => {
      order.push("second")
    })
    const unrelated = lanes.run("chat:2", controller.signal, async () => {
      order.push("unrelated")
    })

    await unrelated
    expect(order).toEqual(["first:start", "unrelated"])
    firstGate.resolve()
    await Promise.all([first, second])
    expect(order).toEqual(["first:start", "unrelated", "first:end", "second"])
  })

  test("an aborted waiter releases its place without running", async () => {
    const lanes = new InlineProtocolApplicationLanes()
    const firstGate = deferred()
    const first = lanes.run("chat:1", new AbortController().signal, () => firstGate.promise)
    const waitingController = new AbortController()
    let ran = false
    const waiting = lanes.run("chat:1", waitingController.signal, async () => { ran = true })
    waitingController.abort()

    await expect(waiting).rejects.toBeInstanceOf(DOMException)
    expect(ran).toBe(false)
    firstGate.resolve()
    await first
    await expect(lanes.run("chat:1", new AbortController().signal, async () => 42)).resolves.toBe(42)
  })

  test("an aborted waiter cannot let later work bypass the active owner", async () => {
    const lanes = new InlineProtocolApplicationLanes()
    const firstGate = deferred()
    const order: string[] = []
    const first = lanes.run("chat:1", new AbortController().signal, async () => {
      order.push("first:start")
      await firstGate.promise
      order.push("first:end")
    })
    const waitingController = new AbortController()
    const waiting = lanes.run("chat:1", waitingController.signal, async () => {
      order.push("aborted")
    })
    waitingController.abort()
    await expect(waiting).rejects.toBeInstanceOf(DOMException)

    const later = lanes.run("chat:1", new AbortController().signal, async () => {
      order.push("later")
    })
    await Bun.sleep(5)
    expect(order).toEqual(["first:start"])

    firstGate.resolve()
    await Promise.all([first, later])
    expect(order).toEqual(["first:start", "first:end", "later"])
  })

  test("maps ordering-sensitive conversation mutations onto the same narrow lane", () => {
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: 44n } } }
    const send = RpcCall.create({
      input: { oneofKind: "sendMessage", sendMessage: { peerId } },
    })
    const remove = RpcCall.create({
      input: { oneofKind: "deleteMessages", deleteMessages: { peerId, messageIds: [9n] } },
    })
    const unrelated = RpcCall.create({
      input: {
        oneofKind: "sendMessage",
        sendMessage: { peerId: { type: { oneofKind: "chat", chat: { chatId: 45n } } } },
      },
    })

    expect(inlineProtocolRpcExecutionLane(send)).toBe("chat:44")
    expect(inlineProtocolRpcExecutionLane(remove)).toBe("chat:44")
    expect(inlineProtocolRpcExecutionLane(unrelated)).toBe("chat:45")
  })

  test("keeps dialog, forwarding, and attachment mutations on their conversation lane", () => {
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: 44n } } }
    const calls = [
      RpcCall.create({
        input: {
          oneofKind: "forwardMessages",
          forwardMessages: { toPeerId: peerId, messageIds: [1n] },
        },
      }),
      RpcCall.create({
        input: {
          oneofKind: "deleteMessageAttachment",
          deleteMessageAttachment: { peerId, messageId: 9n, attachmentId: 3n },
        },
      }),
      RpcCall.create({
        input: { oneofKind: "updateDialogOpen", updateDialogOpen: { peerId, open: false } },
      }),
      RpcCall.create({
        input: {
          oneofKind: "updateDialogNotificationSettings",
          updateDialogNotificationSettings: { peerId },
        },
      }),
      RpcCall.create({
        input: { oneofKind: "updateDialogArchived", updateDialogArchived: { peerId, archived: true } },
      }),
    ]

    expect(calls.map(inlineProtocolRpcExecutionLane)).toEqual(Array(5).fill("chat:44"))
  })

  test("serializes account and space mutations without blocking unrelated conversations", () => {
    const settings = RpcCall.create({
      input: { oneofKind: "updateUserSettings", updateUserSettings: {} },
    })
    const member = RpcCall.create({
      input: { oneofKind: "updateMemberAccess", updateMemberAccess: { spaceId: 8n, userId: 2n } },
    })
    const grid = RpcCall.create({
      input: { oneofKind: "toggleSpaceGrid", toggleSpaceGrid: { spaceId: 8n, enabled: true } },
    })

    expect(inlineProtocolRpcExecutionLane(settings)).toBe("account:settings")
    expect(inlineProtocolRpcExecutionLane(member)).toBe("space:8")
    expect(inlineProtocolRpcExecutionLane(grid)).toBe("space:8")
  })

  test("serializes agent connection and sync mutations on their narrow owners", () => {
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: 44n } } }
    const connect = RpcCall.create({
      input: {
        oneofKind: "connectAgentSession",
        connectAgentSession: {
          peerId,
          botUserId: 2n,
          provider: 1,
          instanceRef: "instance",
          sessionRef: "session",
        },
      },
    })
    const sync = RpcCall.create({
      input: {
        oneofKind: "syncAgentSessionMessages",
        syncAgentSessionMessages: { agentSessionId: 91n, mode: 1, messages: [] },
      },
    })

    expect(inlineProtocolRpcExecutionLane(connect)).toBe("chat:44")
    expect(inlineProtocolRpcExecutionLane(sync)).toBe("agent-session:91")
  })
})
