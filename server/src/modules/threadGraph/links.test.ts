import { describe, expect, it } from "bun:test"
import { graphScopeFromChat } from "./links"

describe("graphScopeFromChat", () => {
  it("uses space scope for space chats", () => {
    expect(graphScopeFromChat({ id: 1, title: "Source", spaceId: 10, createdBy: 20 })).toEqual({
      type: "space",
      id: 10,
    })
  })

  it("uses user scope for home chats", () => {
    expect(graphScopeFromChat({ id: 1, title: "Source", spaceId: null, createdBy: 20 })).toEqual({
      type: "user",
      id: 20,
    })
  })

  it("requires a scope source", () => {
    expect(() => graphScopeFromChat({ id: 1, title: "Source", spaceId: null, createdBy: null })).toThrow()
  })
})
