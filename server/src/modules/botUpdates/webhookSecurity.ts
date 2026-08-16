import { lookup } from "node:dns/promises"
import { isIP } from "node:net"
import { InlineError } from "@in/server/types/errors"

const supportedPorts = new Set(["", "443", "80", "88", "8443"])

const privateIpv4 = (address: string): boolean => {
  const parts = address.split(".").map(Number)
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return true
  const [a, b] = parts as [number, number, number, number]
  return a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0) ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19))
}

const privateIp = (address: string): boolean => {
  const normalized = address.toLowerCase().split("%")[0] ?? address.toLowerCase()
  if (normalized.startsWith("::ffff:")) return privateIpv4(normalized.slice(7))
  if (isIP(normalized) === 4) return privateIpv4(normalized)
  if (isIP(normalized) !== 6) return true
  return normalized === "::" || normalized === "::1" || normalized.startsWith("fc") ||
    normalized.startsWith("fd") || normalized.startsWith("fe8") ||
    normalized.startsWith("fe9") || normalized.startsWith("fea") || normalized.startsWith("feb") ||
    normalized.startsWith("ff") || normalized.startsWith("2001:db8")
}

export async function resolveWebhookUrl(raw: string): Promise<{ url: URL; address: string; family: 4 | 6 }> {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  if (
    url.protocol !== "https:" ||
    !url.hostname ||
    url.username ||
    url.password ||
    url.hash ||
    !supportedPorts.has(url.port) ||
    url.hostname.toLowerCase() === "localhost"
  ) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const lookupHostname = url.hostname.replace(/^\[|\]$/g, "")
  const addresses = isIP(lookupHostname)
    ? [{ address: lookupHostname, family: isIP(lookupHostname) as 4 | 6 }]
    : await lookup(lookupHostname, { all: true, verbatim: true }).catch(() => [])
  if (addresses.length === 0 || addresses.some(({ address }) => privateIp(address))) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const selected = addresses[0]!
  return { url, address: selected.address, family: selected.family as 4 | 6 }
}

export async function validateWebhookUrl(raw: string): Promise<URL> {
  return (await resolveWebhookUrl(raw)).url
}
