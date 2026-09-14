import { describe, expect, it } from "vitest"
import {
  InvalidInlineID,
  compareInlineIds,
  inlineId,
  inlineIdOrderKey,
  int64Max,
  int64Min,
  parseInlineId,
  protocolId,
} from "./index"

describe("InlineID", () => {
  it("round-trips the complete signed int64 boundary", () => {
    for (const value of [int64Min, -1n, 0n, 1n, int64Max]) {
      expect(protocolId(inlineId(value))).toBe(value)
    }
  })

  it("rejects lossy, noncanonical, and out-of-range inputs", () => {
    for (const value of [
      Number.MAX_SAFE_INTEGER + 1,
      "01",
      "-0",
      "+1",
      " 1",
      "",
      int64Min - 1n,
      int64Max + 1n,
    ]) {
      expect(() => inlineId(value)).toThrow(InvalidInlineID)
    }
  })

  it("parses positive route IDs without throwing", () => {
    expect(parseInlineId("9223372036854775807", { positive: true })).toBe(
      "9223372036854775807",
    )
    expect(parseInlineId("-1", { positive: true })).toBeUndefined()
    expect(parseInlineId("not-an-id", { positive: true })).toBeUndefined()
  })

  it("compares IDs exactly past Number.MAX_SAFE_INTEGER", () => {
    const lower = inlineId("9007199254740992")
    const upper = inlineId("9007199254740993")
    expect(compareInlineIds(lower, upper)).toBe(-1)
    expect(compareInlineIds(upper, lower)).toBe(1)
  })

  it("creates lexicographic keys with signed integer order", () => {
    const ids = [inlineId(int64Max), inlineId(0), inlineId(int64Min), inlineId(-1)]
    expect(ids.sort((left, right) => inlineIdOrderKey(left).localeCompare(inlineIdOrderKey(right)))).toEqual([
      inlineId(int64Min),
      inlineId(-1),
      inlineId(0),
      inlineId(int64Max),
    ])
  })
})
