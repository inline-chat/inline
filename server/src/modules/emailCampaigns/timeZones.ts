import type {
  EmailCampaignTimeZoneGroup,
  ResolvedCampaignRecipient,
} from "./types"

export type CampaignTimeZoneWindow = Exclude<
  EmailCampaignTimeZoneGroup,
  "all"
>

export interface CampaignTimeZoneResolution {
  readonly timeZone: string
  readonly utcOffsetMinutes: number
  readonly group: CampaignTimeZoneWindow
}

const timeZoneGroupForOffset = (
  utcOffsetMinutes: number,
): CampaignTimeZoneWindow => {
  if (utcOffsetMinutes <= -120) return "americas"
  if (utcOffsetMinutes < 300) return "europe_africa"
  return "asia_oceania"
}

export const createCampaignTimeZoneResolver = (
  at: Date = new Date(),
) => {
  const cache = new Map<
    string,
    CampaignTimeZoneResolution | null
  >()

  return (
    value: string | null | undefined,
  ): CampaignTimeZoneResolution | null => {
    const timeZone = value?.trim()
    if (!timeZone) return null
    const cached = cache.get(timeZone)
    if (cached !== undefined || cache.has(timeZone)) {
      return cached ?? null
    }

    try {
      const parts = new Intl.DateTimeFormat("en-US", {
        timeZone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hourCycle: "h23",
      }).formatToParts(at)
      const values = Object.fromEntries(
        parts.map((part) => [part.type, part.value]),
      )
      const localAsUtc = Date.UTC(
        Number(values["year"]),
        Number(values["month"]) - 1,
        Number(values["day"]),
        Number(values["hour"]),
        Number(values["minute"]),
        Number(values["second"]),
      )
      const utcOffsetMinutes = Math.round(
        (localAsUtc - at.getTime()) / 60_000,
      )
      const resolution = {
        timeZone,
        utcOffsetMinutes,
        group: timeZoneGroupForOffset(utcOffsetMinutes),
      }
      cache.set(timeZone, resolution)
      return resolution
    } catch {
      cache.set(timeZone, null)
      return null
    }
  }
}

export const filterCampaignRecipientsByTimeZone = (
  recipients: readonly ResolvedCampaignRecipient[],
  group: EmailCampaignTimeZoneGroup,
  at: Date = new Date(),
): {
  readonly recipients: readonly ResolvedCampaignRecipient[]
  readonly excluded: number
} => {
  if (group === "all") return { recipients, excluded: 0 }
  const resolveTimeZone = createCampaignTimeZoneResolver(at)
  const selected = recipients.filter(
    (recipient) => resolveTimeZone(recipient.timeZone)?.group === group,
  )
  return {
    recipients: selected,
    excluded: recipients.length - selected.length,
  }
}

export const summarizeCampaignTimeZones = (
  recipients: readonly ResolvedCampaignRecipient[],
  at: Date = new Date(),
) => {
  const groups = {
    americas: 0,
    europeAfrica: 0,
    asiaOceania: 0,
  }
  const resolveTimeZone = createCampaignTimeZoneResolver(at)
  let known = 0
  let totalUtcOffsetMinutes = 0

  for (const recipient of recipients) {
    const resolution = resolveTimeZone(recipient.timeZone)
    if (!resolution) continue
    known += 1
    totalUtcOffsetMinutes += resolution.utcOffsetMinutes
    if (resolution.group === "americas") groups.americas += 1
    if (resolution.group === "europe_africa") groups.europeAfrica += 1
    if (resolution.group === "asia_oceania") groups.asiaOceania += 1
  }

  return {
    known,
    unknown: recipients.length - known,
    averageUtcOffsetMinutes:
      known === 0
        ? null
        : Math.round(totalUtcOffsetMinutes / known),
    groups,
  }
}
