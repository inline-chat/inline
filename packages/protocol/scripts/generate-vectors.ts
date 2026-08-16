import { mkdir } from "node:fs/promises"
import {
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
  rsaPadAttempt,
  serverDhFailureHash,
} from "../src/secure/index.js"
import { handshakeCoreV1Vector, portableCoreV1Vector } from "../src/vectors.js"

const sequence = (length: number, start = 0): Uint8Array =>
  Uint8Array.from({ length }, (_, index) => (start + index) & 0xff)

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
