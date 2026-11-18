/**
 * The one link-scheme allowlist for the whole app (web/docs/security.md,
 * "Rendering user content"). Every link the UI renders or opens passes
 * through `safeLink`. Anything it does not return a link for renders as text.
 *
 * Allowed: `http:` and `https:` (no credentials, a host, `//` after the
 * scheme), `mailto:` with one address, `tel:` with a plausible number, and the
 * app's own `inline://` and `in://` deep links. Everything else is refused:
 * `javascript:`, `data:`, `vbscript:`, `file:`, `blob:`, `about:`, `ftp:`,
 * scheme-relative and path-relative links, and any input that carries control
 * characters, interior whitespace, invisible formatting characters or a
 * backslash anywhere.
 *
 * Links into the app itself (`inline://chat/1`, `https://inline.chat/c/1`,
 * `https://app.inline.chat/...`) come back as `kind: "app"` with their parsed
 * parts. This module does not know destinations; the app maps an app link to
 * one with the view package's URL codec (`parseLink(link.href)`).
 *
 * Pure and framework-free. Never throws.
 */

export type WebLink = {
  readonly kind: "web"
  /** Normalized absolute URL (`URL.href`): lowercase scheme and host, IDN hosts in punycode. */
  readonly href: string
  /** Host with port, as the browser will show it. */
  readonly host: string
}

export type MailLink = {
  readonly kind: "mail"
  /** `mailto:` plus the address; any query (subject, body, cc) is dropped. */
  readonly href: string
  readonly address: string
}

export type PhoneLink = {
  readonly kind: "phone"
  /** `tel:` plus the digits, with a leading `+` when the number had one. */
  readonly href: string
  /** The number as written. */
  readonly number: string
}

export type AppLinkForm =
  /** `inline://...` or `in://...` (`InlineDeepLink` in the Apple clients). */
  | "deepLink"
  /** A public `https://inline.chat/{c,s,invite}/...` link. */
  | "public"
  /** A URL on one of the app's own origins (`https://app.inline.chat`). */
  | "app"

export type AppLink = {
  readonly kind: "app"
  readonly form: AppLinkForm
  /** Normalized URL. Hand it to the view package's `parseLink` to get a destination. */
  readonly href: string
  /** Lowercased host: `chat`, `user`, `thread` or `join` for deep links, the web host otherwise. */
  readonly host: string
  /** Decoded, non-empty path segments. */
  readonly path: readonly string[]
  /** Query parameters in order, names as written. */
  readonly query: readonly (readonly [string, string])[]
}

export type SafeLink = WebLink | MailLink | PhoneLink | AppLink
export type SafeLinkKind = SafeLink["kind"]

export type SafeLinkOptions = {
  /**
   * Accept a bare domain such as `example.com/path` and give it `https://`.
   * Used for URL entities, whose visible text is the link.
   */
  readonly bareDomain?: boolean
  /** Origins whose URLs are app links. Defaults to `https://app.inline.chat`. */
  readonly appOrigins?: readonly string[]
  /** Deep-link schemes. Defaults to `inline` and `in`, as the Apple production builds read. */
  readonly appSchemes?: readonly string[]
}

export const MAX_LINK_LENGTH = 8192

export const defaultAppOrigins: readonly string[] = ["https://app.inline.chat"]
export const defaultAppSchemes: readonly string[] = ["inline", "in"]
const publicHost = "inline.chat"
const publicPaths = new Set(["c", "s", "invite"])
const deepLinkHosts = new Set(["user", "chat", "thread", "join"])

/**
 * Characters never allowed anywhere in a link: C0 and C1 controls, space,
 * DEL, no-break and other Unicode spaces, soft hyphen, zero-width and
 * bidirectional formatting characters, line and paragraph separators, the
 * byte order mark, and backslash. The URL parser silently strips tabs and
 * newlines (`java\tscript:`) and maps backslashes to slashes for web URLs, so
 * these are refused rather than cleaned.
 */
// oxlint-disable-next-line no-control-regex -- matching control characters is the point
const forbiddenCharacters = /[\u0000-\u0020\u007f-\u00a0\u00ad\u061c\u115f\u1160\u1680\u17b4\u17b5\u180b-\u180f\u2000-\u200f\u2028-\u202f\u205f-\u206f\u3000\u3164\ufeff\uffa0\ufff0-\ufff8\\]/u

/** Combining grapheme joiner and variation selectors: invisible, and dropped by IDNA mapping. */
const hasInvisibleSelector = (value: string): boolean => {
  for (let i = 0; i < value.length; i += 1) {
    const unit = value.charCodeAt(i)
    if (unit === 0x034f || (unit >= 0xfe00 && unit <= 0xfe0f)) return true
  }
  return false
}

const isForbidden = (value: string): boolean => forbiddenCharacters.test(value) || hasInvisibleSelector(value)

const schemePattern = /^([A-Za-z][A-Za-z0-9+.-]*):/

/**
 * Returns a safe, normalized link for `input`, or `undefined` when the input
 * is not a link the app may render or open. Never throws.
 */
export const safeLink = (input: unknown, options: SafeLinkOptions = {}): SafeLink | undefined => {
  if (typeof input !== "string" || input.length > MAX_LINK_LENGTH) return undefined
  const value = trimSpaces(input)
  if (value.length === 0 || isForbidden(value)) return undefined

  const match = schemePattern.exec(value)
  if (match) {
    const scheme = (match[1] ?? "").toLowerCase()
    const rest = value.slice(scheme.length + 1)
    // `example.com:8080/x` reads as scheme `example.com`; a dotted "scheme"
    // followed by a port is a bare host.
    if (options.bareDomain && scheme.includes(".") && /^\d/.test(rest)) {
      return bareWebLink(value, options)
    }
    switch (scheme) {
      case "http":
      case "https":
        return rest.startsWith("//") ? webLink(value, options) : undefined
      case "mailto":
        return mailLink(rest)
      case "tel":
        return phoneLink(rest)
      default:
        return (options.appSchemes ?? defaultAppSchemes).some((s) => s.toLowerCase() === scheme)
          ? deepLink(value)
          : undefined
    }
  }

  if (value.startsWith("/")) return undefined
  return options.bareDomain ? bareWebLink(value, options) : undefined
}

/** Whether `input` is a link `safeLink` accepts. */
export const isSafeLink = (input: unknown, options?: SafeLinkOptions): boolean =>
  safeLink(input, options) !== undefined

// MARK: - Web

/** The authority between `//` and the first `/`, `?` or `#`. */
const rawAuthority = (value: string): string => {
  const start = value.indexOf("//")
  if (start < 0) return ""
  const after = value.slice(start + 2)
  const end = after.search(/[/?#]/)
  return end < 0 ? after : after.slice(0, end)
}

const parseUrl = (value: string): URL | undefined => {
  try {
    return new URL(value)
  } catch {
    return undefined
  }
}

const decodedSegments = (pathname: string): string[] | undefined => {
  try {
    return pathname
      .split("/")
      .filter((part) => part.length > 0)
      .map((part) => decodeURIComponent(part))
  } catch {
    return undefined
  }
}

const queryEntries = (url: URL): (readonly [string, string])[] => [...url.searchParams].map(([k, v]) => [k, v] as const)

const webLink = (value: string, options: SafeLinkOptions): WebLink | AppLink | undefined => {
  // The parser reads `https:///host` as `https://host/`; the raw authority must be the host.
  const authority = rawAuthority(value)
  if (authority.length === 0 || authority.includes("@")) return undefined
  const url = parseUrl(value)
  if (!url) return undefined
  if (url.protocol !== "http:" && url.protocol !== "https:") return undefined
  if (url.username !== "" || url.password !== "" || url.hostname === "") return undefined

  const origins = options.appOrigins ?? defaultAppOrigins
  const path = decodedSegments(url.pathname)
  if (path && origins.some((origin) => sameOrigin(origin, url.origin))) {
    return appLink("app", url, url.hostname.toLowerCase(), path)
  }
  if (
    path &&
    url.protocol === "https:" &&
    url.hostname.toLowerCase() === publicHost &&
    url.port === "" &&
    publicPaths.has((path[0] ?? "").toLowerCase())
  ) {
    return appLink("public", url, publicHost, path)
  }
  return { kind: "web", href: url.href, host: url.host }
}

const sameOrigin = (configured: string, actual: string): boolean => {
  const url = parseUrl(configured)
  return url !== undefined && url.origin === actual
}

const appLink = (form: AppLinkForm, url: URL, host: string, path: string[]): AppLink => ({
  kind: "app",
  form,
  href: url.href,
  host,
  path,
  query: queryEntries(url),
})

const hostLabel = /^(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?)$/u
const tld = /^(?:\p{L}{2,63}|xn--[a-z0-9-]{1,59})$/iu
const ipv4 = /^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/

/** `example.com`, `www.example.com:8080/a?b#c`, `1.2.3.4/x`. */
const bareWebLink = (value: string, options: SafeLinkOptions): WebLink | AppLink | undefined => {
  const end = value.search(/[/?#]/)
  const authority = end < 0 ? value : value.slice(0, end)
  const portAt = authority.lastIndexOf(":")
  const host = portAt >= 0 ? authority.slice(0, portAt) : authority
  const port = portAt >= 0 ? authority.slice(portAt + 1) : ""
  if (portAt >= 0 && !/^\d{1,5}$/.test(port)) return undefined
  if (host.length === 0 || host.length > 253) return undefined
  if (!ipv4.test(host)) {
    const labels = host.split(".")
    if (labels.length < 2) return undefined
    if (!labels.every((label) => hostLabel.test(label))) return undefined
    if (!tld.test(labels[labels.length - 1] ?? "")) return undefined
  }
  return webLink(`https://${value}`, options)
}

// MARK: - Mail and phone

const mailAddress =
  /^[\p{L}\p{N}.!$&'*+=^_`{|}~-]{1,64}@(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+(?:\p{L}{2,63}|xn--[a-z0-9-]{1,59})$/iu

const mailLink = (rest: string): MailLink | undefined => {
  const raw = rest.split("?")[0] ?? ""
  let address: string
  try {
    address = decodeURIComponent(raw)
  } catch {
    return undefined
  }
  if (address.length > 254 || isForbidden(address) || !mailAddress.test(address)) return undefined
  return { kind: "mail", href: `mailto:${address}`, address }
}

const phoneLink = (rest: string): PhoneLink | undefined => {
  const number = rest.split(/[?;]/)[0] ?? ""
  if (!isPhoneNumberCandidate(number)) return undefined
  const digits = number.replace(/[^\d]/g, "")
  return { kind: "phone", href: `tel:${number.startsWith("+") ? "+" : ""}${digits}`, number }
}

/**
 * The Apple clients' phone rule (`ProcessEntities.isValidPhoneNumberCandidate`):
 * only `+-()` and digits, at most one leading `+`, balanced parentheses, 7 to
 * 15 digits, and at least 10 digits unless a `+` or parenthesis marks it.
 */
export const isPhoneNumberCandidate = (input: string): boolean => {
  const value = input.trim()
  if (value.length === 0 || !/^[+\-()0-9]+$/.test(value)) return false
  const plusCount = value.split("+").length - 1
  if (plusCount > 1 || (plusCount === 1 && !value.startsWith("+"))) return false
  let depth = 0
  for (const character of value) {
    if (character === "(") depth += 1
    else if (character === ")") {
      depth -= 1
      if (depth < 0) return false
    }
  }
  if (depth !== 0) return false
  const digits = value.replace(/[^\d]/g, "").length
  if (digits < 7 || digits > 15) return false
  const strong = value.includes("+") || value.includes("(") || value.includes(")")
  return digits >= 10 || strong
}

// MARK: - Deep links

const deepLink = (value: string): AppLink | undefined => {
  if (!value.slice(value.indexOf(":") + 1).startsWith("//")) return undefined
  if (rawAuthority(value).includes("@")) return undefined
  const url = parseUrl(value)
  if (!url || url.username !== "" || url.password !== "") return undefined
  const host = url.hostname.toLowerCase()
  if (!deepLinkHosts.has(host)) return undefined
  const path = decodedSegments(url.pathname)
  if (!path) return undefined
  return appLink("deepLink", url, host, path)
}

// MARK: - Helpers

const trimSpaces = (value: string): string => {
  let start = 0
  let end = value.length
  while (start < end && value.charCodeAt(start) === 0x20) start += 1
  while (end > start && value.charCodeAt(end - 1) === 0x20) end -= 1
  return value.slice(start, end)
}

/** A positive decimal ID, as the Apple clients' `positiveId`. */
export const positiveDecimal = (value: string | undefined | null): string | undefined => {
  if (!value || !/^[0-9]{1,19}$/.test(value)) return undefined
  const parsed = BigInt(value)
  return parsed > 0n && parsed <= 9223372036854775807n ? parsed.toString() : undefined
}

/** The first query value whose lowercased name is one of `names`. */
export const appLinkQuery = (link: AppLink, names: readonly string[]): string | undefined => {
  const wanted = names.map((n) => n.toLowerCase())
  for (const [name, value] of link.query) {
    if (wanted.includes(name.toLowerCase())) return value
  }
  return undefined
}
