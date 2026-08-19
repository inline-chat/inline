import { describe, expect, test } from "bun:test"
import { constants, generateKeyPairSync, privateDecrypt, randomBytes } from "node:crypto"
import { gzipSync, gunzipSync } from "node:zlib"
import {
  InlineHandshakeClient,
  InlineProtocolServerSession,
  MessageIdGenerator,
  ServiceConstructor,
  authKeyId,
  bytesToHex,
  createTemporaryKeyBindingProof,
  decodeInlineApplicationObject,
  decodeMsgsAck,
  decodeRpcError,
  decodeRpcResult,
  decodeRpcDropAnswerResult,
  decodeUnencryptedRecord,
  decryptRecord,
  decryptRecordWithMetadata,
  encodeGzipPacked,
  encodeInlineInvoke,
  encodeInvokeAfterMsg,
  encodeMessageContainer,
  encodeMsgCopy,
  encodePing,
  encodeRpcDropAnswer,
  encodeRpcResult,
  encodeBindTempAuthKey,
  encodeUnencryptedRecord,
  encryptRecord,
  makeRsaPublicKey,
  serviceConstructor,
  type EstablishedAuthorizationKey,
  type InlineProtocolServerApplicationCompletion,
  type LoadedServerAuthorizationKey,
  type ServerAuthorizationKeyRepository,
  type ServerReplayClaim,
  type ServerReplayRepository,
} from "../src/secure/index.js"

const nowMilliseconds = 1_700_000_000_000
const paddingFor = (bodyLength: number) => 12 + ((16 - ((32 + bodyLength + 12) % 16)) % 16)

const deferred = <T = void>() => {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>((continuation) => { resolve = continuation })
  return { promise, resolve }
}

class MemoryAuthorizationKeys implements ServerAuthorizationKeyRepository {
  readonly values = new Map<string, LoadedServerAuthorizationKey>()

  async create(key: EstablishedAuthorizationKey): Promise<"created" | "collision"> {
    const id = bytesToHex(key.keyId)
    if (this.values.has(id)) return "collision"
    this.values.set(id, {
      key: key.key.slice(),
      keyId: key.keyId.slice(),
      temporary: key.temporary,
      expiresAt: key.expiresAt,
      currentServerSalt: key.serverSalt,
    })
    return "created"
  }

  async load(authKeyId: Uint8Array): Promise<LoadedServerAuthorizationKey | undefined> {
    return this.values.get(bytesToHex(authKeyId))
  }

  async bindTemporary(input: {
    temporaryAuthKeyId: Uint8Array
    permanentAuthKeyId: Uint8Array
    temporarySessionId: bigint
    nonce: bigint
    expiresAt: number
    userId: number
    accountSessionId: number
  }): Promise<"created"> {
    const key = this.values.get(bytesToHex(input.temporaryAuthKeyId))
    if (!key) throw new Error("Temporary key not found")
    key.binding = {
      permanentAuthKeyId: input.permanentAuthKeyId.slice(),
      temporarySessionId: input.temporarySessionId,
      nonce: input.nonce,
      expiresAt: input.expiresAt,
      userId: input.userId,
      accountSessionId: input.accountSessionId,
    }
    return "created"
  }

  async rotateServerSalt(authKeyId: Uint8Array, newServerSalt: bigint): Promise<boolean> {
    const key = this.values.get(bytesToHex(authKeyId))
    if (!key) return false
    key.previousServerSalt = key.currentServerSalt
    key.currentServerSalt = newServerSalt
    return true
  }

  async revoke(authKeyId: Uint8Array): Promise<boolean> {
    return this.values.delete(bytesToHex(authKeyId))
  }
}

class MemoryReplay implements ServerReplayRepository {
  readonly values = new Map<string, { body: Uint8Array; result?: Uint8Array }>()

  async claim(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    authenticatedBody: Uint8Array
  }): Promise<ServerReplayClaim> {
    const id = `${bytesToHex(input.authKeyId)}:${input.sessionId}:${input.messageId}`
    const existing = this.values.get(id)
    if (!existing) {
      this.values.set(id, { body: input.authenticatedBody.slice() })
      return { kind: "claimed" }
    }
    if (bytesToHex(existing.body) !== bytesToHex(input.authenticatedBody)) return { kind: "digest_mismatch" }
    return existing.result ? { kind: "completed", resultBody: existing.result.slice() } : { kind: "in_flight" }
  }

  async complete(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    resultBody: Uint8Array
  }): Promise<{ kind: "completed" } | { kind: "superseded"; resultBody: Uint8Array }> {
    const id = `${bytesToHex(input.authKeyId)}:${input.sessionId}:${input.messageId}`
    const value = this.values.get(id)!
    if (value.result) return { kind: "superseded", resultBody: value.result.slice() }
    value.result = input.resultBody.slice()
    return { kind: "completed" }
  }

  async dropAnswer(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    runningResultBody: Uint8Array
  }): Promise<"running" | "unknown"> {
    const id = `${bytesToHex(input.authKeyId)}:${input.sessionId}:${input.messageId}`
    const value = this.values.get(id)
    if (!value || value.result) return "unknown"
    return "running"
  }

  async forgetAnswer(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    forgottenResultBody: Uint8Array
  }): Promise<void> {
    const id = `${bytesToHex(input.authKeyId)}:${input.sessionId}:${input.messageId}`
    const value = this.values.get(id)
    if (!value?.result) throw new Error("Completed answer not found")
    value.result = input.forgottenResultBody.slice()
  }
}

const rsaFixture = () => {
  const pair = generateKeyPairSync("rsa", { modulusLength: 2048, publicExponent: 65537 })
  const jwk = pair.publicKey.export({ format: "jwk" })
  const profile = makeRsaPublicKey(
    Uint8Array.from(Buffer.from(jwk.n!, "base64url")),
    Uint8Array.from(Buffer.from(jwk.e!, "base64url")),
  )
  return {
    profile,
    server: {
      ...profile,
      rawDecrypt: (ciphertext: Uint8Array) => Uint8Array.from(privateDecrypt({
        key: pair.privateKey,
        padding: constants.RSA_NO_PADDING,
      }, ciphertext)),
    },
  }
}

describe("carrier-independent Inline Protocol server session", () => {
  test("classifies an authorization key forgotten across server restart as invalidated", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const body = encodePing(123n)
    const packet = encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId: 456n,
      messageId: new MessageIdGenerator().next(nowMilliseconds, 1, 0),
      sequenceNumber: 0,
      body,
    }, randomBytes(paddingFor(body.length)))
    const server = new InlineProtocolServerSession({
      rsaKeys: [rsa.server],
      authorizationKeys,
      replay: new MemoryReplay(),
      application: {
        dispatch: async () => ({ kind: "result", payload: new Uint8Array() }),
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })

    expect(authorizationKeys.values.has(bytesToHex(keyId))).toBeFalse()
    await expect(server.receive(packet)).rejects.toThrow("Authorization key is no longer active")
  })

  test("delivers a terminal result before closing an explicitly revoked authorization", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const sessionId = 0x1122_3344n
    authorizationKeys.values.set(bytesToHex(keyId), {
      key,
      keyId,
      temporary: true,
      expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
      currentServerSalt: serverSalt,
      binding: {
        permanentAuthKeyId: Uint8Array.from(randomBytes(8)),
        temporarySessionId: sessionId,
        nonce: 1n,
        expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
        userId: 42,
        accountSessionId: 84,
      },
    })
    const server = new InlineProtocolServerSession({
      rsaKeys: [rsa.server],
      authorizationKeys,
      replay: new MemoryReplay(),
      application: {
        dispatch: async () => {
          authorizationKeys.values.delete(bytesToHex(keyId))
          return {
            kind: "result",
            payload: Uint8Array.of(7),
            terminateAuthorization: true,
          }
        },
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    const messageId = new MessageIdGenerator().next(nowMilliseconds, 1, 0)
    const body = encodeInlineInvoke(Uint8Array.of(1))

    const outputs = await server.receive(encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId,
      sequenceNumber: 1,
      body,
    }, randomBytes(paddingFor(body.length))))
    const result = outputs
      .map((output) => decryptRecord(output, key, {
        direction: "server-to-client",
        sessionId,
        validServerSalts: new Set([serverSalt]),
        nowSeconds: nowMilliseconds / 1_000,
      }).body)
      .find((output) => serviceConstructor(output) === ServiceConstructor.rpcResult)

    expect(result).toBeDefined()
    expect(decodeInlineApplicationObject(decodeRpcResult(result!).result)).toEqual({
      kind: "result",
      payload: Uint8Array.of(7),
    })
    expect(server.destroyed).toBeTrue()
    await expect(server.receive(encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId: new MessageIdGenerator().next(nowMilliseconds, 2, 0),
      sequenceNumber: 3,
      body,
    }, randomBytes(paddingFor(body.length))))).rejects.toThrow()
  })

  test("handshakes, dispatches once, caches a byte-identical result, and survives restart", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const replay = new MemoryReplay()
    let dispatches = 0
    const dispatchedPayloads: number[][] = []
    const makeServer = () => new InlineProtocolServerSession({
      rsaKeys: [rsa.server],
      authorizationKeys,
      replay,
      application: {
        dispatch: async ({ payload }) => {
          dispatches += 1
          dispatchedPayloads.push([...payload])
          return { kind: "result", payload: Uint8Array.of(9, ...payload) }
        },
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    let server = makeServer()
    const client = new InlineHandshakeClient({
      rsaKeys: [rsa.profile],
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
    })
    const clientIds = new MessageIdGenerator()
    let request = client.begin(false)
    let established: EstablishedAuthorizationKey | undefined
    for (let step = 0; step < 3; step += 1) {
      const requestRecord = encodeUnencryptedRecord(
        clientIds.next(nowMilliseconds, step + 1, 0),
        request,
      )
      const [responseRecord] = await server.receive(requestRecord)
      const response = client.receive(decodeUnencryptedRecord(responseRecord!).body)
      if ("request" in response) request = response.request
      else established = response.established
    }
    expect(established).toBeDefined()

    const sessionId = 123456n
    const messageId = clientIds.next(nowMilliseconds, 99, 0)
    const applicationBody = encodeInlineInvoke(Uint8Array.of(1, 2, 3))
    const encrypted = encryptRecord(established!.key, "client-to-server", {
      serverSalt: established!.serverSalt,
      sessionId,
      messageId,
      sequenceNumber: 1,
      body: applicationBody,
    }, randomBytes(paddingFor(applicationBody.length)))

    const invalidQuickAcks: number[] = []
    const tampered = encrypted.slice()
    tampered[tampered.length - 1] ^= 1
    await expect(server.receive(tampered, {
      onQuickAck: (quickAckId) => invalidQuickAcks.push(quickAckId),
    })).rejects.toThrow()
    expect(invalidQuickAcks).toEqual([])

    const expectedQuickAck = decryptRecordWithMetadata(encrypted, established!.key, {
      direction: "client-to-server",
      sessionId,
      validServerSalts: new Set([established!.serverSalt]),
      nowSeconds: nowMilliseconds / 1_000,
    }).quickAckId
    const quickAcks: number[] = []
    const firstOutputs = await server.receive(encrypted, {
      onQuickAck: (quickAckId) => quickAcks.push(quickAckId),
    })
    expect(quickAcks).toEqual([expectedQuickAck])
    const firstBodies = firstOutputs.map((output) => decryptRecord(output, established!.key, {
      direction: "server-to-client",
      sessionId,
      validServerSalts: new Set([established!.serverSalt]),
      nowSeconds: nowMilliseconds / 1000,
    }).body)
    const firstResult = firstBodies.find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
    expect(firstBodies.some((body) => serviceConstructor(body) === ServiceConstructor.newSessionCreated)).toBeTrue()
    expect(firstResult).toBeDefined()
    const decoded = decodeRpcResult(firstResult!)
    expect(decoded.requestMessageId).toBe(messageId)
    expect(decodeInlineApplicationObject(decoded.result)).toEqual({
      kind: "result",
      payload: Uint8Array.of(9, 1, 2, 3),
    })
    expect(dispatches).toBe(1)

    const dependentBody = encodeInvokeAfterMsg(messageId, encodeInlineInvoke(Uint8Array.of(4)))
    await server.receive(encryptRecord(established!.key, "client-to-server", {
      serverSalt: established!.serverSalt,
      sessionId,
      messageId: clientIds.next(nowMilliseconds, 100, 0),
      sequenceNumber: 3,
      body: dependentBody,
    }, randomBytes(paddingFor(dependentBody.length))))
    expect(dispatches).toBe(2)

    const deferredMessageId = clientIds.next(nowMilliseconds, 101, 0)
    const dependencyMessageId = clientIds.next(nowMilliseconds, 102, 0)
    const deferredBody = encodeInvokeAfterMsg(dependencyMessageId, encodeInlineInvoke(Uint8Array.of(5)))
    const dependencyBody = encodeInlineInvoke(Uint8Array.of(6))
    const containerBody = encodeMessageContainer([
      { messageId: deferredMessageId, sequenceNumber: 5, body: deferredBody },
      { messageId: dependencyMessageId, sequenceNumber: 7, body: dependencyBody },
    ])
    const containerOutputs = await server.receive(encryptRecord(established!.key, "client-to-server", {
      serverSalt: established!.serverSalt,
      sessionId,
      messageId: clientIds.next(nowMilliseconds, 103, 0),
      sequenceNumber: 8,
      body: containerBody,
    }, randomBytes(paddingFor(containerBody.length))))
    expect(containerOutputs.length).toBeGreaterThan(0)
    expect(dispatches).toBe(4)
    expect(dispatchedPayloads.slice(-2)).toEqual([[6], [5]])

    const retryablePingId = clientIds.next(nowMilliseconds, 104, 0)
    const invalidChildId = clientIds.next(nowMilliseconds, 105, 0)
    const pingBody = encodePing(777n)
    const invalidContainer = encodeMessageContainer([
      { messageId: retryablePingId, sequenceNumber: 8, body: pingBody },
      { messageId: invalidChildId, sequenceNumber: 8, body: encodeInlineInvoke(Uint8Array.of(7)) },
    ])
    await server.receive(encryptRecord(established!.key, "client-to-server", {
      serverSalt: established!.serverSalt,
      sessionId,
      messageId: clientIds.next(nowMilliseconds, 106, 0),
      sequenceNumber: 10,
      body: invalidContainer,
    }, randomBytes(paddingFor(invalidContainer.length))))
    const retriedPing = await server.receive(encryptRecord(established!.key, "client-to-server", {
      serverSalt: established!.serverSalt,
      sessionId,
      messageId: retryablePingId,
      sequenceNumber: 8,
      body: pingBody,
    }, randomBytes(paddingFor(pingBody.length))))
    expect(retriedPing.some((output) => serviceConstructor(decryptRecord(output, established!.key, {
      direction: "server-to-client", sessionId,
      validServerSalts: new Set([established!.serverSalt]),
      nowSeconds: nowMilliseconds / 1000,
    }).body) === ServiceConstructor.pong)).toBeTrue()

    const runningRequestId = clientIds.next(nowMilliseconds, 107, 0)
    await replay.claim({
      authKeyId: established!.keyId,
      sessionId,
      messageId: runningRequestId,
      authenticatedBody: encodeInlineInvoke(Uint8Array.of(8)),
    })
    const dropBody = encodeRpcDropAnswer(runningRequestId)
    const dropMessageId = clientIds.next(nowMilliseconds, 108, 0)
    const dropOutputs = await server.receive(encryptRecord(established!.key, "client-to-server", {
      serverSalt: established!.serverSalt,
      sessionId,
      messageId: dropMessageId,
      sequenceNumber: 9,
      body: dropBody,
    }, randomBytes(paddingFor(dropBody.length))))
    const dropResultBody = dropOutputs.map((output) => decryptRecord(output, established!.key, {
      direction: "server-to-client", sessionId,
      validServerSalts: new Set([established!.serverSalt]),
      nowSeconds: nowMilliseconds / 1000,
    }).body).find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
    expect(dropResultBody).toBeDefined()
    expect(decodeRpcDropAnswerResult(decodeRpcResult(dropResultBody!).result)).toEqual({ kind: "running" })
    const completedAfterDrop = await replay.complete({
      authKeyId: established!.keyId,
      sessionId,
      messageId: runningRequestId,
      resultBody: encodeRpcResult(runningRequestId, encodeInlineInvoke(Uint8Array.of(9))),
    })
    expect(completedAfterDrop.kind).toBe("completed")

    const queuedDropBody = encodeRpcDropAnswer(messageId)
    const queuedDropOutputs = await server.receive(encryptRecord(established!.key, "client-to-server", {
      serverSalt: established!.serverSalt,
      sessionId,
      messageId: clientIds.next(nowMilliseconds, 109, 0),
      sequenceNumber: 11,
      body: queuedDropBody,
    }, randomBytes(paddingFor(queuedDropBody.length))))
    const queuedDropResult = queuedDropOutputs.map((output) => decryptRecord(output, established!.key, {
      direction: "server-to-client", sessionId,
      validServerSalts: new Set([established!.serverSalt]),
      nowSeconds: nowMilliseconds / 1000,
    }).body).find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
    expect(queuedDropResult).toBeDefined()
    expect(decodeRpcDropAnswerResult(decodeRpcResult(queuedDropResult!).result).kind).toBe("dropped")

    const replayedOutputs = await server.receive(encrypted)
    const replayedResult = replayedOutputs.map((output) => {
      const body = decryptRecord(output, established!.key, {
        direction: "server-to-client", sessionId,
        validServerSalts: new Set([established!.serverSalt]),
        nowSeconds: nowMilliseconds / 1000,
      }).body
      return serviceConstructor(body) === ServiceConstructor.rpcResult ? body : undefined
    }).find((body) => body !== undefined)
    expect(replayedResult).toBeDefined()
    expect(decodeRpcDropAnswerResult(decodeRpcResult(replayedResult!).result)).toEqual({ kind: "unknown" })
    expect(dispatches).toBe(4)

    server = makeServer()
    const restartedOutputs = await server.receive(encrypted)
    expect(restartedOutputs.length).toBeGreaterThan(0)
    expect(dispatches).toBe(4)
  }, 20_000)

  test("accepts independent application RPCs before results and finalizes them by request identity", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const replay = new MemoryReplay()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const sessionId = 0x1122_3344n
    authorizationKeys.values.set(bytesToHex(keyId), {
      key,
      keyId,
      temporary: true,
      expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
      currentServerSalt: serverSalt,
      binding: {
        permanentAuthKeyId: Uint8Array.from(randomBytes(8)),
        temporarySessionId: sessionId,
        nonce: 1n,
        expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
        userId: 42,
        accountSessionId: 84,
      },
    })

    const firstGate = deferred()
    const secondGate = deferred()
    const started: number[] = []
    const server = new InlineProtocolServerSession({
      rsaKeys: [rsa.server], authorizationKeys, replay,
      application: {
        dispatch: async ({ payload, sendUpdate }) => {
          const value = payload[0]!
          started.push(value)
          if (value === 1) {
            sendUpdate(Uint8Array.of(101))
            await firstGate.promise
          } else if (value === 2) {
            await secondGate.promise
          }
          return { kind: "result", payload: Uint8Array.of(value + 10) }
        },
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    const ids = new MessageIdGenerator()
    const firstMessageId = ids.next(nowMilliseconds, 1, 0)
    const dependentMessageId = ids.next(nowMilliseconds, 2, 0)
    const secondMessageId = ids.next(nowMilliseconds, 3, 0)
    const copiedMessageId = ids.next(nowMilliseconds, 4, 0)
    const copyOuterMessageId = ids.next(nowMilliseconds, 5, 0)
    const copyDependentMessageId = ids.next(nowMilliseconds, 6, 0)
    const gzipPingMessageId = ids.next(nowMilliseconds, 7, 0)
    const makeInvoke = (messageId: bigint, sequenceNumber: number, payload: Uint8Array): Uint8Array => {
      const body = encodeInlineInvoke(payload)
      return encryptRecord(key, "client-to-server", {
        serverSalt, sessionId, messageId, sequenceNumber, body,
      }, randomBytes(paddingFor(body.length)))
    }
    const decryptBodies = (records: readonly Uint8Array[]): Uint8Array[] => records.map((record) =>
      decryptRecord(record, key, {
        direction: "server-to-client",
        sessionId,
        validServerSalts: new Set([serverSalt]),
        nowSeconds: nowMilliseconds / 1_000,
      }).body)

    const acceptedFirst = await server.receiveConcurrent(
      makeInvoke(firstMessageId, 1, Uint8Array.of(1)),
    )
    expect(acceptedFirst.applicationTasks).toHaveLength(1)
    const firstAck = decryptBodies(acceptedFirst.responses)
      .find((body) => serviceConstructor(body) === ServiceConstructor.msgsAck)
    expect(firstAck).toBeDefined()
    expect(decodeMsgsAck(firstAck!)).toContain(firstMessageId)
    const firstDispatch = acceptedFirst.applicationTasks[0]!.dispatch()

    const dependentBody = encodeInvokeAfterMsg(firstMessageId, encodeInlineInvoke(Uint8Array.of(3)))
    const acceptedDependent = await server.receiveConcurrent(encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId: dependentMessageId,
      sequenceNumber: 3,
      body: dependentBody,
    }, randomBytes(paddingFor(dependentBody.length))))
    expect(acceptedDependent.applicationTasks).toHaveLength(0)

    const acceptedDuplicate = await server.receiveConcurrent(
      makeInvoke(firstMessageId, 1, Uint8Array.of(1)),
    )
    expect(acceptedDuplicate.applicationTasks).toHaveLength(0)
    expect(started).toEqual([1])

    const acceptedSecond = await server.receiveConcurrent(
      makeInvoke(secondMessageId, 5, Uint8Array.of(2)),
    )
    expect(acceptedSecond.applicationTasks).toHaveLength(1)
    const secondDispatch = acceptedSecond.applicationTasks[0]!.dispatch()
    expect(started).toEqual([1, 2])

    secondGate.resolve(undefined)
    const finalizedSecond = await (await secondDispatch).finalize()
    expect(finalizedSecond.applicationTasks).toHaveLength(0)
    const secondResult = decryptBodies(finalizedSecond.responses)
      .find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
    expect(secondResult).toBeDefined()
    expect(decodeRpcResult(secondResult!).requestMessageId).toBe(secondMessageId)

    firstGate.resolve(undefined)
    const finalizedFirst = await (await firstDispatch).finalize()
    expect(finalizedFirst.applicationTasks).toHaveLength(1)
    const firstBodies = decryptBodies(finalizedFirst.responses)
    expect(serviceConstructor(firstBodies[0]!)).toBe(ServiceConstructor.rpcResult)
    expect(decodeRpcResult(firstBodies[0]!).requestMessageId).toBe(firstMessageId)
    expect(decodeInlineApplicationObject(firstBodies[1]!)).toEqual({
      kind: "update",
      payload: Uint8Array.of(101),
    })

    const dependentCompletion = await finalizedFirst.applicationTasks[0]!.dispatch()
    expect(started).toEqual([1, 2, 3])
    const finalizedDependent = await dependentCompletion.finalize()
    const dependentResult = decryptBodies(finalizedDependent.responses)
      .find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
    expect(dependentResult).toBeDefined()
    expect(decodeRpcResult(dependentResult!).requestMessageId).toBe(dependentMessageId)

    const copiedBody = encodeMsgCopy({
      messageId: copiedMessageId,
      sequenceNumber: 7,
      body: encodeInlineInvoke(Uint8Array.of(4)),
    })
    const acceptedCopy = await server.receiveConcurrent(encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId: copyOuterMessageId,
      sequenceNumber: 7,
      body: copiedBody,
    }, randomBytes(paddingFor(copiedBody.length))))
    expect(acceptedCopy.applicationTasks).toHaveLength(1)
    expect(acceptedCopy.applicationTasks[0]!.messageId).toBe(copiedMessageId)
    const copiedDispatch = acceptedCopy.applicationTasks[0]!.dispatch()

    const copyDependentBody = encodeInvokeAfterMsg(
      copyOuterMessageId,
      encodeInlineInvoke(Uint8Array.of(5)),
    )
    const acceptedCopyDependent = await server.receiveConcurrent(encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId: copyDependentMessageId,
      sequenceNumber: 9,
      body: copyDependentBody,
    }, randomBytes(paddingFor(copyDependentBody.length))))
    expect(acceptedCopyDependent.applicationTasks).toHaveLength(0)

    const finalizedCopy = await (await copiedDispatch).finalize()
    expect(finalizedCopy.applicationTasks).toHaveLength(1)
    expect(decodeRpcResult(decryptBodies(finalizedCopy.responses).find(
      (body) => serviceConstructor(body) === ServiceConstructor.rpcResult,
    )!).requestMessageId).toBe(copiedMessageId)
    const copyDependentCompletion = await finalizedCopy.applicationTasks[0]!.dispatch()
    const finalizedCopyDependent = await copyDependentCompletion.finalize()
    expect(decodeRpcResult(decryptBodies(finalizedCopyDependent.responses).find(
      (body) => serviceConstructor(body) === ServiceConstructor.rpcResult,
    )!).requestMessageId).toBe(copyDependentMessageId)

    const gzipPingBody = encodeGzipPacked(gzipSync(encodePing(123n)))
    const gzipPing = await server.receiveConcurrent(encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId: gzipPingMessageId,
      sequenceNumber: 11,
      body: gzipPingBody,
    }, randomBytes(paddingFor(gzipPingBody.length))))
    expect(decryptBodies(gzipPing.responses).some(
      (body) => serviceConstructor(body) === ServiceConstructor.pong,
    )).toBeTrue()
  })

  test("deadline reports commit-unknown but retains replay, ordering, and execution ownership", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const replay = new MemoryReplay()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const sessionId = 0x5566_7788n
    const permanentAuthKeyId = Uint8Array.from(randomBytes(8))
    authorizationKeys.values.set(bytesToHex(keyId), {
      key,
      keyId,
      temporary: true,
      expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
      currentServerSalt: serverSalt,
      binding: {
        permanentAuthKeyId,
        temporarySessionId: sessionId,
        nonce: 1n,
        expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
        userId: 42,
        accountSessionId: 84,
      },
    })

    const release = deferred()
    const committedAfterDeadline = deferred()
    let deadlineSignal: AbortSignal | undefined
    let activeApplications = 0
    let bufferedUpdateBytes = 0
    const server = new InlineProtocolServerSession({
      rsaKeys: [rsa.server],
      authorizationKeys,
      replay,
      applicationTimeoutMs: 10,
      application: {
        dispatch: async ({ payload, signal, markExecutionStarted, sendUpdate }) => {
          markExecutionStarted()
          if (payload[0] === 1) {
            deadlineSignal = signal
            await release.promise
            sendUpdate(Uint8Array.of(99))
            committedAfterDeadline.resolve(undefined)
          }
          if (payload[0] === 4) {
            sendUpdate(Uint8Array.of(100))
            sendUpdate(Uint8Array.of(101))
          }
          return { kind: "result", payload: Uint8Array.of(payload[0] ?? 0) }
        },
      },
      tryAcquireApplication: () => {
        activeApplications += 1
        let released = false
        return () => {
          if (released) return
          released = true
          activeApplications -= 1
        }
      },
      tryReserveApplicationUpdateBytes: (bytes) => {
        if (bufferedUpdateBytes + bytes > 1) return undefined
        bufferedUpdateBytes += bytes
        return () => { bufferedUpdateBytes -= bytes }
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    const ids = new MessageIdGenerator()
    const makeInvoke = (messageId: bigint, sequenceNumber: number, value: number) => {
      const body = encodeInlineInvoke(Uint8Array.of(value))
      return encryptRecord(key, "client-to-server", {
        serverSalt,
        sessionId,
        messageId,
        sequenceNumber,
        body,
      }, randomBytes(paddingFor(body.length)))
    }
    const decryptBodies = (records: readonly Uint8Array[]) => records.map((record) =>
      decryptRecord(record, key, {
        direction: "server-to-client",
        sessionId,
        validServerSalts: new Set([serverSalt]),
        nowSeconds: nowMilliseconds / 1_000,
      }).body)

    const firstMessageId = ids.next(nowMilliseconds, 1, 0)
    const firstRecord = makeInvoke(firstMessageId, 1, 1)
    const first = await server.receiveConcurrent(firstRecord)
    const firstCompletion = await first.applicationTasks[0]!.dispatch()
    expect(activeApplications).toBe(1)
    expect(deadlineSignal?.aborted).toBeTrue()
    const timedOut = await firstCompletion.finalize()
    expect(activeApplications).toBe(1)
    const timedOutResult = decryptBodies(timedOut.responses).find(
      (body) => serviceConstructor(body) === ServiceConstructor.rpcResult,
    )
    expect(timedOutResult).toBeDefined()
    expect(serviceConstructor(decodeRpcResult(timedOutResult!).result)).toBe(ServiceConstructor.rpcError)

    const stillRunning = await server.receiveConcurrent(firstRecord)
    expect(stillRunning.applicationTasks).toHaveLength(0)
    expect(decryptBodies(stillRunning.responses).some(
      (body) => serviceConstructor(body) === ServiceConstructor.msgsStateInfo,
    )).toBeTrue()

    const dependentMessageId = ids.next(nowMilliseconds, 2, 0)
    const dependentBody = encodeInvokeAfterMsg(firstMessageId, encodeInlineInvoke(Uint8Array.of(3)))
    const dependent = await server.receiveConcurrent(encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId: dependentMessageId,
      sequenceNumber: 3,
      body: dependentBody,
    }, randomBytes(paddingFor(dependentBody.length))))
    expect(dependent.applicationTasks).toHaveLength(0)

    const second = await server.receiveConcurrent(makeInvoke(ids.next(nowMilliseconds, 3, 0), 5, 2))
    expect(second.applicationTasks).toHaveLength(1)
    const secondResult = await (await second.applicationTasks[0]!.dispatch()).finalize()
    expect(decryptBodies(secondResult.responses).some(
      (body) => serviceConstructor(body) === ServiceConstructor.rpcResult,
    )).toBeTrue()

    release.resolve(undefined)
    await committedAfterDeadline.promise
    expect(bufferedUpdateBytes).toBe(1)
    const settlement = await firstCompletion.settlement
    expect(settlement).toBeDefined()
    const settled = await settlement!.finalize()
    expect(activeApplications).toBe(0)
    expect(bufferedUpdateBytes).toBe(0)
    const settledBodies = decryptBodies(settled.responses)
    expect(settledBodies.some((body) => {
      try {
        const object = decodeInlineApplicationObject(body)
        return object.kind === "update" && object.payload[0] === 99
      } catch {
        return false
      }
    })).toBeTrue()
    expect(settledBodies.some(
      (body) => serviceConstructor(body) === ServiceConstructor.rpcResult,
    )).toBeFalse()
    expect(settled.applicationTasks).toHaveLength(1)
    const dependentResult = await (await settled.applicationTasks[0]!.dispatch()).finalize()
    expect(decryptBodies(dependentResult.responses).some((body) => {
      if (serviceConstructor(body) !== ServiceConstructor.rpcResult) return false
      return decodeRpcResult(body).requestMessageId === dependentMessageId
    })).toBeTrue()

    const replayed = await server.receiveConcurrent(firstRecord)
    expect(replayed.applicationTasks).toHaveLength(0)
    const replayedResult = decryptBodies(replayed.responses).find(
      (body) => serviceConstructor(body) === ServiceConstructor.rpcResult,
    )
    expect(replayedResult).toBeDefined()
    expect(decodeRpcResult(replayedResult!).requestMessageId).toBe(firstMessageId)
    const replayedObject = decodeInlineApplicationObject(decodeRpcResult(replayedResult!).result)
    expect(replayedObject.kind).toBe("result")
    expect(replayedObject.kind === "result" ? replayedObject.payload[0] : undefined).toBe(1)

    const overloaded = await server.receiveConcurrent(makeInvoke(ids.next(nowMilliseconds, 4, 0), 7, 4))
    const overloadedResult = await (await overloaded.applicationTasks[0]!.dispatch()).finalize()
    const overloadedRpcResult = decryptBodies(overloadedResult.responses).find(
      (body) => serviceConstructor(body) === ServiceConstructor.rpcResult,
    )
    expect(overloadedRpcResult).toBeDefined()
    expect(decodeRpcError(decodeRpcResult(overloadedRpcResult!).result).code).toBe(504)
    expect(bufferedUpdateBytes).toBe(0)
  })

  test("deadline before application execution is a replayable rejection, not commit-unknown", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const replay = new MemoryReplay()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const sessionId = 0x5566_7799n
    authorizationKeys.values.set(bytesToHex(keyId), {
      key,
      keyId,
      temporary: true,
      expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
      currentServerSalt: serverSalt,
      binding: {
        permanentAuthKeyId: Uint8Array.from(randomBytes(8)),
        temporarySessionId: sessionId,
        nonce: 1n,
        expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
        userId: 42,
        accountSessionId: 84,
      },
    })
    let activeApplications = 0
    const server = new InlineProtocolServerSession({
      rsaKeys: [rsa.server],
      authorizationKeys,
      replay,
      applicationTimeoutMs: 10,
      application: {
        dispatch: async ({ signal }) => await new Promise((_, reject) => {
          signal.addEventListener("abort", () => reject(signal.reason), { once: true })
        }),
      },
      tryAcquireApplication: () => {
        activeApplications += 1
        return () => { activeApplications -= 1 }
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    const messageId = new MessageIdGenerator().next(nowMilliseconds, 1, 0)
    const body = encodeInlineInvoke(Uint8Array.of(7))
    const record = encryptRecord(key, "client-to-server", {
      serverSalt,
      sessionId,
      messageId,
      sequenceNumber: 1,
      body,
    }, randomBytes(paddingFor(body.length)))
    const decryptError = (response: Uint8Array) => {
      const decrypted = decryptRecord(response, key, {
        direction: "server-to-client",
        sessionId,
        validServerSalts: new Set([serverSalt]),
        nowSeconds: nowMilliseconds / 1_000,
      }).body
      if (serviceConstructor(decrypted) !== ServiceConstructor.rpcResult) return undefined
      return decodeRpcError(decodeRpcResult(decrypted).result)
    }

    const accepted = await server.receiveConcurrent(record)
    const completion = await accepted.applicationTasks[0]!.dispatch()
    expect(activeApplications).toBe(1)
    const timedOut = await completion.finalize()
    expect(timedOut.responses.map(decryptError).filter(Boolean)).toEqual([{
      code: 503,
      message: "Realtime application deadline exceeded before execution",
    }])

    const settlement = await completion.settlement
    expect(settlement).toBeDefined()
    await settlement!.finalize()
    expect(activeApplications).toBe(0)

    const replayed = await server.receiveConcurrent(record)
    expect(replayed.applicationTasks).toHaveLength(0)
    expect(replayed.responses.map(decryptError).filter(Boolean)).toEqual([{
      code: 503,
      message: "Realtime application deadline exceeded before execution",
    }])
  })

  test("rejects the sixty-fifth retained application before dispatch", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const replay = new MemoryReplay()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const sessionId = 0x5566_77aan
    authorizationKeys.values.set(bytesToHex(keyId), {
      key,
      keyId,
      temporary: true,
      expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
      currentServerSalt: serverSalt,
      binding: {
        permanentAuthKeyId: Uint8Array.from(randomBytes(8)),
        temporarySessionId: sessionId,
        nonce: 1n,
        expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
        userId: 42,
        accountSessionId: 84,
      },
    })
    let dispatchCount = 0
    const server = new InlineProtocolServerSession({
      rsaKeys: [rsa.server],
      authorizationKeys,
      replay,
      application: {
        dispatch: async ({ markExecutionStarted }) => {
          markExecutionStarted()
          dispatchCount += 1
          return { kind: "result", payload: new Uint8Array() }
        },
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    const ids = new MessageIdGenerator()
    const makeRecord = (index: number) => {
      const body = encodeInlineInvoke(Uint8Array.of(index))
      return encryptRecord(key, "client-to-server", {
        serverSalt,
        sessionId,
        messageId: ids.next(nowMilliseconds, index + 1, 0),
        sequenceNumber: index * 2 + 1,
        body,
      }, randomBytes(paddingFor(body.length)))
    }

    for (let index = 0; index < 64; index += 1) {
      expect((await server.receiveConcurrent(makeRecord(index))).applicationTasks).toHaveLength(1)
    }
    const rejected = await server.receiveConcurrent(makeRecord(64))
    expect(rejected.applicationTasks).toHaveLength(0)
    expect(dispatchCount).toBe(0)
    const error = rejected.responses.flatMap((response) => {
      const body = decryptRecord(response, key, {
        direction: "server-to-client",
        sessionId,
        validServerSalts: new Set([serverSalt]),
        nowSeconds: nowMilliseconds / 1_000,
      }).body
      return serviceConstructor(body) === ServiceConstructor.rpcResult
        ? [decodeRpcError(decodeRpcResult(body).result)]
        : []
    })
    expect(error).toEqual([{ code: 503, message: "Realtime application capacity exceeded" }])
  })

  test("keeps session capacity occupied when timed-out handlers ignore abort", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const replay = new MemoryReplay()
    const key = Uint8Array.from(randomBytes(256))
    const keyId = authKeyId(key)
    const serverSalt = 0x1020_3040_5060_7080n
    const sessionId = 0x5566_77abn
    authorizationKeys.values.set(bytesToHex(keyId), {
      key,
      keyId,
      temporary: true,
      expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
      currentServerSalt: serverSalt,
      binding: {
        permanentAuthKeyId: Uint8Array.from(randomBytes(8)),
        temporarySessionId: sessionId,
        nonce: 1n,
        expiresAt: Math.floor(nowMilliseconds / 1_000) + 600,
        userId: 42,
        accountSessionId: 84,
      },
    })
    const release = deferred()
    let activeApplications = 0
    let dispatchCount = 0
    const server = new InlineProtocolServerSession({
      rsaKeys: [rsa.server],
      authorizationKeys,
      replay,
      applicationTimeoutMs: 1,
      application: {
        dispatch: async ({ markExecutionStarted }) => {
          markExecutionStarted()
          dispatchCount += 1
          await release.promise
          return { kind: "result", payload: Uint8Array.of(1) }
        },
      },
      tryAcquireApplication: () => {
        activeApplications += 1
        let released = false
        return () => {
          if (released) return
          released = true
          activeApplications -= 1
        }
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    const ids = new MessageIdGenerator()
    const makeRecord = (index: number) => {
      const body = encodeInlineInvoke(Uint8Array.of(index))
      return encryptRecord(key, "client-to-server", {
        serverSalt,
        sessionId,
        messageId: ids.next(nowMilliseconds, index + 1, 0),
        sequenceNumber: index * 2 + 1,
        body,
      }, randomBytes(paddingFor(body.length)))
    }

    const timedOut: InlineProtocolServerApplicationCompletion[] = []
    for (let index = 0; index < 64; index += 1) {
      const accepted = await server.receiveConcurrent(makeRecord(index))
      expect(accepted.applicationTasks).toHaveLength(1)
      const completion = await accepted.applicationTasks[0]!.dispatch()
      await completion.finalize()
      timedOut.push(completion)
    }
    expect(dispatchCount).toBe(64)
    expect(activeApplications).toBe(64)

    const rejected = await server.receiveConcurrent(makeRecord(64))
    expect(rejected.applicationTasks).toHaveLength(0)
    expect(rejected.responses.length).toBeGreaterThan(0)

    release.resolve()
    await Promise.all(timedOut.map(async (completion) => {
      const settlement = await completion.settlement
      expect(settlement).toBeDefined()
      await settlement!.finalize()
    }))
    expect(activeApplications).toBe(0)
  })

  test("binds a temporary key to an authorized permanent key before application dispatch", async () => {
    const rsa = rsaFixture()
    const authorizationKeys = new MemoryAuthorizationKeys()
    const replay = new MemoryReplay()
    let observedAuthorization: unknown
    let dispatches = 0
    const makeServer = () => new InlineProtocolServerSession({
      rsaKeys: [rsa.server], authorizationKeys, replay,
      application: {
        dispatch: async ({ authorization }) => {
          dispatches += 1
          observedAuthorization = authorization
          return { kind: "result", payload: Uint8Array.of(7) }
        },
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => nowMilliseconds,
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    const handshake = async (temporary: boolean): Promise<EstablishedAuthorizationKey> => {
      const server = makeServer()
      const client = new InlineHandshakeClient({
        rsaKeys: [rsa.profile],
        randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      })
      const ids = new MessageIdGenerator()
      let request = client.begin(temporary)
      for (let step = 0; step < 3; step += 1) {
        const [responseRecord] = await server.receive(encodeUnencryptedRecord(
          ids.next(nowMilliseconds, step + 1, 0), request,
        ))
        const response = client.receive(decodeUnencryptedRecord(responseRecord!).body)
        if ("request" in response) request = response.request
        else return response.established
      }
      throw new Error("Handshake did not establish")
    }

    const permanent = await handshake(false)
    authorizationKeys.values.get(bytesToHex(permanent.keyId))!.authorized = {
      userId: 42,
      accountSessionId: 84,
    }
    const temporary = await handshake(true)
    const server = makeServer()
    const ids = new MessageIdGenerator()
    const sessionId = 24680n
    const bindMessageId = ids.next(nowMilliseconds, 20, 0)
    const nonce = 13579n
    const expiresAt = temporary.expiresAt!
    const proof = createTemporaryKeyBindingProof({
      permanentAuthKey: permanent.key,
      temporaryAuthKey: temporary.key,
      temporarySessionId: sessionId,
      messageId: bindMessageId,
      nonce,
      expiresAt,
      randomInt128: randomBytes(16),
      randomPadding: randomBytes(8),
    })
    const binding = encodeBindTempAuthKey({
      permanentAuthKeyId: new DataView(permanent.keyId.buffer, permanent.keyId.byteOffset, 8).getBigInt64(0, true),
      nonce,
      expiresAt,
      encryptedMessage: proof,
    })
    await server.receive(encryptRecord(temporary.key, "client-to-server", {
      serverSalt: temporary.serverSalt,
      sessionId,
      messageId: bindMessageId,
      sequenceNumber: 1,
      body: binding,
    }, randomBytes(paddingFor(binding.length))))

    const invoke = encodeInlineInvoke(Uint8Array.of(1, 2, 3))
    await server.receive(encryptRecord(temporary.key, "client-to-server", {
      serverSalt: temporary.serverSalt,
      sessionId,
      messageId: ids.next(nowMilliseconds, 21, 0),
      sequenceNumber: 3,
      body: invoke,
    }, randomBytes(paddingFor(invoke.length))))
    expect(observedAuthorization).toEqual({
      authKeyId: temporary.keyId,
      permanentAuthKeyId: permanent.keyId,
      permanent: false,
      temporaryBound: true,
      userId: 42,
      accountSessionId: 84,
    })
    expect(dispatches).toBe(1)

    authorizationKeys.values.delete(bytesToHex(temporary.keyId))
    await expect(server.receive(encryptRecord(temporary.key, "client-to-server", {
      serverSalt: temporary.serverSalt,
      sessionId,
      messageId: ids.next(nowMilliseconds, 22, 0),
      sequenceNumber: 5,
      body: invoke,
    }, randomBytes(paddingFor(invoke.length))))).rejects.toThrow("Authorization key is no longer active")
    expect(dispatches).toBe(1)
    expect(server.destroyed).toBeTrue()
    expect(() => server.sendApplicationUpdate(Uint8Array.of(1))).toThrow()
  }, 30_000)
})
