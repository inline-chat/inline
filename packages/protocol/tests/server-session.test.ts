import { describe, expect, test } from "bun:test"
import { constants, generateKeyPairSync, privateDecrypt, randomBytes } from "node:crypto"
import { gunzipSync } from "node:zlib"
import {
  InlineHandshakeClient,
  InlineProtocolServerSession,
  MessageIdGenerator,
  ServiceConstructor,
  bytesToHex,
  createTemporaryKeyBindingProof,
  decodeInlineApplicationObject,
  decodeRpcResult,
  decodeRpcDropAnswerResult,
  decodeUnencryptedRecord,
  decryptRecord,
  decryptRecordWithMetadata,
  encodeInlineInvoke,
  encodeInvokeAfterMsg,
  encodeMessageContainer,
  encodePing,
  encodeRpcDropAnswer,
  encodeRpcResult,
  encodeBindTempAuthKey,
  encodeUnencryptedRecord,
  encryptRecord,
  makeRsaPublicKey,
  serviceConstructor,
  type EstablishedAuthorizationKey,
  type LoadedServerAuthorizationKey,
  type ServerAuthorizationKeyRepository,
  type ServerReplayClaim,
  type ServerReplayRepository,
} from "../src/secure/index.js"

const nowMilliseconds = 1_700_000_000_000
const paddingFor = (bodyLength: number) => 12 + ((16 - ((32 + bodyLength + 12) % 16)) % 16)

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
    value.result = input.runningResultBody.slice()
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
    const superseded = await replay.complete({
      authKeyId: established!.keyId,
      sessionId,
      messageId: runningRequestId,
      resultBody: encodeRpcResult(runningRequestId, encodeInlineInvoke(Uint8Array.of(9))),
    })
    expect(superseded.kind).toBe("superseded")
    if (superseded.kind === "superseded") {
      expect(decodeRpcDropAnswerResult(decodeRpcResult(superseded.resultBody).result)).toEqual({ kind: "running" })
    }

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
