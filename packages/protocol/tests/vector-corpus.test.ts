import { describe, expect, test } from "bun:test"
import { bytesToHex, encodeInlineInvoke, encryptRecord, hexToBytes } from "../src/secure/index.js"
import { portableCoreV1Vector } from "../src/vectors.js"

interface VectorCorpus {
  formatVersion: number
  protocol: string
  applicationObjects: { rawProtobufPayloadHex: string; invokeHex: string }
  encryptedRecords: { clientToServer: typeof portableCoreV1Vector }
}

describe("language-neutral conformance corpus", () => {
  test("is the frozen corpus consumed by the TypeScript implementation", async () => {
    const data = await Bun.file(new URL("../vectors/inline-protocol-v1.json", import.meta.url)).bytes()
    expect(new Bun.CryptoHasher("sha256").update(data).digest("hex")).toBe(
      "c82d1dbadeb51edd5821c91e518f6a6a2575e865d9439696ddc57cd881c36155",
    )
    const corpus = JSON.parse(new TextDecoder().decode(data)) as VectorCorpus
    expect(corpus.formatVersion).toBe(1)
    expect(corpus.protocol).toBe("Inline Protocol v1")
    expect(corpus.encryptedRecords.clientToServer).toEqual(portableCoreV1Vector)

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
