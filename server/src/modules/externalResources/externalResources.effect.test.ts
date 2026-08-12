import { describe, expect, test } from "bun:test"
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

const peer: InputPeer = {
  type: {
    oneofKind: "chat",
    chat: { chatId: 42n },
  },
}

describe("ExternalResourceSearch", () => {
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
      limit: 6,
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
    expect(providerCalls).toEqual([20, 30])
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
          id: "duplicate",
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
          perUser: { max: 1, windowMs: 60_000 },
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
    }))).toEqual([])
    expect(providerCalls).toBe(1)
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
