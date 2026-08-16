import { mkdir } from "node:fs/promises"
import { constants, createPrivateKey, privateDecrypt } from "node:crypto"
import {
  InlineHandshakeClient,
  InlineHandshakeServer,
  authKeyId,
  bytesToHex,
  createObfuscatedClientHeader,
  createTemporaryKeyBindingProof,
  encodeAbridgedPacket,
  encodeBadMsgNotification,
  encodeDestroyAuthKey,
  encodeDestroySession,
  encodeDetailedMessageInfo,
  encodeDhGen,
  encodeGetFutureSalts,
  encodeHttpWait,
  encodeInlineInvoke,
  encodeInlineResult,
  encodeInlineUpdate,
  encodeMessageContainer,
  encodeMsgsAck,
  encodeMsgsStateInfo,
  encodePingDelayDisconnect,
  encodeRpcDropAnswer,
  encodeRpcDropAnswerResult,
  encodeReqDhParams,
  encodeReqPqMulti,
  encodeResPq,
  encodeServerDhParamsFail,
  encodeServerDhParamsOk,
  encodeSetClientDhParams,
  encryptRecord,
  hexToBytes,
  makeRsaPublicKey,
  rsaPadAttempt,
  serverDhFailureHash,
} from "../src/secure/index.js"
import { handshakeCoreV1Vector, portableCoreV1Vector } from "../src/vectors.js"

const sequence = (length: number, start = 0): Uint8Array =>
  Uint8Array.from({ length }, (_, index) => (start + index) & 0xff)

// Deterministic test fixture only. It is excluded from the published package,
// never loaded by runtime code, and has no relationship to an Inline key ring.
const transcriptPrivateKey = createPrivateKey({
  key: {
    kty: "RSA",
    n: "kcJj3r5PLh9ce5X9BJPrG1O_0pWT1oyCOWrtFIoSo2knb-udc3Q7xyA7net1MzdfZLcaakgaRj0f5gjyrTbRuiF0_RjzFkiUwngRTEcgPjaewSu_d3OnHAfSuNSog9R_9nH6VcO7VAM4nzvMNgDpKZTjpvhh1ckHwazLK4bCEg8MpPWjtXp3PmOQgvTHDkoeuhdC3KhhdLZIPV2NfN7Q2uAb1zXn4blzDL5N2D1sYfCYmYgXa6hLGewnNmrOB38t3SfjBfkjzHFZO4Wo7CJh6IoxNsUZhzENMPyZpC73E38xtiyMaXIZVakq5ujuh2tn0p5coYyOb-GUo5AWxkKNhQ",
    e: "AQAB",
    d: "ARxlrXdu3A-iIVEB1iyYcKNhRWYdc9erUGu3td3diYBOLCS0FQKwR_K_cZMvV_4WjIp2uZOmG53wpcywqNBPpecGYL11cNiJxberjhTGsqKw8BD4yxzHC8gle4InbKXMeeDhgxDUVy4VGuWWR10Xadk4KPggqsP2-qtp-wFybjfLMqxLFj_xSUGu9bpJh9pFE-hDFjDQtCyilQtnUfV6DWZHTtyd-SAiI8EV19xV05db6XfwKCAED33_DIMMxGRfMmE95nh_nVD_3wMhhAl8njtH3Du825Q7RSC_7sM2C8DFK2-9Mnl0wRRIR7w-7x4LqA3U1a_zrtUCna5BIMyjuw",
    p: "ysuESxlcZ1RkibBFM-O2vY7lAT3lnVuGNJpCaQcHpRhdKnMUOILs_MHN-cGs4Un_b93V59OhUANeMlHzZgaB_eLwLPFm5hQDDLbApKY45bSf99zkmmFnKqscvvEuFZNTbNHW-1ozEnPGGXjBYb7DlygnO_ftditXsCAOA6pRVwc",
    q: "uAAkVgZy3VRbrjQxXUfkIs7FGCGAcyByDzBPfPBvYaMUIkOgGp4KFXxH6wz93moa7V7AeNnL8l8LweSsDVGjc8Gd0F2n-q0Y3pQk15kxq3-P-Yk77vghFt8KnjdqC0nwW3b1qIaVRJ892taxldKo9L86c64WUgk-lHbDAWZgKBM",
    dp: "lyGu2OzwkU0yk-5a1H3q7T_16MQBQBE6Zi9kOLN1fhM3M3CJ7EeeaAvi_jPZLBiilfLj_B4axO-NnsC2PR2yeMxMo6HQRr05PJth3BLIql-_K9BiSa83XHQjOyWwa4HdFWcY6T9iemjvhIIa1EZ_q0HQY3-0Z3GLqwVojFC8x7c",
    dq: "kViDW3TinVU6yqQt7mqQmrJM3J_yMH8LulXGJIJk6XKBwAM9YGlAu_IdeV4c1-lm9eSoE46v3PgZeIMjKa44eIMUH3kr7Qd5IrFRXQGFS9yLJWmzbzSQJtnvMEXDvcEdXZLdwM728Gr92HVJeHkcv6CjEqgMt6bXyTz7E4sEIAM",
    qi: "nM6cgGTdSmre6uEChdv4wYh2VTeowH_IugFg8ZBK4M4X8zSVOQwIKJg37PltkSrOtWtHhUg2lfjtUDpRf5JA-1-MSYNvX9N4PXJ9DHcTNw80BszPuPrZXVKPLsD-mjtrgrNodoaz4vd3yhcFS6j5JUJpu72QRfgb8dxiFlzfcuQ",
  },
  format: "jwk",
})

const transcriptRsaModulus = hexToBytes(
  "91c263debe4f2e1f5c7b95fd0493eb1b53bfd29593d68c82396aed148a12a369" +
  "276feb9d73743bc7203b9deb7533375f64b71a6a481a463d1fe608f2ad36d1ba" +
  "2174fd18f3164894c278114c47203e369ec12bbf7773a71c07d2b8d4a883d47f" +
  "f671fa55c3bb5403389f3bcc3600e92994e3a6f861d5c907c1accb2b86c2120f" +
  "0ca4f5a3b57a773e639082f4c70e4a1eba1742dca86174b6483d5d8d7cded0da" +
  "e01bd735e7e1b9730cbe4dd83d6c61f0989988176ba84b19ec27366ace077f2d" +
  "dd27e305f923cc71593b85a8ec2261e88a3136c51987310d30fc99a42ef7137f" +
  "31b62c8c69721955a92ae6e8ee876b67d29e5ca18c8e6fe194a39016c6428d85",
)
const transcriptRsaExponent = hexToBytes("010001")

const recordingRandom = (seed: number) => {
  let call = 0
  const calls: Array<{ length: number; hex: string }> = []
  return {
    calls,
    randomBytes: (length: number): Uint8Array => {
      const bytes = sequence(length, seed + call * 17)
      call += 1
      calls.push({ length, hex: bytesToHex(bytes) })
      return bytes
    },
  }
}

const generateHandshakeTranscript = async (temporary: boolean) => {
  const publicKey = makeRsaPublicKey(transcriptRsaModulus, transcriptRsaExponent)
  const serverKey = {
    ...publicKey,
    rawDecrypt: (ciphertext: Uint8Array) => Uint8Array.from(privateDecrypt({
      key: transcriptPrivateKey,
      padding: constants.RSA_NO_PADDING,
    }, ciphertext)),
  }
  const clientRandom = recordingRandom(temporary ? 0x71 : 0x11)
  const serverRandom = recordingRandom(temporary ? 0xb1 : 0x51)
  let serverEstablished: Awaited<ReturnType<InlineHandshakeServer["receive"]>>["established"]
  const server = new InlineHandshakeServer({
    rsaKeys: [serverKey],
    randomBytes: serverRandom.randomBytes,
    nowSeconds: () => 1_700_000_000,
    authorizationKeys: {
      create: async (key) => {
        serverEstablished = key
        return "created"
      },
    },
  })
  const client = new InlineHandshakeClient({
    rsaKeys: [publicKey],
    randomBytes: clientRandom.randomBytes,
  })
  const requests: string[] = []
  const responses: string[] = []
  let request = client.begin(temporary)
  let clientEstablished
  for (let step = 0; step < 3; step += 1) {
    requests.push(bytesToHex(request))
    const serverResult = await server.receive(request)
    responses.push(bytesToHex(serverResult.response))
    const clientResult = client.receive(serverResult.response)
    if ("request" in clientResult) request = clientResult.request
    else clientEstablished = clientResult.established
  }
  if (!clientEstablished || !serverEstablished ||
      bytesToHex(clientEstablished.key) !== bytesToHex(serverEstablished.key)) {
    throw new Error("Deterministic handshake transcript did not establish one shared key")
  }
  return {
    temporary,
    rsaModulusHex: bytesToHex(transcriptRsaModulus),
    rsaExponentHex: bytesToHex(transcriptRsaExponent),
    rsaFingerprint: publicKey.fingerprint.toString(),
    clientRandomCalls: clientRandom.calls,
    serverRandomCalls: serverRandom.calls,
    requestHex: requests,
    responseHex: responses,
    authKeyHex: bytesToHex(clientEstablished.key),
    authKeyIdHex: bytesToHex(authKeyId(clientEstablished.key)),
    serverSalt: clientEstablished.serverSalt.toString(),
    expiresAt: clientEstablished.expiresAt,
  }
}

const nonce = sequence(16)
const serverNonce = sequence(16, 0x40)
const newNonce = sequence(32, 0x80)
const rawPayload = Uint8Array.of(0x08, 0x96, 0x01)
const authKey = hexToBytes(portableCoreV1Vector.authKeyHex)
const rsa = rsaPadAttempt(
  sequence(64),
  sequence(128, 0x80),
  sequence(32, 0x20),
  hexToBytes(handshakeCoreV1Vector.rsaModulusHex),
  hexToBytes(handshakeCoreV1Vector.rsaExponentHex),
)
const obfuscated = createObfuscatedClientHeader(sequence(64))
const binding = createTemporaryKeyBindingProof({
  permanentAuthKey: authKey,
  temporaryAuthKey: Uint8Array.from(authKey, (byte) => 0xff - byte),
  temporarySessionId: 123n,
  messageId: (1_700_000_000n << 32n) | 4n,
  nonce: 456n,
  expiresAt: 1_700_086_400,
  randomInt128: new Uint8Array(16).fill(0x11),
  randomPadding: new Uint8Array(8).fill(0x22),
})

const corpus = {
  formatVersion: 1,
  protocol: "Inline Protocol v1",
  baseline: "MTProto 2.0",
  tl: {
    abridgedShortHex: bytesToHex(encodeAbridgedPacket(Uint8Array.of(1, 2, 3, 4))),
    abridgedLongHeaderHex: bytesToHex(encodeAbridgedPacket(new Uint8Array(508)).slice(0, 4)),
    obfuscatedRandomHeaderHex: bytesToHex(sequence(64)),
    obfuscatedWireHeaderHex: bytesToHex(obfuscated.wireHeader),
  },
  rsaPad: {
    ...handshakeCoreV1Vector,
    dataWithPaddingHex: bytesToHex(rsa.dataWithPadding),
    dataWithHashHex: bytesToHex(rsa.dataWithHash),
    aesEncryptedHex: bytesToHex(rsa.aesEncrypted),
    keyAesEncryptedHex: bytesToHex(rsa.keyAesEncrypted),
  },
  handshakeObjects: {
    reqPqMultiHex: bytesToHex(encodeReqPqMulti(nonce)),
    resPqHex: bytesToHex(encodeResPq(nonce, serverNonce, Uint8Array.of(0x17, 0xed, 0x48, 0x94, 0x1a, 0x08, 0xf9, 0x81), [1n, -2n])),
    reqDhParamsHex: bytesToHex(encodeReqDhParams({
      nonce, serverNonce, p: Uint8Array.of(0x17, 0xed, 0x48, 0x95), q: Uint8Array.of(0x1a, 0x08, 0xf9, 0x85),
      fingerprint: -2n, encryptedData: sequence(256, 0x20),
    })),
    serverDhParamsOkHex: bytesToHex(encodeServerDhParamsOk(nonce, serverNonce, sequence(64, 0xa0))),
    serverDhParamsFailHex: bytesToHex(encodeServerDhParamsFail(nonce, serverNonce, serverDhFailureHash(newNonce))),
    setClientDhParamsHex: bytesToHex(encodeSetClientDhParams(nonce, serverNonce, sequence(64, 0xc0))),
    dhGenOkHex: bytesToHex(encodeDhGen("ok", nonce, serverNonce, sequence(16, 0xe0))),
    dhGenRetryHex: bytesToHex(encodeDhGen("retry", nonce, serverNonce, sequence(16, 0xe0))),
    dhGenFailHex: bytesToHex(encodeDhGen("fail", nonce, serverNonce, sequence(16, 0xe0))),
  },
  handshakeTranscripts: {
    permanent: await generateHandshakeTranscript(false),
    temporary: await generateHandshakeTranscript(true),
  },
  encryptedRecords: {
    clientToServer: portableCoreV1Vector,
    serverToClientHex: bytesToHex(encryptRecord(authKey, "server-to-client", {
      serverSalt: 0x0102030405060708n,
      sessionId: 0x1112131415161718n,
      messageId: (1_700_000_000n << 32n) | 1n,
      sequenceNumber: 1,
      body: encodeInlineUpdate(rawPayload),
    }, sequence(24, 0xd0))),
    minimumPaddingHex: bytesToHex(encryptRecord(authKey, "client-to-server", {
      serverSalt: 1n, sessionId: 2n, messageId: (1_700_000_000n << 32n) | 4n,
      sequenceNumber: 0, body: encodeDestroyAuthKey(),
    }, sequence(12, 0x30))),
    maximumPaddingHex: bytesToHex(encryptRecord(authKey, "client-to-server", {
      serverSalt: 1n, sessionId: 2n, messageId: (1_700_000_000n << 32n) | 8n,
      sequenceNumber: 0, body: encodePingDelayDisconnect(4n, 30),
    }, sequence(1024, 0x50))),
  },
  bindingProofHex: bytesToHex(binding),
  applicationObjects: {
    rawProtobufPayloadHex: bytesToHex(rawPayload),
    invokeHex: bytesToHex(encodeInlineInvoke(rawPayload)),
    resultHex: bytesToHex(encodeInlineResult(rawPayload)),
    updateHex: bytesToHex(encodeInlineUpdate(rawPayload)),
  },
  serviceObjects: {
    msgsAckHex: bytesToHex(encodeMsgsAck([4n, 8n])),
    containerHex: bytesToHex(encodeMessageContainer([
      { messageId: 4n, sequenceNumber: 1, body: encodeInlineInvoke(rawPayload) },
      { messageId: 8n, sequenceNumber: 0, body: encodeMsgsAck([4n]) },
    ])),
    badMsgNotificationHex: bytesToHex(encodeBadMsgNotification(4n, 1, 20)),
    getFutureSaltsHex: bytesToHex(encodeGetFutureSalts(8)),
    destroySessionHex: bytesToHex(encodeDestroySession(0x1112131415161718n)),
    destroyAuthKeyHex: bytesToHex(encodeDestroyAuthKey()),
    rpcDropAnswerHex: bytesToHex(encodeRpcDropAnswer(12n)),
    rpcAnswerUnknownHex: bytesToHex(encodeRpcDropAnswerResult({ kind: "unknown" })),
    rpcAnswerDroppedRunningHex: bytesToHex(encodeRpcDropAnswerResult({ kind: "running" })),
    rpcAnswerDroppedHex: bytesToHex(encodeRpcDropAnswerResult({
      kind: "dropped", messageId: 16n, sequenceNumber: 3, bytes: 64,
    })),
    httpWaitHex: bytesToHex(encodeHttpWait({ maximumDelay: 100, waitAfter: 200, maximumWait: 300 })),
    msgsStateInfoHex: bytesToHex(encodeMsgsStateInfo(12n, Uint8Array.of(1, 4, 132))),
    msgDetailedInfoHex: bytesToHex(encodeDetailedMessageInfo({
      messageId: 12n, answerMessageId: 16n, bytes: 64, status: 0,
    })),
    msgNewDetailedInfoHex: bytesToHex(encodeDetailedMessageInfo({
      answerMessageId: 20n, bytes: 128, status: 0,
    })),
  },
} as const

const output = process.argv[2]
  ? new URL(process.argv[2], `file://${process.cwd()}/`)
  : new URL("../vectors/inline-protocol-v1.json", import.meta.url)
await mkdir(new URL(".", output), { recursive: true })
await Bun.write(output, `${JSON.stringify(corpus, null, 2)}\n`)
