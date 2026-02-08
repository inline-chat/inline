import { describe, it, expect, beforeEach, afterEach, setSystemTime } from "bun:test"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"

const TEN_MINUTES_MS = 10 * 60 * 1000

describe("AccessGuardsCache", () => {
  beforeEach(() => {
    AccessGuardsCache.resetAll()
    setSystemTime()
  })

  afterEach(() => {
    AccessGuardsCache.resetAll()
    setSystemTime()
  })

  it("caches positive space membership", () => {
    AccessGuardsCache.setSpaceMember(1, 2)

    expect(AccessGuardsCache.getSpaceMember(1, 2)).toBe(true)
  })

  it("evicts on resetSpaceMember", () => {
    AccessGuardsCache.setSpaceMember(1, 2)
    AccessGuardsCache.resetSpaceMember(1, 2)

    expect(AccessGuardsCache.getSpaceMember(1, 2)).toBeUndefined()
  })

  it("expires entries after ttl", () => {
    const base = 1 // Bun's setSystemTime treats 0 as "reset to real time".
    setSystemTime(new Date(base))
    AccessGuardsCache.setSpaceMember(3, 4)

    setSystemTime(new Date(base + TEN_MINUTES_MS - 1))
    expect(AccessGuardsCache.getSpaceMember(3, 4)).toBe(true)

    // TTL boundary is inclusive: expires when `now >= expiresAt`.
    setSystemTime(new Date(base + TEN_MINUTES_MS))
    expect(AccessGuardsCache.getSpaceMember(3, 4)).toBeUndefined()
  })

  it("clears when capacity is exceeded", () => {
    // Fill to capacity
    for (let i = 0; i < 10_000; i += 1) {
      AccessGuardsCache.setSpaceMember(100, i)
    }

    // Adding one more should clear then insert the new key
    AccessGuardsCache.setSpaceMember(200, 1)

    expect(AccessGuardsCache.getSpaceMember(100, 0)).toBeUndefined()
    expect(AccessGuardsCache.getSpaceMember(200, 1)).toBe(true)
  })

  it("resets all entries for a user across scopes", () => {
    AccessGuardsCache.setSpaceMember(1, 9)
    AccessGuardsCache.setChatParticipant(10, 9)
    AccessGuardsCache.setChatParticipant(11, 8)

    AccessGuardsCache.resetForUser(9)

    expect(AccessGuardsCache.getSpaceMember(1, 9)).toBeUndefined()
    expect(AccessGuardsCache.getChatParticipant(10, 9)).toBeUndefined()
    expect(AccessGuardsCache.getChatParticipant(11, 8)).toBe(true)
  })
})
