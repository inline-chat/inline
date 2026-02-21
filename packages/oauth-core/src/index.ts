const LOCAL_DEV_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"])

export const MCP_SUPPORTED_SCOPES = ["offline_access", "messages:read", "messages:write", "spaces:read"] as const
export type McpSupportedScope = (typeof MCP_SUPPORTED_SCOPES)[number]

const MCP_SUPPORTED_SCOPE_SET = new Set<string>(MCP_SUPPORTED_SCOPES)

export const MCP_DEFAULT_SCOPE = "messages:read spaces:read"

export function normalizeScopes(scope: string): string {
  const out: string[] = []
  const seen = new Set<string>()

  for (const part of scope.split(/\s+/)) {
    const value = part.trim()
    if (!value || seen.has(value) || !MCP_SUPPORTED_SCOPE_SET.has(value)) {
      continue
    }
    seen.add(value)
    out.push(value)
  }

  if (out.length === 0) {
    return MCP_DEFAULT_SCOPE
  }

  return out.join(" ")
}

export function hasScope(scope: string, needed: string): boolean {
  return scope
    .split(/\s+/)
    .map((value) => value.trim())
    .filter(Boolean)
    .includes(needed)
}

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase()
}

export function normalizeRateLimitKeyPart(value: string): string {
  const normalized = value.trim().toLowerCase()
  if (!normalized) return "unknown"
  return normalized.slice(0, 200)
}

export function isAllowedRedirectUri(uri: string): boolean {
  let parsed: URL
  try {
    parsed = new URL(uri)
  } catch {
    return false
  }

  if (parsed.protocol === "https:") {
    return true
  }

  if (parsed.protocol !== "http:") {
    return false
  }

  return LOCAL_DEV_HOSTS.has(parsed.hostname)
}

export function base64UrlEncode(bytes: Uint8Array): string {
  return Buffer.from(bytes)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "")
}

export function base64UrlDecode(input: string): Uint8Array {
  const padded = input.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((input.length + 3) % 4)
  return new Uint8Array(Buffer.from(padded, "base64"))
}

export async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest("SHA-256", data)
  const bytes = new Uint8Array(digest)
  let out = ""
  for (const byte of bytes) {
    out += byte.toString(16).padStart(2, "0")
  }
  return out
}

export async function sha256Base64Url(input: string): Promise<string> {
  const data = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest("SHA-256", data)
  return base64UrlEncode(new Uint8Array(digest))
}

export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false

  let mismatch = 0
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i)
  }
  return mismatch === 0
}

export function createRandomToken(prefix: string, randomBytesLength = 32): string {
  const normalizedPrefix = prefix.trim()
  if (!normalizedPrefix) {
    throw new Error("token prefix is required")
  }

  const size = Math.max(16, Math.min(256, Math.trunc(randomBytesLength)))
  return `${normalizedPrefix}_${base64UrlEncode(crypto.getRandomValues(new Uint8Array(size)))}`
}
