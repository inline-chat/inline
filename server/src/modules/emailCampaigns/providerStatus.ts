import { GetAccountCommand, GetEmailIdentityCommand, type GetAccountCommandOutput } from "@aws-sdk/client-sesv2"
import { RESEND_API_KEY, SES_REGION } from "@in/server/env"
import { sesClient } from "@in/server/libs/ses"

export interface EmailProviderStatus {
  readonly provider: "resend" | "ses"
  readonly region: string | null
  readonly refreshedAt: string
  readonly available: boolean
  readonly statusCode: number | null
  readonly sendingEnabled: boolean | null
  readonly productionAccess: boolean | null
  readonly requestLimit: number | null
  readonly requestRemaining: number | null
  readonly requestResetAt: string | null
  readonly retryAfterSeconds: number | null
  readonly dailyQuota: string | null
  readonly monthlyQuota: string | null
  readonly max24HourSend: number | null
  readonly sentLast24Hours: number | null
  readonly remaining24Hours: number | null
  readonly maxSendRate: number | null
  readonly quotaWindow: "fixed" | "rolling_24_hours" | null
  readonly senderIdentityVerified: boolean | null
}

const numberHeader = (headers: Headers, name: string): number | null => {
  const value = headers.get(name)
  if (value === null) return null
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

const resendStatus = async (): Promise<EmailProviderStatus> => {
  let response: Response
  try {
    response = await fetch("https://api.resend.com/domains?limit=1", {
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "User-Agent": "inline-admin-email-campaigns/1.0",
      },
    })
  } catch {
    return unavailableStatus("resend")
  }
  const resetSeconds = numberHeader(response.headers, "ratelimit-reset")
  return {
    provider: "resend",
    region: null,
    refreshedAt: new Date().toISOString(),
    available: response.ok,
    statusCode: response.status,
    sendingEnabled: response.ok ? true : null,
    productionAccess: null,
    requestLimit: numberHeader(response.headers, "ratelimit-limit"),
    requestRemaining: numberHeader(response.headers, "ratelimit-remaining"),
    requestResetAt: resetSeconds === null
      ? null
      : new Date(Date.now() + resetSeconds * 1_000).toISOString(),
    retryAfterSeconds: numberHeader(response.headers, "retry-after"),
    dailyQuota: response.headers.get("x-resend-daily-quota"),
    monthlyQuota: response.headers.get("x-resend-monthly-quota"),
    max24HourSend: null,
    sentLast24Hours: null,
    remaining24Hours: null,
    maxSendRate: null,
    quotaWindow: "fixed",
    senderIdentityVerified: null,
  }
}

const sesStatus = async (): Promise<EmailProviderStatus> => {
  let account: GetAccountCommandOutput
  try {
    account = await sesClient.send(new GetAccountCommand({}))
  } catch {
    return unavailableStatus("ses")
  }
  const max24HourSend = account.SendQuota?.Max24HourSend ?? null
  const sentLast24Hours = account.SendQuota?.SentLast24Hours ?? null
  const senderIdentity = await sesClient
    .send(new GetEmailIdentityCommand({ EmailIdentity: "inline.chat" }))
    .catch(() => null)
  return {
    provider: "ses",
    region: SES_REGION,
    refreshedAt: new Date().toISOString(),
    available: true,
    statusCode: null,
    sendingEnabled: account.SendingEnabled ?? null,
    productionAccess: account.ProductionAccessEnabled ?? null,
    requestLimit: null,
    requestRemaining: null,
    requestResetAt: null,
    retryAfterSeconds: null,
    dailyQuota: null,
    monthlyQuota: null,
    max24HourSend,
    sentLast24Hours,
    remaining24Hours: max24HourSend === null || sentLast24Hours === null
      ? null
      : Math.max(0, max24HourSend - sentLast24Hours),
    maxSendRate: account.SendQuota?.MaxSendRate ?? null,
    quotaWindow: "rolling_24_hours",
    senderIdentityVerified: senderIdentity?.VerifiedForSendingStatus ?? false,
  }
}

const unavailableStatus = (provider: "resend" | "ses"): EmailProviderStatus => ({
  provider,
  region: provider === "ses" ? SES_REGION : null,
  refreshedAt: new Date().toISOString(),
  available: false,
  statusCode: null,
  sendingEnabled: null,
  productionAccess: null,
  requestLimit: null,
  requestRemaining: null,
  requestResetAt: null,
  retryAfterSeconds: null,
  dailyQuota: null,
  monthlyQuota: null,
  max24HourSend: null,
  sentLast24Hours: null,
  remaining24Hours: null,
  maxSendRate: null,
  quotaWindow: provider === "ses" ? "rolling_24_hours" : "fixed",
  senderIdentityVerified: provider === "ses" ? false : null,
})

export const getEmailProviderStatus = async (
  provider: "resend" | "ses",
): Promise<EmailProviderStatus> =>
  provider === "ses" ? sesStatus() : resendStatus()
