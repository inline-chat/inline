import { afterEach, describe, expect, it } from "vitest"
import { constants, generateKeyPairSync, privateDecrypt, randomBytes } from "node:crypto"
import { WebSocketServer } from "ws"
import {
  InlineProtocolServerSession,
  acceptObfuscatedClientHeader,
  bytesToHex,
  decodeAbridgedFrame,
  encodeAbridgedPacket,
  makeRsaPublicKey,
  type EstablishedAuthorizationKey,
  type LoadedServerAuthorizationKey,
  type ObfuscatedServerHeader,
  type ServerAuthorizationKeyRepository,
} from "@inline-chat/protocol/secure"
import {
  AuthBeginResult_Delivery,
  Method,
  RealtimeV3Request,
  RealtimeV3Response,
} from "@inline-chat/protocol/core"
import { InlineProtocolV3Connection, type InlineProtocolPublicKey } from "./v3-connection.js"

class MemoryAuthorizationKeys implements ServerAuthorizationKeyRepository {
  readonly values = new Map<string, LoadedServerAuthorizationKey>()

  async create(key: EstablishedAuthorizationKey): Promise<"created"> {
    this.values.set(bytesToHex(key.keyId), {
      key: key.key.slice(),
      keyId: key.keyId.slice(),
      temporary: key.temporary,
      expiresAt: key.expiresAt,
      currentServerSalt: key.serverSalt,
    })
    return "created"
  }

  async load(keyId: Uint8Array): Promise<LoadedServerAuthorizationKey | undefined> {
    const value = this.values.get(bytesToHex(keyId))
    return value && {
      ...value,
      key: value.key.slice(),
      keyId: value.keyId.slice(),
      binding: value.binding && { ...value.binding, permanentAuthKeyId: value.binding.permanentAuthKeyId.slice() },
      authorized: value.authorized && { ...value.authorized },
    }
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
    const value = this.values.get(bytesToHex(input.temporaryAuthKeyId))!
    value.binding = {
      permanentAuthKeyId: input.permanentAuthKeyId.slice(),
      temporarySessionId: input.temporarySessionId,
      nonce: input.nonce,
      expiresAt: input.expiresAt,
      userId: input.userId,
      accountSessionId: input.accountSessionId,
    }
    return "created"
  }

  async rotateServerSalt(keyId: Uint8Array, serverSalt: bigint): Promise<boolean> {
    const value = this.values.get(bytesToHex(keyId))
    if (!value) return false
    value.previousServerSalt = value.currentServerSalt
    value.currentServerSalt = serverSalt
    return true
  }

  async revoke(): Promise<boolean> { return true }

  authorize(keyId: Uint8Array): void {
    this.values.get(bytesToHex(keyId))!.authorized = { userId: 7, accountSessionId: 11 }
  }
}

const servers: WebSocketServer[] = []

afterEach(async () => {
  for (const server of servers.splice(0)) {
    for (const client of server.clients) client.terminate()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
})

const testServer = async (): Promise<{
  url: string
  publicKeys: InlineProtocolPublicKey[]
}> => {
  const pair = generateKeyPairSync("rsa", { modulusLength: 2048, publicExponent: 65537 })
  const jwk = pair.publicKey.export({ format: "jwk" })
  const profile = makeRsaPublicKey(
    Uint8Array.from(Buffer.from(jwk.n!, "base64url")),
    Uint8Array.from(Buffer.from(jwk.e!, "base64url")),
  )
  const keys = new MemoryAuthorizationKeys()
  const server = new WebSocketServer({ port: 0 })
  servers.push(server)
  server.on("connection", (socket) => {
    let carrier: ObfuscatedServerHeader | undefined
    let queue = Promise.resolve()
    const session = new InlineProtocolServerSession({
      rsaKeys: [{
        ...profile,
        rawDecrypt: (ciphertext) => Uint8Array.from(privateDecrypt({
          key: pair.privateKey,
          padding: constants.RSA_NO_PADDING,
        }, ciphertext)),
      }],
      authorizationKeys: keys,
      replay: {
        claim: async () => ({ kind: "claimed" }),
        complete: async ({ resultBody }) => ({ kind: "completed", resultBody }),
        dropAnswer: async () => "unknown",
        forgetAnswer: async () => {},
      },
      application: {
        dispatch: async ({ payload, authorization }) => {
          const application = RealtimeV3Request.fromBinary(payload)
          if (application.body.oneofKind === "authBegin") {
            return { kind: "result", payload: RealtimeV3Response.toBinary({
              body: { oneofKind: "authBegin", authBegin: {
                challengeId: new Uint8Array(32).fill(7),
                delivery: AuthBeginResult_Delivery.EMAIL,
                expiresAt: 1_700_000_600n,
                retryAfterSeconds: 60,
              } },
            }) }
          }
          if (application.body.oneofKind === "authComplete") {
            keys.authorize(authorization.authKeyId)
            return { kind: "result", payload: RealtimeV3Response.toBinary({
              body: { oneofKind: "authComplete", authComplete: {
                state: { oneofKind: "authorized", authorized: { accountSessionId: 11n } },
              } },
            }) }
          }
          if (application.body.oneofKind === "rpc") {
            return { kind: "result", payload: RealtimeV3Response.toBinary({
              body: { oneofKind: "rpcResult", rpcResult: {
                reqMsgId: 0n,
                result: { oneofKind: undefined },
              } },
            }) }
          }
          return { kind: "error", code: 400, message: "unexpected request" }
        },
      },
      randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      nowMilliseconds: () => Date.now(),
      gunzip: () => { throw new Error("not used") },
      carrierProfile: "websocket",
      dc: 1,
    })
    socket.on("message", (data) => {
      queue = queue.then(async () => {
        const frame = new Uint8Array(data as Buffer)
        if (!carrier) {
          carrier = acceptObfuscatedClientHeader(frame, 1)
          return
        }
        const decoded = decodeAbridgedFrame(carrier.inbound.process(frame))
        if (decoded.kind !== "packet") throw new Error("unexpected quick ACK")
        const responses = await session.receive(decoded.payload)
        for (const response of responses) socket.send(carrier.outbound.process(encodeAbridgedPacket(response)))
      })
    })
  })
  await new Promise<void>((resolve) => server.once("listening", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("test server did not bind TCP")
  return {
    url: `ws://127.0.0.1:${address.port}`,
    publicKeys: [{
      modulus: Buffer.from(profile.modulus).toString("base64url"),
      exponent: Buffer.from(profile.exponent).toString("base64url"),
      fingerprint: profile.fingerprint.toString(),
    }],
  }
}

describe("InlineProtocolV3Connection", () => {
  it("logs in with a permanent key, binds a temporary key, and invokes an RPC", async () => {
    const fixture = await testServer()
    const permanent = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
    })
    const challenge = await permanent.authBegin({
      identifier: { oneofKind: "email", email: "v3@example.com" },
    })
    expect(challenge.challengeId).toEqual(new Uint8Array(32).fill(7))
    const completion = await permanent.authComplete({ challengeId: challenge.challengeId, code: "123456" })
    expect(completion.state.oneofKind).toBe("authorized")

    const temporary = await InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: fixture.publicKeys,
      temporary: true,
    })
    await temporary.bindTemporary(permanent.authorization)
    await expect(temporary.callRpc({ method: Method.GET_ME, input: { oneofKind: undefined } })).resolves.toEqual({
      oneofKind: undefined,
    })

    expect(permanent.authorization.temporary).toBe(false)
    expect(temporary.authorization.temporary).toBe(true)
    await temporary.close()
    await permanent.close()
  }, 30_000)

  it("rejects a pinned RSA fingerprint that does not match the key", async () => {
    const fixture = await testServer()
    const connect = InlineProtocolV3Connection.connect({
      url: fixture.url,
      rsaPublicKeys: [{ ...fixture.publicKeys[0]!, fingerprint: "1" }],
    })
    await expect(connect).rejects.toThrow("fingerprint")
  })
})
