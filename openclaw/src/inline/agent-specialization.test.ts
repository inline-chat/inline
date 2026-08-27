import { describe, expect, it, vi } from "vitest"
import {
  createInlineAgentSpecializationResolver,
  projectInlineAgentSessionKey,
} from "./agent-specialization.js"

describe("Inline Agent specialization resolver", () => {
  it("projects a separate session only for an authenticated specialization", () => {
    expect(projectInlineAgentSessionKey("agent:main:inline:group:7", "42", {
      name: "Data Analyst",
    })).toBe("agent:main:inline:group:7:inline-agent:42")
    expect(projectInlineAgentSessionKey("agent:main:inline:group:7", "42", null)).toBe(
      "agent:main:inline:group:7",
    )
  })

  it("coalesces concurrent loads and reuses a bounded cache", async () => {
    let now = 1_000
    const fetchAgent = vi.fn(async () => ({ name: "Data Analyst", skillKey: "analysis" }))
    const resolver = createInlineAgentSpecializationResolver({
      fetchAgent,
      ttlMs: 100,
      now: () => now,
    })

    const [first, second] = await Promise.all([resolver.resolve("7"), resolver.resolve("7")])
    expect(first).toEqual(second)
    expect(fetchAgent).toHaveBeenCalledTimes(1)

    await resolver.resolve("7")
    expect(fetchAgent).toHaveBeenCalledTimes(1)

    now += 101
    await resolver.resolve("7")
    expect(fetchAgent).toHaveBeenCalledTimes(2)
  })

  it("caches a missing Agent without fabricating a specialization", async () => {
    const fetchAgent = vi.fn(async () => null)
    const resolver = createInlineAgentSpecializationResolver({ fetchAgent })

    await expect(resolver.resolve("7")).resolves.toBeNull()
    await expect(resolver.resolve("7")).resolves.toBeNull()
    expect(fetchAgent).toHaveBeenCalledTimes(1)
  })

  it("evicts the oldest specialization at the configured bound", async () => {
    const fetchAgent = vi.fn(async (agentId: string) => ({ name: `Agent ${agentId}` }))
    const resolver = createInlineAgentSpecializationResolver({ fetchAgent, maxEntries: 1 })

    await resolver.resolve("7")
    await resolver.resolve("8")
    await resolver.resolve("7")

    expect(fetchAgent).toHaveBeenCalledTimes(3)
  })
})
