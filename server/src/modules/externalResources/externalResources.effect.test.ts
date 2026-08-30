import { describe, expect, test, vi } from "vitest"
import type { InputPeer } from "@inline-chat/protocol/core"
import type { IntegrationAuthToken } from "@in/server/modules/integrations/authResolver"
import { Effect } from "effect"
import { ExternalResourceCache } from "./cache"
import {
  ExternalResourceAccessFailure,
  ExternalResourceInputError,
  ExternalResourceProviderFailure,
  makeExternalResourceSearch,
  type ExternalResourceRecord,
} from "./externalResources.effect"

vi.mock("@in/server/db/models/chats", () => ({ ChatModel: {} }))
vi.mock("@in/server/modules/authorization/accessGuards", () => ({ AccessGuards: {} }))
vi.mock("@in/server/modules/integrations/authResolver", () => ({
  resolveIntegrationAuthCandidates: async () => [],
  userThenSpaceIntegrationAuthPolicy: { scopeOrderInSpace: ["user", "space"] },
}))

const peer: InputPeer = {
  type: {
    oneofKind: "chat",
    chat: { chatId: 42n },
  },
}

describe("ExternalResourceSearch", () => {
  test("new-thread search uses personal connections without looking up a chat or space", async () => {
    const resolveSpaceId = vi.fn(async () => { throw new Error("No chat should be resolved") })
    const resolveConnections = vi.fn(async (_provider: string, userId: number, spaceId: number | null) => {
      expect(spaceId).toBeNull()
      return [connection({ integrationId: userId * 10, userId })]
    })
    const service = makeExternalResourceSearch({
      resolveSpaceId,
      resolveConnection: async () => null,
      resolveConnections,
      searchNotion: async (auth) => [{
        id: `personal-${auth.integrationId}`,
        provider: "notion",
        kind: "database",
        title: "Reminders",
        url: `https://www.notion.so/personal-${auth.integrationId}`,
      }],
    })

    const first = await Effect.runPromise(service.search({ currentUserId: 1, query: "reminders" }))
    const second = await Effect.runPromise(service.search({ currentUserId: 2, query: "reminders" }))
    expect(first.map((resource) => resource.id)).toEqual(["personal-10"])
    expect(second.map((resource) => resource.id)).toEqual(["personal-20"])
    expect(resolveSpaceId).not.toHaveBeenCalled()
    expect(resolveConnections).toHaveBeenCalledWith("notion", 1, null)
    expect(resolveConnections).toHaveBeenCalledWith("notion", 2, null)
  })

  test.each<IntegrationAuthToken["owner"]>([
    { type: "space", spaceId: 7 },
    { type: "user", userId: 2 },
  ])("new-thread search rejects credentials outside the requesting user: %j", async (owner) => {
    const searchNotion = vi.fn(async () => [])
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => { throw new Error("No chat should be resolved") },
      resolveConnection: async () => ({ ...connection({ integrationId: 20, userId: 1 }), owner }),
      searchNotion,
    })

    const result = await Effect.runPromiseExit(service.search({ currentUserId: 1, query: "reminders" }))
    expect(result._tag).toBe("Failure")
    expect(searchNotion).not.toHaveBeenCalled()
  })

  test("normalizes queries and caches connection-scoped results", async () => {
    let connectionLookups = 0
    const calls: Array<{
      integrationId: number
      query: string
      limit: number
    }> = []
    const resource: ExternalResourceRecord = {
      id: "page-1",
      provider: "notion",
      kind: "page",
      title: "Roadmap",
      url: "https://www.notion.so/page-1",
    }
    const service = makeExternalResourceSearch(
      {
        resolveSpaceId: async () => 7,
        resolveConnection: async () => {
          connectionLookups += 1
          return connection({ integrationId: 20, userId: 1 })
        },
        searchNotion: async (auth, query, limit) => {
          calls.push({ integrationId: auth.integrationId, query, limit })
          return [resource]
        },
      },
      {
        results: new ExternalResourceCache({ ttlMs: 10_000 }),
        connections: new ExternalResourceCache({ ttlMs: 10_000 }),
      },
    )

    const input = {
      peerId: peer,
      currentUserId: 1,
      query: "  product   roadmap ",
    }
    expect(await Effect.runPromise(service.search(input))).toEqual([resource])
    expect(await Effect.runPromise(service.search(input))).toEqual([resource])
    expect(connectionLookups).toBe(1)
    expect(calls).toEqual([{
      integrationId: 20,
      query: "product roadmap",
      limit: 12,
    }, {
      integrationId: 20,
      query: "product roadmap",
      limit: 24,
    }])
  })

  test("no connection is a cached no-op across different queries", async () => {
    let connectionLookups = 0
    let providerCalls = 0
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => null,
      resolveConnection: async () => {
        connectionLookups += 1
        return null
      },
      searchNotion: async () => {
        providerCalls += 1
        return []
      },
    })

    expect(await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: " ",
    }))).toEqual([])
    expect(await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: "roadmap",
    }))).toEqual([])
    expect(await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: "projects",
    }))).toEqual([])
    expect(connectionLookups).toBe(1)
    expect(providerCalls).toBe(0)
  })

  test("empty normalized query requests recent provider resources", async () => {
    let receivedQuery: string | undefined
    let receivedLimit: number | undefined
    const resource: ExternalResourceRecord = {
      id: "recent-page",
      provider: "notion",
      kind: "page",
      title: "Recently edited",
      url: "https://www.notion.so/recent-page",
    }
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => connection({ integrationId: 20, userId: 1 }),
      searchNotion: async (_, query, limit) => {
        receivedQuery = query
        receivedLimit = limit
        return [resource]
      },
    })

    expect(await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: "  ",
    }))).toEqual([resource])
    expect(receivedQuery).toBe("")
    expect(receivedLimit).toBe(6)
  })

  test("does not share personal-connection results between users", async () => {
    const providerCalls: number[] = []
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async (_, currentUserId) =>
        connection({
          integrationId: currentUserId === 1 ? 20 : 30,
          userId: currentUserId,
        }),
      searchNotion: async (auth) => {
        providerCalls.push(auth.integrationId)
        return [{
          id: `page-${auth.integrationId}`,
          provider: "notion",
          kind: "page",
          title: `Page ${auth.integrationId}`,
          url: `https://www.notion.so/page-${auth.integrationId}`,
        }]
      },
    })

    const first = await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: "roadmap",
    }))
    const second = await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 2,
      query: "roadmap",
    }))

    expect(first[0]?.title).toBe("Page 20")
    expect(second[0]?.title).toBe("Page 30")
    expect(providerCalls).toEqual([20, 20, 30, 30])
  })

  test("merges personal and space search results without duplicates", async () => {
    const personal = connection({ integrationId: 20, userId: 1 })
    const space: IntegrationAuthToken = {
      provider: "notion",
      accessToken: "space-token",
      integrationId: 30,
      owner: { type: "space", spaceId: 7 },
    }
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => personal,
      resolveConnections: async () => [personal, space],
      searchNotion: async (auth) => [
        {
          id: `page-${auth.integrationId}`,
          provider: "notion",
          kind: "page",
          title: `Page ${auth.integrationId}`,
          url: auth.integrationId === 20
            ? "https://www.notion.so/shared"
            : "https://www.notion.so/space-only",
        },
        {
          id: "page-20",
          provider: "notion",
          kind: "page",
          title: "Duplicate",
          url: "https://www.notion.so/shared",
        },
      ],
    })

    const results = await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: "roadmap",
    }))

    expect(results.map((resource) => resource.url)).toEqual([
      "https://www.notion.so/shared",
      "https://www.notion.so/space-only",
    ])
  })

  test("uses space results when the personal connection fails", async () => {
    const personal = connection({ integrationId: 20, userId: 1 })
    const space: IntegrationAuthToken = {
      provider: "notion",
      accessToken: "space-token",
      integrationId: 30,
      owner: { type: "space", spaceId: 7 },
    }
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => personal,
      resolveConnections: async () => [personal, space],
      searchNotion: async (auth) => {
        if (auth.owner.type === "user") throw new Error("revoked personal token")
        return [{
          id: "space-page",
          provider: "notion",
          kind: "page",
          title: "Space page",
          url: "https://www.notion.so/space-page",
        }]
      },
    })

    const results = await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: "roadmap",
    }))
    expect(results.map((resource) => resource.id)).toEqual(["space-page"])
  })

  test("rejects a connection whose owner does not match the request", async () => {
    let providerCalls = 0
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => connection({ integrationId: 20, userId: 99 }),
      searchNotion: async () => {
        providerCalls += 1
        return []
      },
    })

    const error = await Effect.runPromise(
      service.search({
        peerId: peer,
        currentUserId: 1,
        query: "roadmap",
      }).pipe(Effect.flip),
    )
    expect(error).toBeInstanceOf(ExternalResourceAccessFailure)
    expect(providerCalls).toBe(0)
  })

  test("bounds unique provider searches per user and connection", async () => {
    let providerCalls = 0
    const service = makeExternalResourceSearch(
      {
        resolveSpaceId: async () => 7,
        resolveConnection: async () => connection({ integrationId: 20, userId: 1 }),
        searchNotion: async () => {
          providerCalls += 1
          return []
        },
      },
      {
        providerRequestLimits: {
          perUser: { max: 2, windowMs: 60_000 },
          perConnection: { max: 2, windowMs: 60_000 },
        },
        now: () => 1_000,
      },
    )

    expect(await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: "roadmap",
    }))).toEqual([])
    expect(await Effect.runPromise(service.search({
      peerId: peer,
      currentUserId: 1,
      query: "projects",
    }).pipe(Effect.flip))).toBeInstanceOf(ExternalResourceProviderFailure)
    expect(providerCalls).toBe(2)
  })

  test("ranks space candidates before trimming a full personal result pool", async () => {
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => null,
      resolveConnections: async () => [connection({ integrationId: 20, userId: 1 }), {
        ...connection({ integrationId: 30, userId: 1 }), owner: { type: "space", spaceId: 7 },
      }],
      searchNotion: async (auth, _, limit, object) => auth.integrationId === 30 && object === "data_source"
        ? [{ id: "reminders", provider: "notion", kind: "database", title: "Reminders", url: "https://notion.so/reminders" }]
        : Array.from({ length: limit }, (_, i) => ({
          id: `task-${i}`, provider: "notion" as const, kind: "page" as const,
          title: `Reminders for customer ${i}`, url: `https://notion.so/task-${i}`,
        })),
    })
    const results = await Effect.runPromise(service.search({ peerId: peer, currentUserId: 1, query: "Reminders" }))
    expect(results).toHaveLength(6)
    expect(results[0]?.id).toBe("reminders")
  })

  test("a failed category does not poison its cache or hide successful sources", async () => {
    let failPages = true
    const calls: string[] = []
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => connection({ integrationId: 20, userId: 1 }),
      searchNotion: async (_, __, ___, object) => {
        calls.push(object!)
        if (object === "page" && failPages) throw new Error("timeout")
        return [{ id: object!, provider: "notion", kind: "page", title: "Reminders", url: `https://notion.so/${object}` }]
      },
    })
    const input = { peerId: peer, currentUserId: 1, query: "Reminders" }
    expect(await Effect.runPromise(service.search(input))).toHaveLength(1)
    failPages = false
    expect(await Effect.runPromise(service.search(input))).toHaveLength(2)
    expect(calls).toEqual(["data_source", "page", "page"])
  })

  test("rate-limited queries can retry after the budget resets without an empty cache hit", async () => {
    let now = 1_000
    let calls = 0
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => connection({ integrationId: 20, userId: 1 }),
      searchNotion: async () => { calls += 1; return [] },
    }, {
      now: () => now,
      providerRequestLimits: { perUser: { max: 2, windowMs: 1_000 }, perConnection: { max: 2, windowMs: 1_000 } },
    })
    const input = { peerId: peer, currentUserId: 1, query: "first" }
    await Effect.runPromise(service.search(input))
    const retry = { ...input, query: "second" }
    expect(await Effect.runPromise(service.search(retry).pipe(Effect.flip))).toBeInstanceOf(ExternalResourceProviderFailure)
    now = 2_001
    expect(await Effect.runPromise(service.search(retry))).toEqual([])
    expect(calls).toBe(4)
  })

  test("one user shares the provider budget across personal and space connections", async () => {
    let calls = 0
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => null,
      resolveConnections: async () => [connection({ integrationId: 20, userId: 1 }), {
        ...connection({ integrationId: 30, userId: 1 }), owner: { type: "space", spaceId: 7 },
      }],
      searchNotion: async () => {
        calls += 1
        return [{ id: "page", provider: "notion", kind: "page", title: "Reminders", url: "https://notion.so/page" }]
      },
    }, {
      now: () => 1_000,
      providerRequestLimits: { perUser: { max: 2, windowMs: 60_000 }, perConnection: { max: 120, windowMs: 60_000 } },
    })
    const input = { peerId: peer, currentUserId: 1, query: "Reminders" }
    expect(await Effect.runPromise(service.search(input))).toHaveLength(1)
    expect(calls).toBe(2)
    expect(await Effect.runPromise(service.search({ ...input, query: "Projects" }).pipe(Effect.flip)))
      .toBeInstanceOf(ExternalResourceProviderFailure)
    expect(calls).toBe(2)
  })

  test("an incomplete empty search is retryable rather than a cached no-match", async () => {
    let failPages = true
    let calls = 0
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => connection({ integrationId: 20, userId: 1 }),
      searchNotion: async (_, __, ___, object) => {
        calls += 1
        if (object === "page" && failPages) throw new Error("timeout")
        return []
      },
    })
    const input = { peerId: peer, currentUserId: 1, query: "Reminders" }
    expect(await Effect.runPromise(service.search(input).pipe(Effect.flip))).toBeInstanceOf(ExternalResourceProviderFailure)
    failPages = false
    expect(await Effect.runPromise(service.search(input))).toEqual([])
    expect(calls).toBe(3)
  })

  test("rejects an excessive limit in the typed error channel", async () => {
    const service = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => connection({ integrationId: 20, userId: 1 }),
      searchNotion: async () => [],
    })
    const error = await Effect.runPromise(
      service.search({
        peerId: peer,
        currentUserId: 1,
        query: "roadmap",
        limit: 100,
      }).pipe(Effect.flip),
    )
    expect(error).toBeInstanceOf(ExternalResourceInputError)
  })

  test("keeps access and provider failures distinct", async () => {
    const accessService = makeExternalResourceSearch({
      resolveSpaceId: async () => {
        throw new Error("denied")
      },
      resolveConnection: async () => connection({ integrationId: 20, userId: 1 }),
      searchNotion: async () => [],
    })
    const accessError = await Effect.runPromise(
      accessService.search({
        peerId: peer,
        currentUserId: 1,
        query: "roadmap",
      }).pipe(Effect.flip),
    )
    expect(accessError).toBeInstanceOf(ExternalResourceAccessFailure)

    const providerService = makeExternalResourceSearch({
      resolveSpaceId: async () => 7,
      resolveConnection: async () => connection({ integrationId: 20, userId: 1 }),
      searchNotion: async () => {
        throw new Error("provider unavailable")
      },
    })
    const providerError = await Effect.runPromise(
      providerService.search({
        peerId: peer,
        currentUserId: 1,
        query: "roadmap",
      }).pipe(Effect.flip),
    )
    expect(providerError).toBeInstanceOf(ExternalResourceProviderFailure)
  })
})

function connection(input: {
  integrationId: number
  userId: number
}): IntegrationAuthToken {
  return {
    provider: "notion",
    accessToken: "notion-token",
    integrationId: input.integrationId,
    owner: { type: "user", userId: input.userId },
  }
}
