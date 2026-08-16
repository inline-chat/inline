import { describe, expect, test } from "bun:test"
import { constants, generateKeyPairSync, privateDecrypt, randomBytes } from "node:crypto"
import { gunzipSync, gzipSync } from "node:zlib"
import {
  AesCtrStream,
  acceptObfuscatedClientHeader,
  InvalidEncryptedRecord,
  InlineHandshakeClient,
  InlineHandshakeServer,
  MessageIdGenerator,
  AuthenticatedServerClock,
  AcknowledgementQueue,
  BadMessageRecovery,
  PendingMessageCache,
  ReceiveSequenceValidator,
  ReceiveMessageWindow,
  SequenceNumberGenerator,
  TlReader,
  aesIgeDecrypt,
  aesIgeEncrypt,
  authKeyId,
  bytesToHex,
  createObfuscatedClientHeader,
  createTemporaryKeyBindingProof,
  decodeAbridgedPacket,
  decryptRecord,
  deriveV2Aes,
  decryptDhInner,
  deriveTemporaryAes,
  encodeAbridgedPacket,
  decodeInlineApplicationObject,
  decodeServerDhParams,
  encodeInlineInvoke,
  encodeInlineResult,
  encodeInlineUpdate,
  decodeBadMessageNotification,
  decodeGzipPacked,
  decodeMessageContainer,
  decodeMsgCopy,
  decodeDestroySession,
  decodeGetFutureSalts,
  decodeMsgsAck,
  decodeRpcResult,
  encodeBadServerSalt,
  encodeGzipPacked,
  encodeMessageContainer,
  encodeMsgCopy,
  encodeDestroySession,
  encodeDestroySessionResult,
  encodeDestroyAuthKey,
  encodeDestroyAuthKeyResult,
  encodeFutureSalts,
  encodeGetFutureSalts,
  encodeMsgsAck,
  encodeRpcResult,
  encodeServerDhParamsFail,
  encodeTlBytes,
  encryptRecord,
  encryptDhInner,
  hexToBytes,
  makeRsaPublicKey,
  rsaPadAttempt,
  serverDhFailureHash,
  TELEGRAM_DH_PRIME,
  validateDhParameters,
  validateDhPublicValue,
  verifyTemporaryKeyBindingProof,
} from "../src/secure/index.js"
import { handshakeCoreV1Vector, portableCoreV1Vector } from "../src/vectors.js"

const crc32 = (bytes: Uint8Array): number => {
  let crc = 0xffffffff
  for (const byte of bytes) {
    crc ^= byte
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0)
  }
  return (crc ^ 0xffffffff) >>> 0
}

describe("TL and abridged framing", () => {
  test("round trips both TL bytes length forms", () => {
    for (const length of [0, 1, 253, 254, 1024]) {
      const value = Uint8Array.from({ length }, (_, index) => index)
      const reader = new TlReader(encodeTlBytes(value))
      expect(reader.readBytes()).toEqual(value)
      reader.expectEnd()
    }
  })

  test("round trips short and long abridged packets", () => {
    for (const length of [4, 504, 508, 4096]) {
      const payload = Uint8Array.from({ length }, (_, index) => index)
      expect(decodeAbridgedPacket(encodeAbridgedPacket(payload))).toEqual(payload)
    }
  })

  test("matches all three Inline application constructors", () => {
    const payload = Uint8Array.of(8, 150, 1)
    expect(bytesToHex(encodeInlineInvoke(payload))).toBe("a64a7deb0300000003089601")
    expect(bytesToHex(encodeInlineResult(payload))).toBe("54dc3dac03089601")
    expect(bytesToHex(encodeInlineUpdate(payload))).toBe("982c41dc03089601")
    expect(decodeInlineApplicationObject(encodeInlineInvoke(payload))).toEqual({ kind: "invoke", layer: 3, payload })
    expect(decodeInlineApplicationObject(encodeInlineResult(payload))).toEqual({ kind: "result", payload })
    expect(decodeInlineApplicationObject(encodeInlineUpdate(payload))).toEqual({ kind: "update", payload })
  })
})

describe("portable cryptography", () => {
  test("matches Telegram TDLib AES-IGE fixture CRC", () => {
    const length = 32
    let seed = length >>> 0
    const next = (): number => {
      seed = Math.imul(seed, 123457567) + 987651241 >>> 0
      return (seed >>> 23) & 255
    }
    const plaintext = Uint8Array.from({ length }, next)
    const key = Uint8Array.from({ length: 32 }, next)
    const iv = Uint8Array.from({ length: 32 }, next)
    const ciphertext = aesIgeEncrypt(plaintext, key, iv)
    expect(crc32(ciphertext)).toBe(2423540300)
    expect(aesIgeDecrypt(ciphertext, key, iv)).toEqual(plaintext)
  })

  test("keeps AES-CTR state across arbitrary carrier chunks", () => {
    const key = Uint8Array.from({ length: 32 }, (_, index) => index)
    const iv = Uint8Array.from({ length: 16 }, (_, index) => 255 - index)
    const input = Uint8Array.from({ length: 97 }, (_, index) => index * 17)
    const whole = new AesCtrStream(key, iv).process(input)
    const splitStream = new AesCtrStream(key, iv)
    const split = new Uint8Array(input.length)
    split.set(splitStream.process(input.slice(0, 7)), 0)
    split.set(splitStream.process(input.slice(7, 63)), 7)
    split.set(splitStream.process(input.slice(63)), 63)
    expect(split).toEqual(whole)
  })

  test("constructs a valid obfuscated client header", () => {
    const randomHeader = Uint8Array.from({ length: 64 }, (_, index) => index)
    const client = createObfuscatedClientHeader(randomHeader)
    const server = acceptObfuscatedClientHeader(client.wireHeader)
    expect(client.wireHeader.slice(0, 56)).toEqual(randomHeader.slice(0, 56))
    expect(client.wireHeader.length).toBe(64)
    expect(server.dc).toBe(1)
    const request = encodeAbridgedPacket(Uint8Array.of(1, 2, 3, 4))
    expect(server.inbound.process(client.outbound.process(request))).toEqual(request)
    const response = encodeAbridgedPacket(Uint8Array.of(5, 6, 7, 8))
    expect(client.inbound.process(server.outbound.process(response))).toEqual(response)
  })
})

describe("authorization-key cryptography", () => {
  test("matches the frozen exact RSA_PAD vector", () => {
    const result = rsaPadAttempt(
      Uint8Array.from({ length: 64 }, (_, index) => index),
      Uint8Array.from({ length: 128 }, (_, index) => 0x80 + index),
      Uint8Array.from({ length: 32 }, (_, index) => 0x20 + index),
      hexToBytes(handshakeCoreV1Vector.rsaModulusHex),
      hexToBytes(handshakeCoreV1Vector.rsaExponentHex),
    )
    expect(bytesToHex(result.encryptedData)).toBe(handshakeCoreV1Vector.rsaEncryptedHex)
  })

  test("matches temporary AES derivation and authenticates the exact DH constructor", () => {
    const newNonce = Uint8Array.from({ length: 32 }, (_, index) => index)
    const serverNonce = Uint8Array.from({ length: 16 }, (_, index) => 0xf0 + index)
    const temporary = deriveTemporaryAes(newNonce, serverNonce)
    expect(bytesToHex(temporary.key)).toBe(handshakeCoreV1Vector.temporaryAesKeyHex)
    expect(bytesToHex(temporary.iv)).toBe(handshakeCoreV1Vector.temporaryAesIvHex)
    const serialized = Uint8Array.from({ length: 43 }, (_, index) => 0x40 + index)
    const encrypted = encryptDhInner(serialized, Uint8Array.of(0xaa), newNonce, serverNonce)
    expect(bytesToHex(encrypted)).toBe(handshakeCoreV1Vector.dhEncryptedInnerHex)
    expect(decryptDhInner(encrypted, serialized.length, newNonce, serverNonce)).toEqual(serialized)
    encrypted[0] ^= 1
    expect(() => decryptDhInner(encrypted, serialized.length, newNonce, serverNonce)).toThrow()
  })

  test("accepts the built-in safe prime and enforces generator and public-value bounds", () => {
    const deterministicRandom = (length: number) => new Uint8Array(length).fill(0x42)
    expect(() => validateDhParameters(TELEGRAM_DH_PRIME, 3, deterministicRandom)).not.toThrow()
    expect(() => validateDhParameters(TELEGRAM_DH_PRIME, 8, deterministicRandom)).toThrow()
    expect(() => validateDhPublicValue(Uint8Array.of(3), TELEGRAM_DH_PRIME)).toThrow()
    const middle = TELEGRAM_DH_PRIME.slice()
    middle[0] >>>= 1
    expect(() => validateDhPublicValue(middle, TELEGRAM_DH_PRIME)).not.toThrow()
  })

  test("authenticates the exact server DH failure constructor", () => {
    const nonce = Uint8Array.from({ length: 16 }, (_, index) => index)
    const serverNonce = Uint8Array.from({ length: 16 }, (_, index) => 0x80 + index)
    const newNonce = Uint8Array.from({ length: 32 }, (_, index) => 0x40 + index)
    const hash = serverDhFailureHash(newNonce)
    expect(decodeServerDhParams(encodeServerDhParamsFail(nonce, serverNonce, hash))).toEqual({
      kind: "fail", nonce, serverNonce, newNonceHash: hash,
    })
    const tampered = hash.slice()
    tampered[0] ^= 1
    expect(tampered).not.toEqual(serverDhFailureHash(newNonce))
  })

  test("completes permanent and temporary authorization-key handshakes", async () => {
    const { publicKey, privateKey } = generateKeyPairSync("rsa", {
      modulusLength: 2048,
      publicExponent: 65537,
    })
    const jwk = publicKey.export({ format: "jwk" })
    const modulus = Uint8Array.from(Buffer.from(jwk.n!, "base64url"))
    const exponent = Uint8Array.from(Buffer.from(jwk.e!, "base64url"))
    const publicProfile = makeRsaPublicKey(modulus, exponent)
    const serverKey = {
      ...publicProfile,
      rawDecrypt: (ciphertext: Uint8Array) => Uint8Array.from(privateDecrypt({
        key: privateKey,
        padding: constants.RSA_NO_PADDING,
      }, ciphertext)),
    }
    for (const temporary of [false, true]) {
      let serverEstablished: Uint8Array | undefined
      const server = new InlineHandshakeServer({
        rsaKeys: [serverKey],
        randomBytes: (length) => Uint8Array.from(randomBytes(length)),
        nowSeconds: () => 1_700_000_000,
        authorizationKeys: {
          create: async (key) => {
            serverEstablished = key.key
            return "created"
          },
        },
      })
      const client = new InlineHandshakeClient({
        rsaKeys: [publicProfile],
        randomBytes: (length) => Uint8Array.from(randomBytes(length)),
      })
      let request = client.begin(temporary)
      let clientEstablished: Uint8Array | undefined
      for (let step = 0; step < 3; step += 1) {
        const serverResult = await server.receive(request)
        const clientResult = client.receive(serverResult.response)
        if ("request" in clientResult) request = clientResult.request
        else clientEstablished = clientResult.established.key
      }
      expect(clientEstablished).toBeDefined()
      expect(serverEstablished).toEqual(clientEstablished)
    }
  }, 20_000)

  test("creates and verifies only the isolated temporary-key binding proof", () => {
    const permanentAuthKey = Uint8Array.from({ length: 256 }, (_, index) => index)
    const temporaryAuthKey = Uint8Array.from({ length: 256 }, (_, index) => 255 - index)
    const messageId = 1_700_000_000n << 32n | 4n
    const temporarySessionId = 123n
    const nonce = 456n
    const expiresAt = 1_700_086_400
    const encryptedMessage = createTemporaryKeyBindingProof({
      permanentAuthKey, temporaryAuthKey, temporarySessionId, messageId, nonce, expiresAt,
      randomInt128: new Uint8Array(16).fill(0x11),
      randomPadding: new Uint8Array(8).fill(0x22),
    })
    expect(encryptedMessage.length).toBe(104)
    const expectedPermanentId = new DataView(authKeyId(permanentAuthKey).buffer).getBigInt64(0, true)
    const expectedTemporaryId = new DataView(authKeyId(temporaryAuthKey).buffer).getBigInt64(0, true)
    expect(verifyTemporaryKeyBindingProof({
      encryptedMessage, permanentAuthKey,
      outerPermanentAuthKeyId: expectedPermanentId,
      outerTemporaryAuthKeyId: expectedTemporaryId,
      outerTemporarySessionId: temporarySessionId,
      outerMessageId: messageId,
      outerNonce: nonce,
      outerExpiresAt: expiresAt,
      temporaryKeyExpiresAt: expiresAt,
      nowSeconds: 1_700_000_000,
    }).inner.temporarySessionId).toBe(temporarySessionId)
    const tampered = encryptedMessage.slice()
    tampered[103] ^= 1
    expect(() => verifyTemporaryKeyBindingProof({
      encryptedMessage: tampered, permanentAuthKey,
      outerPermanentAuthKeyId: expectedPermanentId,
      outerTemporaryAuthKeyId: expectedTemporaryId,
      outerTemporarySessionId: temporarySessionId,
      outerMessageId: messageId,
      outerNonce: nonce,
      outerExpiresAt: expiresAt,
      temporaryKeyExpiresAt: expiresAt,
      nowSeconds: 1_700_000_000,
    })).toThrow()
  })
})

describe("encrypted records", () => {
  const authKey = hexToBytes(portableCoreV1Vector.authKeyHex)
  const body = hexToBytes(portableCoreV1Vector.bodyHex)
  const padding = hexToBytes(portableCoreV1Vector.paddingHex)
  const fields = {
    serverSalt: 0x0102030405060708n,
    sessionId: 0x1112131415161718n,
    messageId: (1700000000n << 32n) | 4n,
    sequenceNumber: 1,
    body,
  }

  test("matches the frozen v2 record vector", () => {
    const record = encryptRecord(authKey, "client-to-server", fields, padding)
    expect(bytesToHex(record)).toBe(portableCoreV1Vector.recordHex)
    expect(bytesToHex(record.slice(8, 24))).toBe(portableCoreV1Vector.msgKeyHex)
    const derived = deriveV2Aes(authKey, record.slice(8, 24), "client-to-server")
    expect(bytesToHex(derived.key)).toBe(portableCoreV1Vector.aesKeyHex)
    expect(bytesToHex(derived.iv)).toBe(portableCoreV1Vector.aesIvHex)
    expect(decryptRecord(record, authKey, {
      direction: "client-to-server",
      sessionId: fields.sessionId,
      validServerSalts: new Set([fields.serverSalt]),
      nowSeconds: 1700000000,
    })).toEqual(fields)
  })

  test("authenticates the exact full plaintext including padding", () => {
    const changedPadding = padding.slice()
    changedPadding[0] ^= 1
    expect(encryptRecord(authKey, "client-to-server", fields, changedPadding)).not.toEqual(
      encryptRecord(authKey, "client-to-server", fields, padding),
    )
    const tampered = hexToBytes(portableCoreV1Vector.recordHex)
    tampered[tampered.length - 1] ^= 1
    expect(() => decryptRecord(tampered, authKey, {
      direction: "client-to-server",
      sessionId: fields.sessionId,
      validServerSalts: new Set([fields.serverSalt]),
      nowSeconds: 1700000000,
    })).toThrow(InvalidEncryptedRecord)
  })
})

describe("session counters", () => {
  test("accepts unseen out-of-order IDs but rejects duplicates and IDs below the retained window", () => {
    const window = new ReceiveMessageWindow(3)
    expect(window.claim(8n)).toBeTrue()
    expect(window.claim(4n)).toBeTrue()
    expect(window.claim(12n)).toBeTrue()
    expect(window.claim(8n)).toBeFalse()
    expect(window.claim(16n)).toBeTrue()
    expect(window.claim(4n)).toBeFalse()
  })

  test("generates monotonic IDs and MTProto sequence numbers", () => {
    const ids = new MessageIdGenerator()
    const first = ids.next(1700000000123, 7, 0)
    const second = ids.next(1700000000122, 1, 0)
    expect(second).toBeGreaterThan(first)
    expect(first & 3n).toBe(0n)
    const sequences = new SequenceNumberGenerator()
    expect([sequences.next(false), sequences.next(true), sequences.next(false), sequences.next(true)]).toEqual([0, 1, 2, 3])
  })

  test("anchors protocol time to monotonic elapsed time and validates authenticated recovery", () => {
    let monotonic = 1000
    const clock = new AuthenticatedServerClock({ nowMilliseconds: () => monotonic })
    clock.sample(1_700_000_000)
    monotonic += 2500
    expect(clock.nowMilliseconds()).toBe(1_700_000_002_500)
    const recovery = new BadMessageRecovery()
    const badMessageId = 1_700_000_000n << 32n | 4n
    recovery.add(badMessageId, 1)
    expect(recovery.accept({
      outerServerMessageId: 1_700_000_005n << 32n | 1n,
      badMessageId,
      badSequenceNumber: 1,
      errorCode: 16,
    })).toEqual({ kind: "time", serverSeconds: 1_700_000_005 })
    expect(recovery.accept({
      outerServerMessageId: 1_700_000_005n << 32n | 1n,
      badMessageId: badMessageId + 4n,
      badSequenceNumber: 1,
      errorCode: 16,
    })).toEqual({ kind: "fatal" })
  })

  test("tracks sequence order, acknowledgements, pending resends, and state", () => {
    const sequences = new ReceiveSequenceValidator()
    expect(sequences.validate(8n, 1, true)).toBeUndefined()
    expect(sequences.validate(4n, 0, false)).toBeUndefined()
    expect(sequences.validate(12n, 2, true)).toBe(35)
    const acknowledgements = new AcknowledgementQueue()
    acknowledgements.add(8n)
    acknowledgements.add(8n)
    expect(acknowledgements.drain()).toEqual([8n])
    const pending = new PendingMessageCache()
    pending.retain({ messageId: 8n, sequenceNumber: 1, body: Uint8Array.of(1, 2, 3, 4) })
    expect(pending.state([8n, 12n])).toEqual(Uint8Array.of(4, 1))
    expect(pending.resend([8n]).length).toBe(1)
    pending.acknowledge([8n])
    expect(pending.resend([8n])).toEqual([])
  })
})

describe("reliability service objects", () => {
  test("round trips containers, acknowledgements, results, and bad-salt recovery", () => {
    const child = encodeMsgsAck([4n, 8n])
    const container = encodeMessageContainer([{ messageId: 12n, sequenceNumber: 1, body: child }])
    expect(decodeMessageContainer(container)).toEqual([{ messageId: 12n, sequenceNumber: 1, body: child }])
    expect(decodeMsgsAck(child)).toEqual([4n, 8n])
    expect(decodeRpcResult(encodeRpcResult(12n, child))).toEqual({ requestMessageId: 12n, result: child })
    expect(decodeBadMessageNotification(encodeBadServerSalt(12n, 1, 48, 99n))).toEqual({
      kind: "salt", badMessageId: 12n, badSequenceNumber: 1, errorCode: 48, newServerSalt: 99n,
    })
    expect(() => encodeMessageContainer([{ messageId: 16n, sequenceNumber: 0, body: container }])).toThrow()
  })

  test("enforces the decompressed gzip limit before exposing an object", () => {
    const object = encodeMsgsAck([4n])
    const packed = encodeGzipPacked(gzipSync(object))
    expect(decodeGzipPacked(packed, (bytes, maximum) => gunzipSync(bytes, { maxOutputLength: maximum }))).toEqual(object)
    expect(() => decodeGzipPacked(packed, (bytes) => gunzipSync(bytes), object.length - 1)).toThrow()
  })

  test("matches Telegram message-copy, salt, and destruction constructors", () => {
    const child = encodeMsgsAck([4n])
    expect(decodeMsgCopy(encodeMsgCopy({ messageId: 8n, sequenceNumber: 1, body: child }))).toEqual({
      messageId: 8n,
      sequenceNumber: 1,
      body: child,
    })
    expect(decodeGetFutureSalts(encodeGetFutureSalts(8))).toBe(8)
    expect(bytesToHex(encodeFutureSalts(12n, 100, [{ validSince: 100, validUntil: 200, salt: 44n }])).slice(0, 8))
      .toBe("950850ae")
    expect(decodeDestroySession(encodeDestroySession(99n))).toBe(99n)
    expect(bytesToHex(encodeDestroySessionResult(99n, true)).slice(0, 8)).toBe("fc4520e2")
    expect(bytesToHex(encodeDestroyAuthKey())).toBe("605143d1")
    expect(bytesToHex(encodeDestroyAuthKeyResult("ok"))).toBe("d4e160f6")
  })
})
