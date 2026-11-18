import { manualTime } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { MatchTier, matchText, type Match } from "./match"
import {
  UsageStore,
  compareRanked,
  compareSuggestions,
  memoryUsagePersistence,
  noUsage,
  rankScore,
  storageUsagePersistence,
  usageLimits,
  usageQueryKeys,
  type RankInput,
} from "./usage"

const DAY = 86_400_000
const T0 = Date.UTC(2026, 10, 17)

const clockAt = (start = T0) => {
  let now = start
  return { now: () => now, set: (value: number) => (now = value), add: (ms: number) => (now += ms) }
}

describe("UsageStore", () => {
  it("records a pick for the query and every compact prefix of 2 to 8 letters", () => {
    const wall = clockAt()
    const store = new UsageStore({ now: wall.now })
    store.recordSelection("user:1", "Alice Smith")
    expect(store.signals("al").get("user:1")?.queryAffinity).toBeCloseTo(1)
    // Every shared key adds: seven prefixes, plus the whole query when it is the same.
    expect(store.signals("alicesmi").get("user:1")?.queryAffinity).toBeCloseTo(7)
    expect(store.signals("alice smith").get("user:1")?.queryAffinity).toBeCloseTo(8)
    expect(store.signals("a").get("user:1")).toBeUndefined()
    expect(store.signals("bo").get("user:1")).toBeUndefined()
  })

  it("records nothing for an empty query", () => {
    const store = new UsageStore({ now: clockAt().now })
    store.recordSelection("user:1", "  ")
    expect(store.signals("").size).toBe(0)
    expect(store.revision.peek()).toBe(0)
  })

  it("decays query affinity with a 30 day half-life and switches with 45 days", () => {
    const wall = clockAt()
    const store = new UsageStore({ now: wall.now })
    store.recordSelection("chat:5", "design")
    store.recordSwitch("chat:5")
    const fresh = store.signals("de").get("chat:5")
    expect(fresh?.queryAffinity).toBeCloseTo(1)
    expect(fresh?.switchFrecency).toBeCloseTo(1)
    wall.add(30 * DAY)
    expect(store.signals("de").get("chat:5")?.queryAffinity).toBeCloseTo(0.5)
    wall.set(T0 + 45 * DAY)
    expect(store.signals("").get("chat:5")?.switchFrecency).toBeCloseTo(0.5)
    expect(store.signals("").get("chat:5")?.lastUsedAt).toBe(T0)
  })

  it("grows with log2 of the count", () => {
    const store = new UsageStore({ now: clockAt().now })
    for (let i = 0; i < 3; i++) store.recordSwitch("chat:1")
    expect(store.signals("").get("chat:1")?.switchFrecency).toBeCloseTo(2)
  })

  it("drops records older than 180 days and keeps 12 items per query", () => {
    const wall = clockAt()
    const store = new UsageStore({ now: wall.now })
    store.recordSwitch("chat:old")
    store.recordSelection("chat:old", "zz")
    wall.add((usageLimits.retentionDays + 1) * DAY)
    store.recordSwitch("chat:new")
    expect(store.signals("").has("chat:old")).toBe(false)
    expect(store.signals("zz").has("chat:old")).toBe(false)

    for (let i = 0; i < 20; i++) {
      wall.add(1000)
      store.recordSelection(`chat:${i}`, "qq")
    }
    const picked = [...store.signals("qq")].filter(([, s]) => s.queryAffinity > 0).map(([key]) => key)
    expect(picked).toHaveLength(usageLimits.maxItemsPerQuery)
    expect(picked).toContain("chat:19")
    expect(picked).not.toContain("chat:0")
  })

  it("saves after 350 ms of quiet and reloads what it saved", () => {
    const time = manualTime()
    const wall = clockAt()
    const persistence = memoryUsagePersistence()
    const store = new UsageStore({ persistence, now: wall.now, clock: time })
    store.recordSelection("user:7", "kim")
    time.advance(200)
    store.recordSwitch("user:7")
    time.advance(349)
    expect(persistence.saved).toHaveLength(0)
    time.advance(1)
    expect(persistence.saved).toHaveLength(1)

    const reloaded = new UsageStore({ persistence, now: wall.now })
    expect(reloaded.signals("ki").get("user:7")).toEqual(store.signals("ki").get("user:7"))
  })

  it("keeps search text out of the saved snapshot", () => {
    const store = new UsageStore({ now: clockAt().now })
    store.recordSelection("user:1", "confidential")
    expect(JSON.stringify(store.snapshot())).not.toContain("confid")
    expect(usageQueryKeys("Confidential")).toEqual(usageQueryKeys("  confidential "))
  })

  it("treats an unreadable snapshot as empty and survives a failing storage", () => {
    for (const raw of [undefined, null, "x", 3, { v: 2 }, { v: 1, items: [1], queries: "q" }, { v: 1, items: { a: { c: "1", t: 0 } } }]) {
      const store = new UsageStore({ persistence: memoryUsagePersistence(raw), now: clockAt().now })
      expect(store.signals("").size).toBe(0)
    }
    const broken = storageUsagePersistence(
      {
        getItem: () => {
          throw new Error("blocked")
        },
        setItem: () => {
          throw new Error("quota")
        },
      },
      "k",
    )
    const store = new UsageStore({ persistence: broken, now: clockAt().now })
    expect(() => store.recordSwitch("chat:1")).not.toThrow()
    expect(store.signals("").get("chat:1")?.switchFrecency).toBeCloseTo(1)
  })

  it("clears and saves at once, and bumps its revision on every change", () => {
    const persistence = memoryUsagePersistence()
    const store = new UsageStore({ persistence, now: clockAt().now })
    store.recordSwitch("chat:1")
    const revision = store.revision.peek()
    store.clear()
    expect(store.revision.peek()).toBe(revision + 1)
    expect(store.signals("").size).toBe(0)
    expect(persistence.saved.at(-1)).toEqual({ v: 1, items: {}, queries: {} })
  })
})

const match = (tier: Match["tier"], fieldPriority = 400): Match => {
  const base = matchText("a", "a")
  if (!base) throw new Error("match")
  return { ...base, tier, fieldPriority }
}

const input = (overrides: Partial<RankInput> & { order: number }): RankInput => ({
  match: match(MatchTier.tokenPrefix),
  usage: noUsage,
  ...overrides,
})

describe("ranking", () => {
  it("orders by tier, then query affinity, frecency, field priority, space, pinned and unread, activity, order", () => {
    const ranked = [
      input({ order: 0 }),
      input({ order: 1, lastActivity: 100 }),
      input({ order: 2, unread: true }),
      input({ order: 3, pinned: true }),
      input({ order: 4, currentSpace: true }),
      input({ order: 5, match: match(MatchTier.tokenPrefix, 500) }),
      input({ order: 6, usage: { switchFrecency: 1, queryAffinity: 0 } }),
      input({ order: 7, usage: { switchFrecency: 0, queryAffinity: 1 } }),
      input({ order: 8, match: match(MatchTier.fieldPrefix) }),
    ].sort(compareRanked)
    expect(ranked.map((r) => r.order)).toEqual([8, 7, 6, 5, 4, 3, 2, 1, 0])
  })

  it("never lets usage lift a result over a better tier in the mixed score", () => {
    const heavy = { switchFrecency: 1e9, queryAffinity: 1e9 }
    expect(rankScore(match(MatchTier.substring, 999), heavy)).toBeLessThan(rankScore(match(MatchTier.acronym, 0)))
    expect(rankScore(match(MatchTier.tokenPrefix), { switchFrecency: 0, queryAffinity: 1 })).toBeGreaterThan(
      rankScore(match(MatchTier.tokenPrefix)),
    )
  })

  it("orders suggestions by frecency, then last use, then sidebar order", () => {
    const list = [
      { order: 0, usage: { switchFrecency: 1, queryAffinity: 0, lastUsedAt: 1 } },
      { order: 1, usage: { switchFrecency: 1, queryAffinity: 0, lastUsedAt: 2 } },
      { order: 2, usage: { switchFrecency: 3, queryAffinity: 0, lastUsedAt: 0 } },
      { order: 3, usage: { switchFrecency: 1, queryAffinity: 0, lastUsedAt: 2 } },
    ].sort(compareSuggestions)
    expect(list.map((e) => e.order)).toEqual([2, 1, 3, 0])
  })
})
