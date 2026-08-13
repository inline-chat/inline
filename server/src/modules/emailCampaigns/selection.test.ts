import { describe, expect, it } from "bun:test"
import { orderCampaignRecipients } from "./selection"
import type { ResolvedCampaignRecipient } from "./types"

const recipient = (
  emailKey: string,
  joinedAt: string | null,
): ResolvedCampaignRecipient => ({
  email: `${emailKey}@example.com`,
  name: null,
  emailKey,
  sources: ["waitlist"],
  joinedAt: joinedAt ? new Date(joinedAt) : null,
})

const recipients = [
  recipient("middle", "2026-08-02T00:00:00.000Z"),
  recipient("oldest", "2026-08-01T00:00:00.000Z"),
  recipient("unknown", null),
  recipient("newest", "2026-08-03T00:00:00.000Z"),
]

describe("campaign recipient selection order", () => {
  it("selects newest and oldest signups chronologically with unknown dates last", () => {
    expect(orderCampaignRecipients(recipients, "newest", "unused").map(({ emailKey }) => emailKey))
      .toEqual(["newest", "middle", "oldest", "unknown"])
    expect(orderCampaignRecipients(recipients, "oldest", "unused").map(({ emailKey }) => emailKey))
      .toEqual(["oldest", "middle", "newest", "unknown"])
  })

  it("keeps random selection deterministic for an unchanged seed", () => {
    const first = orderCampaignRecipients(recipients, "random", "launch-v1")
      .map(({ emailKey }) => emailKey)
    const second = orderCampaignRecipients([...recipients].reverse(), "random", "launch-v1")
      .map(({ emailKey }) => emailKey)
    expect(second).toEqual(first)
  })
})
