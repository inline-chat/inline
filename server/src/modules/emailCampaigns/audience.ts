import {
  and,
  eq,
  inArray,
  isNotNull,
  isNull,
  max,
  or,
  sql,
} from "drizzle-orm"
import { createHash } from "node:crypto"
import { db } from "@in/server/db"
import {
  emailCampaignRecipients,
  emailSuppressions,
  sessions,
  users,
  waitlist,
} from "@in/server/db/schema"
import {
  emailContactKey,
} from "./contactCrypto"
import { campaignEmailQuality } from "./emailQuality"
import type {
  CampaignAudiencePreview,
  EmailCampaignAudience,
  EmailCampaignSource,
  ResolvedCampaignRecipient,
} from "./types"

const MAX_SOURCE_ROWS = 25_000

interface Candidate {
  readonly email: string
  readonly name: string | null
  readonly verified: boolean
  readonly joinedAt: Date | null
  readonly lastActive: Date | null
  readonly platforms: readonly string[]
  readonly source: EmailCampaignSource | "manual"
}

const dateBoundary = (value: string | undefined): Date | undefined => {
  if (!value) return undefined
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? undefined : date
}

const loadInlineCandidates = async (): Promise<readonly Candidate[]> => {
  const rows = await db
    .select({
      email: users.email,
      name: users.firstName,
      verified: users.emailVerified,
      joinedAt: users.date,
      lastActive: max(sessions.lastActive),
      platforms: sql<string[]>`coalesce(array_remove(array_agg(distinct ${sessions.clientType}), null), '{}')`,
    })
    .from(users)
    .leftJoin(sessions, eq(sessions.userId, users.id))
    .where(
      and(
        isNotNull(users.email),
        or(isNull(users.deleted), eq(users.deleted, false)),
        or(isNull(users.bot), eq(users.bot, false)),
      ),
    )
    .groupBy(users.id)
    .limit(MAX_SOURCE_ROWS + 1)

  if (rows.length > MAX_SOURCE_ROWS) {
    throw new Error(`Inline campaign audience exceeds the ${MAX_SOURCE_ROWS} row safety limit`)
  }

  return rows.flatMap((row) =>
    row.email
        ? [{
          email: row.email,
          name: row.name?.trim() || null,
          verified: row.verified === true,
          joinedAt: row.joinedAt,
          lastActive: row.lastActive,
          platforms: row.platforms,
          source: "inline" as const,
        }]
      : [],
  )
}

const loadWaitlistCandidates = async (): Promise<readonly Candidate[]> => {
  const rows = await db
    .select({
      email: waitlist.email,
      name: waitlist.name,
      verified: waitlist.verified,
      joinedAt: waitlist.date,
    })
    .from(waitlist)
    .limit(MAX_SOURCE_ROWS + 1)

  if (rows.length > MAX_SOURCE_ROWS) {
    throw new Error(`Waitlist campaign audience exceeds the ${MAX_SOURCE_ROWS} row safety limit`)
  }

  return rows.map((row) => ({
    email: row.email,
    name: row.name?.trim().split(/\s+/)[0] || null,
    verified: row.verified,
    joinedAt: row.joinedAt,
    lastActive: null,
    platforms: [],
    source: "waitlist" as const,
  }))
}

const deterministicRank = (emailKey: string, seed: string): string =>
  createHash("sha256").update(`${seed}:${emailKey}`).digest("hex")

export const resolveCampaignAudience = async (
  audience: EmailCampaignAudience,
): Promise<CampaignAudiencePreview> => {
  const sourceRows = await Promise.all([
    audience.sources.includes("inline") ? loadInlineCandidates() : [],
    audience.sources.includes("waitlist") ? loadWaitlistCandidates() : [],
  ])
  const candidates: Candidate[] = sourceRows.flat()
  candidates.push(
    ...audience.manualEmails.map((email) => ({
      email,
      name: null,
      verified: true,
      joinedAt: null,
      lastActive: null,
      platforms: [],
      source: "manual" as const,
    })),
  )

  const excluded = {
    invalid: 0,
    typo: 0,
    unverified: 0,
    inactive: 0,
    platform: 0,
    suppressed: 0,
    priorCampaign: 0,
    duplicate: 0,
    limited: 0,
  }
  const joinedAfter = dateBoundary(audience.joinedAfter)
  const joinedBefore = dateBoundary(audience.joinedBefore)
  const activityCutoff = audience.activeWithinDays
    ? new Date(Date.now() - audience.activeWithinDays * 86_400_000)
    : undefined
  const byKey = new Map<string, ResolvedCampaignRecipient>()

  for (const candidate of candidates) {
    const quality = campaignEmailQuality(candidate.email)
    if (!quality.valid) {
      excluded[quality.reason] += 1
      continue
    }
    const email = quality.email
    if (audience.verifiedOnly && !candidate.verified) {
      excluded.unverified += 1
      continue
    }
    if (
      candidate.source !== "manual" &&
      joinedAfter &&
      (!candidate.joinedAt || candidate.joinedAt < joinedAfter)
    ) {
      continue
    }
    if (
      candidate.source !== "manual" &&
      joinedBefore &&
      (!candidate.joinedAt || candidate.joinedAt > joinedBefore)
    ) {
      continue
    }
    if (
      candidate.source === "inline" &&
      activityCutoff &&
      (!candidate.lastActive || candidate.lastActive < activityCutoff)
    ) {
      excluded.inactive += 1
      continue
    }
    if (
      candidate.source === "inline" &&
      audience.platforms.length > 0 &&
      !audience.platforms.some((platform) =>
        candidate.platforms.includes(platform),
      )
    ) {
      excluded.platform += 1
      continue
    }

    const emailKey = emailContactKey(email)
    const existing = byKey.get(emailKey)
    if (existing) {
      excluded.duplicate += 1
      if (!existing.sources.includes(candidate.source)) {
        byKey.set(emailKey, {
          ...existing,
          sources: [...existing.sources, candidate.source],
        })
      }
      continue
    }
    byKey.set(emailKey, {
      email,
      name: candidate.name,
      emailKey,
      sources: [candidate.source],
    })
  }

  const keys = [...byKey.keys()]
  if (keys.length > 0) {
    const [suppressedRows, priorRows] = await Promise.all([
      db
        .select({ emailKey: emailSuppressions.emailKey })
        .from(emailSuppressions)
        .where(inArray(emailSuppressions.emailKey, keys)),
      audience.excludeCampaignIds.length > 0
        ? db
            .selectDistinct({ emailKey: emailCampaignRecipients.emailKey })
            .from(emailCampaignRecipients)
            .where(
              and(
                inArray(emailCampaignRecipients.emailKey, keys),
                inArray(emailCampaignRecipients.campaignId, audience.excludeCampaignIds),
                inArray(emailCampaignRecipients.status, [
                  "sending",
                  "provider_accepted",
                  "unknown",
                ]),
              ),
            )
        : Promise.resolve([]),
    ])
    for (const row of suppressedRows) {
      if (byKey.delete(row.emailKey)) excluded.suppressed += 1
    }
    for (const row of priorRows) {
      if (byKey.delete(row.emailKey)) excluded.priorCampaign += 1
    }
  }

  const ranked = [...byKey.values()].sort((left, right) =>
    deterministicRank(left.emailKey, audience.sampleSeed).localeCompare(
      deterministicRank(right.emailKey, audience.sampleSeed),
    ),
  )
  const limit = audience.limit ?? ranked.length
  excluded.limited = Math.max(0, ranked.length - limit)
  return {
    recipients: ranked.slice(0, limit),
    excluded,
  }
}
