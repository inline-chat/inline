import { describe, expect, it } from "vitest"
import {
  positiveInt64FromUint32,
  randomPositiveInt64,
} from "../transactions/helpers"

const int64Maximum = (1n << 63n) - 1n

describe("transaction identifier helpers", () => {
  it("maps the full uint32 pair into the positive signed int64 domain", () => {
    expect(positiveInt64FromUint32(0xffff_ffff, 0xffff_ffff)).toBe(int64Maximum)
    expect(positiveInt64FromUint32(0, 0)).toBe(0n)
  })

  it("never generates a value outside the protocol int64 range", () => {
    for (let index = 0; index < 1_000; index += 1) {
      const value = randomPositiveInt64()
      expect(value).toBeGreaterThanOrEqual(0n)
      expect(value).toBeLessThanOrEqual(int64Maximum)
    }
  })
})
