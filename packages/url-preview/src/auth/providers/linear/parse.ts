import { trimUrlToken } from "../../../normalize.js"
import type { LinearParsedUrl } from "./types.js"

const linearHost = "linear.app"
const identifierPattern = /^[a-z][a-z0-9]*-\d+$/i
const slugPattern = /^[a-z0-9][a-z0-9-]*$/i

export function parseLinearUrl(input: string): LinearParsedUrl | null {
  const raw = trimUrlToken(input)
  if (!raw) return null

  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return null
  }

  if (
    url.protocol !== "https:" ||
    url.hostname.toLowerCase() !== linearHost ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    return null
  }

  const segments = url.pathname.split("/").filter(Boolean)
  if (
    (segments.length !== 3 && segments.length !== 4) ||
    segments[1]?.toLowerCase() !== "issue" ||
    !segments[0] ||
    !slugPattern.test(segments[0]) ||
    !segments[2] ||
    !identifierPattern.test(segments[2]) ||
    (segments[3] != null && !slugPattern.test(segments[3]))
  ) {
    return null
  }

  const workspace = segments[0].toLowerCase()
  const identifier = segments[2].toUpperCase()
  const slug = segments[3] ? `/${segments[3]}` : ""
  return {
    provider: "linear",
    resourceType: "issue",
    resourceId: identifier,
    originalUrl: raw,
    normalizedUrl: `https://${linearHost}/${workspace}/issue/${identifier}${slug}`,
    meta: { workspace, identifier },
  }
}
