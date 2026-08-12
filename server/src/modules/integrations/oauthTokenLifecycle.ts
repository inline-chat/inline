import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrations } from "@in/server/db/schema"
import { decrypt, encrypt } from "@in/server/modules/encryption/encryption"
import { connectorOAuthCredentials } from "./connectorOAuthCredentials"

export type RefreshableOAuthProvider = "linear" | "notion"

export interface StoredOAuthIntegration {
  readonly id: number
  readonly provider: string
  readonly date: Date
  readonly accessTokenEncrypted: Buffer | null
  readonly accessTokenIv: Buffer | null
  readonly accessTokenTag: Buffer | null
}

export interface OAuthTokenLifecycleDependencies {
  readonly refreshTokens: (
    provider: RefreshableOAuthProvider,
    refreshToken: string,
  ) => Promise<OAuthTokenData>
}

export interface OAuthTokenData {
  access_token?: unknown
  refresh_token?: unknown
  expires_in?: unknown
  obtained_at?: unknown
  [key: string]: unknown
}

const REFRESH_MARGIN_SECONDS = 5 * 60
const NOTION_API_VERSION = "2026-03-11"

export async function usableOAuthAccessToken(
  integration: StoredOAuthIntegration,
  dependencies: OAuthTokenLifecycleDependencies = defaultDependencies,
): Promise<string | null> {
  const payload = decryptTokenPayload(integration)
  if (!payload) return null

  const accessToken = stringValue(payload.access_token)
  const obtainedAt = tokenObtainedAt(payload, integration.date)
  if (!shouldRefreshOAuthToken(payload, obtainedAt)) return accessToken

  const provider = refreshableProvider(integration.provider)
  const refreshToken = stringValue(payload.refresh_token)
  if (!provider || !refreshToken) return null

  return await db.transaction(async (tx) => {
    const [latest] = await tx
      .select({
        id: integrations.id,
        provider: integrations.provider,
        date: integrations.date,
        accessTokenEncrypted: integrations.accessTokenEncrypted,
        accessTokenIv: integrations.accessTokenIv,
        accessTokenTag: integrations.accessTokenTag,
      })
      .from(integrations)
      .where(eq(integrations.id, integration.id))
      .for("update")
      .limit(1)
    if (!latest) return null

    const latestPayload = decryptTokenPayload(latest)
    if (!latestPayload) return null
    const latestAccessToken = stringValue(latestPayload.access_token)
    const latestObtainedAt = tokenObtainedAt(latestPayload, latest.date)
    if (!shouldRefreshOAuthToken(latestPayload, latestObtainedAt)) {
      return latestAccessToken
    }

    const latestRefreshToken = stringValue(latestPayload.refresh_token)
    const latestProvider = refreshableProvider(latest.provider)
    if (!latestProvider || !latestRefreshToken) return null

    const refreshed = await dependencies.refreshTokens(
      latestProvider,
      latestRefreshToken,
    )
    const nextPayload = {
      ...latestPayload,
      ...refreshed,
      obtained_at: Math.floor(Date.now() / 1_000),
    }
    const nextAccessToken = stringValue(nextPayload.access_token)
    if (!nextAccessToken) return null

    const encrypted = encrypt(JSON.stringify({ data: nextPayload }))
    await tx
      .update(integrations)
      .set({
        accessTokenEncrypted: encrypted.encrypted,
        accessTokenIv: encrypted.iv,
        accessTokenTag: encrypted.authTag,
      })
      .where(eq(integrations.id, integration.id))
    return nextAccessToken
  })
}

export function shouldRefreshOAuthToken(
  payload: OAuthTokenData,
  obtainedAt: Date,
  now = new Date(),
): boolean {
  if (!stringValue(payload.access_token)) return true
  const expiresIn = numberValue(payload.expires_in)
  if (expiresIn === null) return false
  const refreshAt = obtainedAt.getTime() + Math.max(
    0,
    expiresIn - REFRESH_MARGIN_SECONDS,
  ) * 1_000
  return now.getTime() >= refreshAt
}

function decryptTokenPayload(
  integration: StoredOAuthIntegration,
): OAuthTokenData | null {
  if (
    !integration.accessTokenEncrypted ||
    !integration.accessTokenIv ||
    !integration.accessTokenTag
  ) return null

  const text = decrypt({
    encrypted: integration.accessTokenEncrypted,
    iv: integration.accessTokenIv,
    authTag: integration.accessTokenTag,
  })
  const parsed: unknown = JSON.parse(text)
  const record = objectValue(parsed)
  return objectValue(record?.["data"]) ?? record
}

async function requestRefreshedTokens(
  provider: RefreshableOAuthProvider,
  refreshToken: string,
): Promise<OAuthTokenData> {
  const credentials = oauthCredentials(provider)
  if (!credentials) throw new Error(`${provider} OAuth is not configured`)

  const response = provider === "linear"
    ? await refreshLinear(credentials, refreshToken)
    : await refreshNotion(credentials, refreshToken)
  if (!response.ok) {
    await response.body?.cancel()
    throw new Error(`${provider} OAuth refresh failed with status ${response.status}`)
  }
  const body: unknown = await response.json()
  const tokens = objectValue(body)
  if (!tokens || !stringValue(tokens.access_token)) {
    throw new Error(`${provider} OAuth refresh returned invalid credentials`)
  }
  return tokens
}

function refreshLinear(
  credentials: { clientId: string; clientSecret: string },
  refreshToken: string,
): Promise<Response> {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    client_id: credentials.clientId,
    client_secret: credentials.clientSecret,
  })
  return fetch("https://api.linear.app/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(10_000),
  })
}

function refreshNotion(
  credentials: { clientId: string; clientSecret: string },
  refreshToken: string,
): Promise<Response> {
  const authorization = Buffer.from(
    `${credentials.clientId}:${credentials.clientSecret}`,
    "utf8",
  ).toString("base64")
  return fetch("https://api.notion.com/v1/oauth/token", {
    method: "POST",
    headers: {
      Authorization: `Basic ${authorization}`,
      "Content-Type": "application/json",
      "Notion-Version": NOTION_API_VERSION,
    },
    body: JSON.stringify({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
    }),
    signal: AbortSignal.timeout(10_000),
  })
}

function oauthCredentials(
  provider: RefreshableOAuthProvider,
): { clientId: string; clientSecret: string } | null {
  return connectorOAuthCredentials(provider)
}

function tokenObtainedAt(payload: OAuthTokenData, fallback: Date): Date {
  const seconds = numberValue(payload.obtained_at)
  return seconds === null ? fallback : new Date(seconds * 1_000)
}

const defaultDependencies: OAuthTokenLifecycleDependencies = {
  refreshTokens: requestRefreshedTokens,
}

function refreshableProvider(value: string): RefreshableOAuthProvider | null {
  return value === "linear" || value === "notion" ? value : null
}

function objectValue(value: unknown): OAuthTokenData | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as OAuthTokenData
    : null
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value
    : null
}
