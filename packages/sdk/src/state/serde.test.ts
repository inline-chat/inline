import { describe, expect, it } from "vitest"
import { deserializeStateV1, serializeStateV1 } from "./serde.js"

describe("state serde", () => {
  it("roundtrips with bigint dateCursor", () => {
    const raw = serializeStateV1({ version: 1, dateCursor: 123n, lastSeqByChatId: { "10": 5 } })
    const parsed = deserializeStateV1(raw)
    expect(parsed).toEqual({ version: 1, dateCursor: 123n, lastSeqByChatId: { "10": 5 } })
  })

  it("serializes and deserializes with empty optional fields", () => {
    const raw = serializeStateV1({ version: 1 })
    expect(raw).toContain("\"version\": 1")
    expect(deserializeStateV1(raw)).toEqual({ version: 1 })
  })

  it("rejects invalid json shape", () => {
    expect(() => deserializeStateV1(JSON.stringify({ version: 2 }))).toThrow("invalid state json")
  })

  it("rejects non-object roots", () => {
    expect(() => deserializeStateV1(JSON.stringify(null))).toThrow("invalid state json")
  })

  it("rejects invalid dateCursor type", () => {
    expect(() => deserializeStateV1(JSON.stringify({ version: 1, dateCursor: 123 }))).toThrow("invalid state json")
  })

  it("rejects invalid lastSeqByChatId values", () => {
    expect(() => deserializeStateV1(JSON.stringify({ version: 1, lastSeqByChatId: { "1": "nope" } }))).toThrow(
      "invalid state json",
    )
  })

  it("rejects non-object lastSeqByChatId", () => {
    expect(() => deserializeStateV1(JSON.stringify({ version: 1, lastSeqByChatId: 123 }))).toThrow("invalid state json")
  })
})
