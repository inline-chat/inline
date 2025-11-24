import { describe, it, expect, beforeEach, afterEach } from "bun:test"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"

const TEN_MINUTES_MS = 10 * 60 * 1000

const realNow = Date.now

describe("AccessGuardsCache", () => {
  beforeEach(() => {
    AccessGuardsCache.resetAll()
    Date.now = realNow
  })

  afterEach(() => {
    AccessGuardsCache.resetAll()
    Date.now = realNow
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
    const base = realNow()
    Date.now = () => base
    AccessGuardsCache.setSpaceMember(3, 4)

    Date.now = () => base + TEN_MINUTES_MS + 1
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

