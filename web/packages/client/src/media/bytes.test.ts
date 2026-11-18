import { createHash } from "node:crypto"
import { describe, expect, it } from "vitest"
import { bytesEqual, decodeRecord, encodeRecord, fromBase64, fromHex, sha256, Sha256, toBase64, toHex } from "./bytes"
import { testBytes } from "./testing/transfer-server"

describe("media bytes", () => {
  it("hashes like node:crypto, whole and in uneven chunks", () => {
    for (const length of [0, 1, 55, 56, 63, 64, 65, 1000, 200_003]) {
      const data = testBytes(length, length + 1)
      const expected = createHash("sha256").update(data).digest()
      expect(toHex(sha256(data))).toBe(expected.toString("hex"))
      const hash = new Sha256()
      for (let offset = 0; offset < data.length; offset += 7_919) hash.update(data.subarray(offset, offset + 7_919))
      expect(toHex(hash.digest())).toBe(expected.toString("hex"))
    }
  })

  it("round-trips bytes and 64-bit integers through durable JSON without numbers", () => {
    const record = { id: "a", bytes: new Uint8Array([0, 1, 255]), big: 9_007_199_254_740_993n, nested: [{ more: new Uint8Array(3) }] }
    const back = decodeRecord<typeof record>(encodeRecord(record))
    expect(back).toEqual(record)
    expect(back.big).toBe(9_007_199_254_740_993n)
  })

  it("converts hex and base64", () => {
    const data = testBytes(100_000)
    expect(bytesEqual(fromHex(toHex(data)), data)).toBe(true)
    expect(bytesEqual(fromBase64(toBase64(data)), data)).toBe(true)
    expect(() => fromHex("zz")).toThrow()
  })
})
