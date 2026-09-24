/** Display-only evidence; never used for authentication or authorization. */
export type SignupAttribution = {
  entryPoint?: "oauth"
  oauthClient?: string
  authMethod?: "email" | "phone" | "google" | "apple"
  referrerHost?: string
  utmSource?: string
  utmMedium?: string
  utmCampaign?: string
}

// Bound untrusted labels and keep each field on one plain-text row.
function label(value: string | null | undefined): string | undefined {
  return value?.replace(/[\p{Cc}\p{Cf}|·`*_[\]<>\\]/gu, " ").replace(/\s+/g, " ").trim().slice(0, 80) || undefined
}

export function captureSignupReferral(url: URL, referrer?: string | null): SignupAttribution {
  let referrerHost: string | undefined
  try {
    const parsed = new URL(referrer ?? "")
    if (parsed.protocol === "https:" || parsed.protocol === "http:") referrerHost = parsed.hostname
  } catch {
    // Referrers are optional; never retain paths, queries, fragments or credentials.
  }
  return {
    referrerHost,
    utmSource: label(url.searchParams.get("utm_source")),
    utmMedium: label(url.searchParams.get("utm_medium")),
    utmCampaign: label(url.searchParams.get("utm_campaign")),
  }
}

export function formatSignupAttribution(input: {
  clientType?: string | null
  clientVersion?: string | null
  ip?: string
  attribution?: SignupAttribution
} = {}): string {
  const evidence = input.attribution
  const client = [label(input.clientType), label(input.clientVersion)].filter(Boolean).join(" ") || "unknown"
  const parts = [`client: ${client}`]
  if (evidence?.entryPoint === "oauth") parts.push(`via: ${label(evidence.oauthClient) ?? "connected app"} OAuth`)
  if (evidence?.authMethod) parts.push(`login: ${evidence.authMethod}`)
  parts.push(`ref: ${label(evidence?.referrerHost) ?? "unknown"}`)
  const campaign = [
    ["source", evidence?.utmSource],
    ["medium", evidence?.utmMedium],
    ["campaign", evidence?.utmCampaign],
  ].flatMap(([key, value]) => {
    const text = label(value)
    return text ? [`${key}=${text}`] : []
  }).join(", ")
  if (campaign) parts.push(`utm: ${campaign}`)
  const ip = label(input.ip)
  if (ip) parts.push(`ip: ${ip}`)
  return parts.join(" · ")
}
