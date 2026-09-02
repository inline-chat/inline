import { afterEach, describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

describe("inline/bot-skills-sync", () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock("openclaw/plugin-sdk/routing")
    vi.doUnmock("openclaw/plugin-sdk/skill-commands-runtime")
  })

  it("publishes canonical installed skill keys for Agent selection", async () => {
    vi.doMock("openclaw/plugin-sdk/routing", () => ({
      resolveAgentRoute: () => ({ agentId: "main" }),
    }))
    vi.doMock("openclaw/plugin-sdk/skill-commands-runtime", () => ({
      listSkillCommandsForAgents: () => [
        {
          name: "data_analysis",
          displayName: "Data Analysis",
          skillName: "data-analysis",
          description: ` ${"x".repeat(3_999)}😀 `,
        },
        { name: "research", skillName: "research", description: "Research with sources" },
        { name: "data_analysis_2", skillName: "data-analysis", description: "Duplicate" },
      ],
    }))
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true, result: {} }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }))
    globalThis.fetch = fetchMock as typeof fetch

    const { syncInlineAgentSkills } = await import("./bot-skills-sync")
    const result = await syncInlineAgentSkills({
      cfg: {
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
    })

    expect(result).toEqual({ attempted: 1, synced: 1, failed: 0 })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(String(fetchMock.mock.calls[0]?.[0])).toBe("https://api.inline.chat/bot/setMySkills")
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toEqual({
      skills: [
        {
          key: "data-analysis",
          name: "Data Analysis",
          description: "x".repeat(3_999),
          sort_order: 0,
        },
        {
          key: "research",
          name: "research",
          description: "Research with sources",
          sort_order: 1,
        },
      ],
    })
  })

  it("clears the published catalog when the routed Agent has no installed skills", async () => {
    vi.doMock("openclaw/plugin-sdk/routing", () => ({
      resolveAgentRoute: () => ({ agentId: "main" }),
    }))
    vi.doMock("openclaw/plugin-sdk/skill-commands-runtime", () => ({
      listSkillCommandsForAgents: () => [],
    }))
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true, result: {} }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }))
    globalThis.fetch = fetchMock as typeof fetch

    const { syncInlineAgentSkills } = await import("./bot-skills-sync")
    const result = await syncInlineAgentSkills({
      cfg: {
        channels: {
          inline: {
            token: "inline-bot-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
    })

    expect(result).toEqual({ attempted: 1, synced: 1, failed: 0 })
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toEqual({ skills: [] })
  })
})
