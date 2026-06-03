import { isIP } from "node:net"

export type UrlBlockReason =
  | "blocked_host"
  | "blocked_ip"
  | "sensitive_query"
  | "sensitive_path"

export type UrlFilterResult = { ok: true } | { ok: false; reason: UrlBlockReason }

// These services commonly put private workspace/project identifiers behind auth.
// Expanding this list is intentionally low-risk: blocked URLs simply do not get fetched by Inline.
const protectedHostSuffixes = [
  "sentry.io",
  "linear.app",
  "app.notion.com",
  "notion.so",
  "notion.site",
  "1password.com",
  "1password.eu",
  "1password.ca",
]

const localHostSuffixes = [".localhost", ".local", ".internal", ".home.arpa"]

const sensitiveQueryKeys = new Set([
  "access-token",
  "auth-token",
  "bearer",
  "challenge",
  "client-secret",
  "code",
  "confirmation",
  "email-token",
  "id-token",
  "invite",
  "invitation",
  "jwt",
  "key",
  "magic",
  "nonce",
  "otp",
  "passcode",
  "password",
  "recovery",
  "refresh-token",
  "reset",
  "secret",
  "session",
  "signature",
  "sso",
  "ticket",
  "token",
  "verify",
  "verification",
])

const sensitiveQueryTokens = new Set([
  "auth",
  "bearer",
  "challenge",
  "code",
  "confirmation",
  "invite",
  "invitation",
  "jwt",
  "key",
  "magic",
  "nonce",
  "oauth",
  "oauth2",
  "oidc",
  "otp",
  "passcode",
  "password",
  "recovery",
  "reset",
  "secret",
  "session",
  "signature",
  "sso",
  "saml",
  "ticket",
  "token",
  "verify",
  "verification",
])

const sensitivePathSegments = new Set([
  "activate",
  "activation",
  "auth",
  "authorize",
  "callback",
  "confirm",
  "confirmation",
  "email-verification",
  "forgot-password",
  "invite",
  "invitation",
  "login",
  "magic-link",
  "oauth",
  "oauth2",
  "oidc",
  "password",
  "password-reset",
  "recover",
  "recovery",
  "register",
  "reset",
  "reset-password",
  "sign-in",
  "sign-up",
  "signup",
  "signin",
  "saml",
  "verify",
  "verify-email",
  "verification",
])

const sensitivePathTokens = new Set([
  "activate",
  "activation",
  "auth",
  "authorize",
  "callback",
  "confirm",
  "confirmation",
  "invite",
  "invitation",
  "login",
  "magic",
  "oauth",
  "oauth2",
  "oidc",
  "password",
  "recover",
  "recovery",
  "register",
  "reset",
  "saml",
  "signin",
  "signup",
  "verify",
  "verification",
])

const safeQueryKeys = new Set([
  "ab_channel",
  "feature",
  "list",
  "pp",
  "start",
  "t",
  "time_continue",
  "v",
])

export function filterPreviewUrl(url: URL): UrlFilterResult {
  const hostname = stripIpv6Brackets(url.hostname).toLowerCase()
  if (isBlockedHostname(hostname)) {
    return { ok: false, reason: "blocked_host" }
  }

  if (isIP(hostname) !== 0 && isBlockedIp(hostname)) {
    return { ok: false, reason: "blocked_ip" }
  }

  if (hasSensitiveQuery(url)) {
    return { ok: false, reason: "sensitive_query" }
  }

  if (hasSensitivePath(url)) {
    return { ok: false, reason: "sensitive_path" }
  }

  return { ok: true }
}

export function isBlockedHostname(hostname: string): boolean {
  const host = stripIpv6Brackets(hostname).toLowerCase()
  return (
    host === "localhost" ||
    localHostSuffixes.some((suffix) => host.endsWith(suffix)) ||
    protectedHostSuffixes.some((suffix) => host === suffix || host.endsWith(`.${suffix}`))
  )
}

export function isBlockedIp(ip: string): boolean {
  const normalized = stripIpv6Brackets(ip).toLowerCase()
  const version = isIP(normalized)
  if (version === 4) {
    return isBlockedIpv4(normalized)
  }
  if (version === 6) {
    return isBlockedIpv6(normalized)
  }
  return true
}

function hasSensitiveQuery(url: URL): boolean {
  for (const [key, value] of url.searchParams) {
    const normalizedKey = normalizeToken(key)
    const normalizedValue = value.trim()
    if (!normalizedKey || !normalizedValue || safeQueryKeys.has(normalizedKey)) {
      continue
    }

    if (sensitiveQueryKeys.has(normalizedKey)) {
      return true
    }

    if (tokenParts(normalizedKey).some((part) => sensitiveQueryTokens.has(part))) {
      return true
    }
  }
  return false
}

function hasSensitivePath(url: URL): boolean {
  const segments = url.pathname
    .split("/")
    .map((segment) => normalizeToken(decodeURIComponentSafe(segment)))
    .filter(Boolean)

  return segments.some((segment) => {
    if (sensitivePathSegments.has(segment)) {
      return true
    }

    return tokenParts(segment).some((part) => sensitivePathTokens.has(part))
  })
}

function normalizeToken(value: string): string {
  return value.trim().replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase().replaceAll("_", "-")
}

function tokenParts(value: string): string[] {
  return value.split(/[^a-z0-9]+/).filter(Boolean)
}

function decodeURIComponentSafe(value: string): string {
  try {
    return decodeURIComponent(value)
  } catch {
    return value
  }
}

function isBlockedIpv4(ip: string): boolean {
  const parts = parseIpv4Parts(ip)
  if (!parts) {
    return true
  }

  const value = ((parts[0]! << 24) | (parts[1]! << 16) | (parts[2]! << 8) | parts[3]!) >>> 0
  return (
    inCidr(value, "0.0.0.0", 8) ||
    inCidr(value, "10.0.0.0", 8) ||
    inCidr(value, "100.64.0.0", 10) ||
    inCidr(value, "127.0.0.0", 8) ||
    inCidr(value, "169.254.0.0", 16) ||
    inCidr(value, "172.16.0.0", 12) ||
    inCidr(value, "192.0.0.0", 24) ||
    inCidr(value, "192.0.2.0", 24) ||
    inCidr(value, "192.168.0.0", 16) ||
    inCidr(value, "198.18.0.0", 15) ||
    inCidr(value, "198.51.100.0", 24) ||
    inCidr(value, "203.0.113.0", 24) ||
    inCidr(value, "224.0.0.0", 4) ||
    inCidr(value, "240.0.0.0", 4)
  )
}

function isBlockedIpv6(ip: string): boolean {
  const bytes = parseIpv6Bytes(ip)
  if (!bytes) {
    return true
  }

  if ((bytes.every((byte) => byte === 0)) || (bytes.slice(0, 15).every((byte) => byte === 0) && bytes[15] === 1)) {
    return true
  }

  if (isIpv4Mapped(bytes)) {
    return isBlockedIpv4(`${bytes[12]}.${bytes[13]}.${bytes[14]}.${bytes[15]}`)
  }

  return (
    (bytes[0]! & 0xfe) === 0xfc ||
    (bytes[0] === 0xfe && (bytes[1]! & 0xc0) === 0x80) ||
    bytes[0] === 0xff ||
    (bytes[0] === 0x20 && bytes[1] === 0x01 && bytes[2] === 0x0d && bytes[3] === 0xb8) ||
    (bytes[0] === 0x20 && bytes[1] === 0x01 && bytes[2] === 0x00 && bytes[3] === 0x00) ||
    (bytes[0] === 0x20 && bytes[1] === 0x02) ||
    (bytes[0] === 0x01 && bytes.slice(1, 8).every((byte) => byte === 0)) ||
    (bytes[0] === 0x20 && bytes[1] === 0x01 && bytes[2] === 0x00 && bytes[3] === 0x02)
  )
}

function parseIpv6Bytes(ip: string): Uint8Array | null {
  const value = stripIpv6Brackets(ip).toLowerCase().split("%")[0]
  if (!value || value.includes(":::")) {
    return null
  }

  const parts = value.split("::")
  if (parts.length > 2) {
    return null
  }

  const head = parseIpv6Words(parts[0] ?? "")
  const tail = parts.length === 2 ? parseIpv6Words(parts[1] ?? "") : []
  if (!head || !tail) {
    return null
  }

  const missing = 8 - head.length - tail.length
  if ((parts.length === 1 && missing !== 0) || missing < 0) {
    return null
  }

  const words = [...head, ...Array<number>(missing).fill(0), ...tail]
  const bytes = new Uint8Array(16)
  words.forEach((word, index) => {
    bytes[index * 2] = (word >> 8) & 0xff
    bytes[index * 2 + 1] = word & 0xff
  })
  return bytes
}

function parseIpv6Words(input: string): number[] | null {
  if (input === "") {
    return []
  }

  const words: number[] = []
  const segments = input.split(":")
  for (const segment of segments) {
    if (segment.includes(".")) {
      const ipv4 = parseIpv4Parts(segment)
      if (!ipv4) {
        return null
      }
      words.push((ipv4[0]! << 8) | ipv4[1]!, (ipv4[2]! << 8) | ipv4[3]!)
      continue
    }

    if (!/^[0-9a-f]{1,4}$/.test(segment)) {
      return null
    }
    words.push(Number.parseInt(segment, 16))
  }

  return words
}

function parseIpv4Parts(ip: string): number[] | null {
  const parts = ip.split(".").map((part) => Number(part))
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return null
  }
  return parts
}

function isIpv4Mapped(bytes: Uint8Array): boolean {
  return bytes.slice(0, 10).every((byte) => byte === 0) && bytes[10] === 0xff && bytes[11] === 0xff
}

function inCidr(value: number, baseIp: string, prefix: number): boolean {
  const base = ipv4ToNumber(baseIp)
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0
  return (value & mask) === (base & mask)
}

function ipv4ToNumber(ip: string): number {
  const parts = ip.split(".").map((part) => Number(part))
  return ((parts[0]! << 24) | (parts[1]! << 16) | (parts[2]! << 8) | parts[3]!) >>> 0
}

export function stripIpv6Brackets(hostname: string): string {
  return hostname.startsWith("[") && hostname.endsWith("]") ? hostname.slice(1, -1) : hostname
}
