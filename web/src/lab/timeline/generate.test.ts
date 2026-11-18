import { describe, expect, it } from "vitest"
import { createRandom, generateHistory, LAB_VIEWER, randomText } from "./generate"

describe("createRandom", () => {
  it("is deterministic per seed and stays in range", () => {
    const a = createRandom(7)
    const b = createRandom(7)
    const c = createRandom(8)
    const seqA = Array.from({ length: 20 }, () => a.next())
    expect(Array.from({ length: 20 }, () => b.next())).toEqual(seqA)
    expect(Array.from({ length: 20 }, () => c.next())).not.toEqual(seqA)
    for (const value of seqA) {
      expect(value).toBeGreaterThanOrEqual(0)
      expect(value).toBeLessThan(1)
    }
    const r = createRandom(1)
    for (let i = 0; i < 200; i++) {
      const n = r.int(3, 5)
      expect(n === 3 || n === 4 || n === 5).toBe(true)
    }
  })

  it("randomText is non-empty and varies", () => {
    const r = createRandom(3)
    const texts = Array.from({ length: 50 }, () => randomText(r))
    expect(texts.every((t) => t.length > 0)).toBe(true)
    expect(new Set(texts.map((t) => t.length)).size).toBeGreaterThan(10)
  })
})

describe("generateHistory", () => {
  const history = generateHistory(1234, 500)

  it("is deterministic", () => {
    expect(generateHistory(1234, 500)).toEqual(history)
  })

  it("has increasing IDs and dates, own and incoming messages, and both kinds of media", () => {
    expect(history.map((m) => Number(m.row.messageId))).toEqual(Array.from({ length: 500 }, (_, i) => i + 1))
    for (let i = 1; i < history.length; i++) expect(history[i]!.row.date).toBeGreaterThan(history[i - 1]!.row.date)
    expect(history.some((m) => m.row.fromId === LAB_VIEWER && m.row.out)).toBe(true)
    expect(history.some((m) => !m.row.out)).toBe(true)
    expect(history.some((m) => m.media?.late === true)).toBe(true)
    expect(history.some((m) => m.media?.late === false)).toBe(true)
  })
})
