import { ListSuppressedDestinationsCommand } from "@aws-sdk/client-sesv2"
import { db } from "@in/server/db"
import { emailSuppressions } from "@in/server/db/schema"
import { resend } from "@in/server/libs/resend"
import { sesClient } from "@in/server/libs/ses"
import {
  emailContactKey,
  encryptCampaignString,
} from "./contactCrypto"
import { campaignEmailQuality } from "./emailQuality"

export type CampaignEmailProvider = "resend" | "ses"
type SuppressionReason = "bounce" | "complaint" | "manual"

interface ProviderSuppression {
  readonly email: string
  readonly reason: SuppressionReason
}

const MAX_PROVIDER_SUPPRESSIONS = 50_000
const CACHE_DURATION_MS = 5 * 60_000
const lastSuccessfulSync = new Map<CampaignEmailProvider, number>()
const inFlightSync = new Map<CampaignEmailProvider, Promise<number>>()

const fetchSesSuppressions = async (): Promise<readonly ProviderSuppression[]> => {
  const suppressions: ProviderSuppression[] = []
  let nextToken: string | undefined
  do {
    const page = await sesClient.send(new ListSuppressedDestinationsCommand({
      NextToken: nextToken,
      PageSize: 1_000,
      Reasons: ["BOUNCE", "COMPLAINT"],
    }))
    for (const destination of page.SuppressedDestinationSummaries ?? []) {
      if (!destination.EmailAddress || !destination.Reason) continue
      suppressions.push({
        email: destination.EmailAddress,
        reason: destination.Reason === "COMPLAINT" ? "complaint" : "bounce",
      })
    }
    if (suppressions.length > MAX_PROVIDER_SUPPRESSIONS) {
      throw new Error(`SES suppression list exceeds ${MAX_PROVIDER_SUPPRESSIONS} entries`)
    }
    nextToken = page.NextToken
  } while (nextToken)
  return suppressions
}

const fetchResendSuppressions = async (): Promise<readonly ProviderSuppression[]> => {
  const suppressions: ProviderSuppression[] = []
  let after: string | undefined
  while (true) {
    const page = await resend.suppressions.list({ limit: 100, ...(after ? { after } : {}) })
    if (page.error || !page.data) throw page.error ?? new Error("Resend did not return suppressions")
    suppressions.push(...page.data.data.map((entry) => ({
      email: entry.email,
      reason: entry.origin,
    })))
    if (suppressions.length > MAX_PROVIDER_SUPPRESSIONS) {
      throw new Error(`Resend suppression list exceeds ${MAX_PROVIDER_SUPPRESSIONS} entries`)
    }
    const last = page.data.data.at(-1)
    if (!page.data.has_more || !last) break
    after = last.id
  }
  return suppressions
}

export const persistProviderSuppressions = async (
  suppressions: readonly ProviderSuppression[],
): Promise<number> => {
  const values = suppressions.flatMap((suppression) => {
    const quality = campaignEmailQuality(suppression.email)
    if (!quality.valid) return []
    return [{
      emailKey: emailContactKey(quality.email),
      emailEncrypted: encryptCampaignString(quality.email),
      reason: suppression.reason,
    }]
  })
  let inserted = 0
  for (let index = 0; index < values.length; index += 500) {
    const rows = await db
      .insert(emailSuppressions)
      .values(values.slice(index, index + 500))
      .onConflictDoNothing({ target: emailSuppressions.emailKey })
      .returning({ id: emailSuppressions.id })
    inserted += rows.length
  }
  return inserted
}

const performSync = async (provider: CampaignEmailProvider): Promise<number> => {
  const suppressions = provider === "ses"
    ? await fetchSesSuppressions()
    : await fetchResendSuppressions()
  const inserted = await persistProviderSuppressions(suppressions)
  lastSuccessfulSync.set(provider, Date.now())
  return inserted
}

export const syncProviderSuppressions = async (
  provider: CampaignEmailProvider,
  options: { readonly force?: boolean } = {},
): Promise<number> => {
  const lastSync = lastSuccessfulSync.get(provider)
  if (!options.force && lastSync !== undefined && Date.now() - lastSync < CACHE_DURATION_MS) return 0
  const existing = inFlightSync.get(provider)
  if (existing) return existing
  const operation = performSync(provider).finally(() => inFlightSync.delete(provider))
  inFlightSync.set(provider, operation)
  return operation
}
