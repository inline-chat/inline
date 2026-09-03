import { describe, expect, it } from "bun:test"
import type { ResolvedCampaignRecipient } from "./types"
import {
  createCampaignTimeZoneResolver,
  filterCampaignRecipientsByTimeZone,
  summarizeCampaignTimeZones,
} from "./timeZones"

const at = new Date("2026-01-15T12:00:00.000Z")
const recipient = (
  emailKey: string,
  timeZone: string | null,
): ResolvedCampaignRecipient => ({
  email: `${emailKey}@example.com`,
  name: null,
  emailKey,
  sources: ["waitlist"],
  joinedAt: null,
  timeZone,
})

describe("campaign time-zone windows", () => {
  it("groups recipients by their current UTC offset", () => {
    const resolve = createCampaignTimeZoneResolver(at)

    expect(resolve("America/Sao_Paulo")).toMatchObject({
      utcOffsetMinutes: -180,
      group: "americas",
    })
    expect(resolve("Europe/London")).toMatchObject({
      utcOffsetMinutes: 0,
      group: "europe_africa",
    })
    expect(resolve("Asia/Tokyo")).toMatchObject({
      utcOffsetMinutes: 540,
      group: "asia_oceania",
    })
    expect(resolve("Etc/GMT+2")?.group).toBe("americas")
    expect(resolve("Etc/GMT+1")?.group).toBe("europe_africa")
    expect(resolve("Etc/GMT-4")?.group).toBe("europe_africa")
    expect(resolve("Etc/GMT-5")?.group).toBe("asia_oceania")
    expect(resolve("Invalid/Zone")).toBeNull()
  })

  it("uses daylight-saving-aware offsets", () => {
    expect(createCampaignTimeZoneResolver(at)("America/New_York")?.utcOffsetMinutes)
      .toBe(-300)
    expect(createCampaignTimeZoneResolver(
      new Date("2026-07-15T12:00:00.000Z"),
    )("America/New_York")?.utcOffsetMinutes).toBe(-240)
  })

  it("filters a time-zone window before the caller applies its cohort limit", () => {
    const recipients = [
      recipient("tokyo", "Asia/Tokyo"),
      recipient("invalid", "Invalid/Zone"),
      recipient("london", "Europe/London"),
      recipient("sao-paulo", "America/Sao_Paulo"),
    ]

    expect(
      filterCampaignRecipientsByTimeZone(
        recipients,
        "americas",
        at,
      ),
    ).toEqual({
      recipients: [recipients[3]!],
      excluded: 3,
    })
    expect(
      filterCampaignRecipientsByTimeZone(recipients, "all", at),
    ).toEqual({ recipients, excluded: 0 })
  })

  it("summarizes coverage and the recipient-weighted average offset", () => {
    expect(summarizeCampaignTimeZones([
      recipient("new-york", "America/New_York"),
      recipient("los-angeles", "America/Los_Angeles"),
      recipient("unknown", null),
    ], at)).toEqual({
      known: 2,
      unknown: 1,
      averageUtcOffsetMinutes: -390,
      groups: {
        americas: 2,
        europeAfrica: 0,
        asiaOceania: 0,
      },
    })
  })
})
