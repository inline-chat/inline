import { describe, expect, it } from "vitest"
import { InlineBroadcastCoreRegistry } from "./InlineBroadcastCoreRegistry"
import { InlineLocalCoreRegistry } from "./InlineLocalCoreRegistry"

describe("InlineLocalCoreRegistry", () => {
  it("keeps the compatibility name on the broadcast-backed registry", () => {
    const registry = new InlineLocalCoreRegistry()
    expect(registry).toBeInstanceOf(InlineBroadcastCoreRegistry)
  })
})
