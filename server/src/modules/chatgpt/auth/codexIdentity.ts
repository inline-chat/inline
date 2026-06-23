type CodexJwtPayload = {
  exp?: unknown
  iss?: unknown
  sub?: unknown
  "https://api.openai.com/profile"?: {
    email?: unknown
  }
  "https://api.openai.com/auth"?: {
    chatgpt_account_id?: unknown
    chatgpt_account_user_id?: unknown
    chatgpt_plan_type?: unknown
    chatgpt_user_id?: unknown
    user_id?: unknown
  }
}

export type CodexIdentity = {
  readonly accountId?: string
  readonly chatgptPlanType?: string
  readonly email?: string
  readonly profileName?: string
}

export function resolveCodexAccessTokenExpiry(accessToken: string): number | undefined {
  const payload = decodeCodexJwtPayload(accessToken)
  const exp = normalizeFutureEpochSeconds(payload?.exp)
  return exp ? exp * 1000 : undefined
}

export function resolveCodexAuthIdentity(input: { readonly accessToken: string; readonly email?: string | null }): CodexIdentity {
  const payload = decodeCodexJwtPayload(input.accessToken)
  const auth = payload?.["https://api.openai.com/auth"]
  const accountId = trimString(auth?.chatgpt_account_id)
  const chatgptPlanType = trimString(auth?.chatgpt_plan_type)
  const email = trimString(payload?.["https://api.openai.com/profile"]?.email) ?? trimString(input.email)

  const metadata = {
    ...(accountId ? { accountId } : {}),
    ...(chatgptPlanType ? { chatgptPlanType } : {}),
  }

  if (email) {
    return { ...metadata, email, profileName: email }
  }

  const stableSubject = resolveCodexStableSubject(payload)
  if (!stableSubject) {
    return metadata
  }

  return {
    ...metadata,
    profileName: `id-${Buffer.from(stableSubject).toString("base64url")}`,
  }
}

function decodeCodexJwtPayload(accessToken: string): CodexJwtPayload | null {
  const parts = accessToken.split(".")
  if (parts.length !== 3 || !parts[1]) {
    return null
  }

  try {
    const decoded = Buffer.from(parts[1], "base64url").toString("utf8")
    const parsed: unknown = JSON.parse(decoded)
    return parsed && typeof parsed === "object" ? (parsed as CodexJwtPayload) : null
  } catch {
    return null
  }
}

function resolveCodexStableSubject(payload: CodexJwtPayload | null): string | undefined {
  const auth = payload?.["https://api.openai.com/auth"]
  const accountUserId = trimString(auth?.chatgpt_account_user_id)
  if (accountUserId) {
    return accountUserId
  }

  const userId = trimString(auth?.chatgpt_user_id) ?? trimString(auth?.user_id)
  if (userId) {
    return userId
  }

  const iss = trimString(payload?.iss)
  const sub = trimString(payload?.sub)
  if (iss && sub) {
    return `${iss}|${sub}`
  }

  return sub
}

function normalizeFutureEpochSeconds(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return Math.trunc(value)
  }
  if (typeof value === "string" && /^\d+$/.test(value.trim())) {
    return Number.parseInt(value.trim(), 10)
  }
  return undefined
}

function trimString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined
}
