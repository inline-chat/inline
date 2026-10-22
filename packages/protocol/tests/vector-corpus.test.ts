import { describe, expect, test } from "bun:test"
import { gunzipSync } from "node:zlib"
import {
  authKeyId,
  bytesToHex,
  createTemporaryKeyBindingProof,
  decodeGzipPacked,
  decodeRpcResult,
  decryptRecord,
  encodeInlineInvoke,
  encryptRecord,
  hexToBytes,
} from "../src/secure/index.js"
import { portableCoreV1Vector } from "../src/vectors.js"

interface VectorCorpus {
  formatVersion: number
  protocol: string
  applicationObjects: { rawProtobufPayloadHex: string; invokeHex: string; updateHex: string }
  serviceObjects: { destroyAuthKeyHex: string; gzipPackedRpcResultHex: string; gzipPackedInnerResultHex: string }
  bindingProofHex: string
  encryptedRecords: {
    clientToServer: typeof portableCoreV1Vector
    serverToClientHex: string
    minimumPaddingHex: string
    maximumPaddingHex: string
  }
  handshakeTranscripts: {
    permanent: { requestHex: string[]; responseHex: string[]; authKeyHex: string; authKeyIdHex: string; expiresAt?: number }
    temporary: { requestHex: string[]; responseHex: string[]; authKeyHex: string; authKeyIdHex: string; expiresAt?: number }
    generatorFour: { requestHex: string[]; responseHex: string[]; authKeyHex: string; authKeyIdHex: string; expiresAt?: number; generator: number }
  }
}

describe("language-neutral conformance corpus", () => {
  test("is the frozen corpus consumed by the TypeScript implementation", async () => {
    const data = await Bun.file(new URL("../vectors/inline-protocol-v1.json", import.meta.url)).bytes()
    expect(new Bun.CryptoHasher("sha256").update(data).digest("hex")).toBe(
      "35a3bccb6e11a934d83e2370e739204144c1d0b89653b7780b22fd124e20b816",
    )
    const corpus = JSON.parse(new TextDecoder().decode(data)) as VectorCorpus
    expect(corpus.formatVersion).toBe(1)
    expect(corpus.protocol).toBe("Inline Protocol v1")
    expect(corpus.encryptedRecords.clientToServer).toEqual(portableCoreV1Vector)
    for (const transcript of [
      corpus.handshakeTranscripts.permanent,
      corpus.handshakeTranscripts.temporary,
      corpus.handshakeTranscripts.generatorFour,
    ]) {
      expect(transcript.requestHex).toHaveLength(3)
      expect(transcript.responseHex).toHaveLength(3)
      expect(bytesToHex(authKeyId(hexToBytes(transcript.authKeyHex)))).toBe(transcript.authKeyIdHex)
    }
    expect(corpus.handshakeTranscripts.permanent.expiresAt).toBeUndefined()
    expect(corpus.handshakeTranscripts.temporary.expiresAt).toBe(1_700_086_400)
    expect(corpus.handshakeTranscripts.generatorFour.generator).toBe(4)

    const vector = corpus.encryptedRecords.clientToServer
    expect(bytesToHex(encodeInlineInvoke(hexToBytes(corpus.applicationObjects.rawProtobufPayloadHex)))).toBe(
      corpus.applicationObjects.invokeHex,
    )
    expect(bytesToHex(encryptRecord(hexToBytes(vector.authKeyHex), vector.direction, {
      serverSalt: BigInt(`0x${vector.serverSalt}`),
      sessionId: BigInt(`0x${vector.sessionId}`),
      messageId: (BigInt(vector.messageId.split(":")[0]!) << 32n) | BigInt(vector.messageId.split(":")[1]!),
      sequenceNumber: vector.sequenceNumber,
      body: hexToBytes(vector.bodyHex),
    }, hexToBytes(vector.paddingHex)))).toBe(vector.recordHex)

    const authKey = hexToBytes(vector.authKeyHex)
    const sharedValidation = {
      sessionId: 0x1112131415161718n,
      validServerSalts: new Set([0x0102030405060708n]),
      nowSeconds: 1_700_000_000,
    }
    expect(bytesToHex(decryptRecord(hexToBytes(corpus.encryptedRecords.serverToClientHex), authKey, {
      direction: "server-to-client",
      ...sharedValidation,
    }).body)).toBe(corpus.applicationObjects.updateHex)
    expect(bytesToHex(decryptRecord(hexToBytes(corpus.encryptedRecords.minimumPaddingHex), authKey, {
      direction: "client-to-server",
      sessionId: 2n,
      validServerSalts: new Set([1n]),
      nowSeconds: 1_700_000_000,
    }).body)).toBe(corpus.serviceObjects.destroyAuthKeyHex)
    expect(decryptRecord(hexToBytes(corpus.encryptedRecords.maximumPaddingHex), authKey, {
      direction: "client-to-server",
      sessionId: 2n,
      validServerSalts: new Set([1n]),
      nowSeconds: 1_700_000_000,
    }).messageId).toBe((1_700_000_000n << 32n) | 8n)

    expect(bytesToHex(createTemporaryKeyBindingProof({
      permanentAuthKey: authKey,
      temporaryAuthKey: Uint8Array.from(authKey, (byte) => 0xff - byte),
      temporarySessionId: 123n,
      messageId: (1_700_000_000n << 32n) | 4n,
      nonce: 456n,
      expiresAt: 1_700_086_400,
      randomInt128: new Uint8Array(16).fill(0x11),
      randomPadding: new Uint8Array(8).fill(0x22),
    }))).toBe(corpus.bindingProofHex)

    const packedResult = decodeRpcResult(hexToBytes(corpus.serviceObjects.gzipPackedRpcResultHex))
    expect(packedResult.requestMessageId).toBe(24n)
    expect(bytesToHex(decodeGzipPacked(packedResult.result, (packed, maximum) =>
      Uint8Array.from(gunzipSync(packed, { maxOutputLength: maximum }))))).toBe(corpus.serviceObjects.gzipPackedInnerResultHex)
  })
})
