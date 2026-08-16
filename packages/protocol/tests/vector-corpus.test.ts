import { describe, expect, test } from "bun:test"
import { authKeyId, bytesToHex, encodeInlineInvoke, encryptRecord, hexToBytes } from "../src/secure/index.js"
import { portableCoreV1Vector } from "../src/vectors.js"

interface VectorCorpus {
  formatVersion: number
  protocol: string
  applicationObjects: { rawProtobufPayloadHex: string; invokeHex: string }
  encryptedRecords: { clientToServer: typeof portableCoreV1Vector }
  handshakeTranscripts: {
    permanent: { requestHex: string[]; responseHex: string[]; authKeyHex: string; authKeyIdHex: string; expiresAt?: number }
    temporary: { requestHex: string[]; responseHex: string[]; authKeyHex: string; authKeyIdHex: string; expiresAt?: number }
  }
}

describe("language-neutral conformance corpus", () => {
  test("is the frozen corpus consumed by the TypeScript implementation", async () => {
    const data = await Bun.file(new URL("../vectors/inline-protocol-v1.json", import.meta.url)).bytes()
    expect(new Bun.CryptoHasher("sha256").update(data).digest("hex")).toBe(
      "73fbe70763140f91cd1667c9d714848acfe0234a770ee2dfb891939ac2148893",
    )
    const corpus = JSON.parse(new TextDecoder().decode(data)) as VectorCorpus
    expect(corpus.formatVersion).toBe(1)
    expect(corpus.protocol).toBe("Inline Protocol v1")
    expect(corpus.encryptedRecords.clientToServer).toEqual(portableCoreV1Vector)
    for (const transcript of [corpus.handshakeTranscripts.permanent, corpus.handshakeTranscripts.temporary]) {
      expect(transcript.requestHex).toHaveLength(3)
      expect(transcript.responseHex).toHaveLength(3)
      expect(bytesToHex(authKeyId(hexToBytes(transcript.authKeyHex)))).toBe(transcript.authKeyIdHex)
    }
    expect(corpus.handshakeTranscripts.permanent.expiresAt).toBeUndefined()
    expect(corpus.handshakeTranscripts.temporary.expiresAt).toBe(1_700_086_400)

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
  })
})
