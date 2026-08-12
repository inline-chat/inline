import { describe, expect, test } from "bun:test"
import type { SearchExternalResourcesInput } from "@inline-chat/protocol/core"
import { searchExternalResources } from "./externalResources.search"

describe("searchExternalResources", () => {
  test("returns an empty result for bots before resolving integrations", async () => {
    const input: SearchExternalResourcesInput = { query: "roadmap" }
    const result = await searchExternalResources(input, {
      userId: 1,
      sessionId: 1,
      connectionId: "test",
      isBot: true,
      sendRaw() {},
      sendRpcReply() {},
    })

    expect(result).toEqual({ resources: [] })
  })
})
