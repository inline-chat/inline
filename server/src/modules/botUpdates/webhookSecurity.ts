import { lookup } from "node:dns/promises"
import { isIP } from "node:net"
import { InlineError } from "@in/server/types/errors"
import { isPublicAddress } from "@in/server/modules/mcpEvents/webhook"

const supportedPorts = new Set(["", "443", "80", "88", "8443"])

const dnsDeadlineMs = 10_000

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
  let deadline: ReturnType<typeof setTimeout> | undefined
  const addresses = isIP(lookupHostname)
    ? [{ address: lookupHostname, family: isIP(lookupHostname) as 4 | 6 }]
    : await Promise.race([
      lookup(lookupHostname, { all: true, verbatim: true }).catch(() => []),
      new Promise<never>((_resolve, reject) => {
        deadline = setTimeout(() => reject(new InlineError(InlineError.ApiError.BAD_REQUEST)), dnsDeadlineMs)
      }),
    ]).finally(() => { if (deadline) clearTimeout(deadline) })
  // Public-unicast allowlist shared with MCP callbacks: rejects private,
  // loopback, link-local, ULA, CGNAT, NAT64, 6to4, Teredo and documentation ranges.
  if (addresses.length === 0 || addresses.some(({ address }) => !isPublicAddress(address))) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
  const selected = addresses[0]!
  return { url, address: selected.address, family: selected.family as 4 | 6 }
}

export async function validateWebhookUrl(raw: string): Promise<URL> {
  return (await resolveWebhookUrl(raw)).url
}
