import { getApiBaseUrl } from "@inline/config"

export type SpaceJoinReference =
  | { kind: "public_handle"; value: string }
  | { kind: "invite_token"; value: string }

type SpaceJoinFetch = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>

const publicHandlePattern = /^[A-Za-z0-9][A-Za-z0-9_-]{1,63}$/
const inviteTokenPattern = /^iv1_[A-Za-z0-9_-]{43}$/

const responseHeaders = {
  "cache-control": "private, no-store",
  "content-security-policy": "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; style-src 'unsafe-inline'",
  "content-type": "text/html; charset=utf-8",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "x-robots-tag": "noindex, nofollow, noarchive, nosnippet",
} as const

const escapeHtml = (value: string): string => value
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#39;")

export const publicSpaceJoinReference = (handle: string): SpaceJoinReference | null => {
  const normalized = handle.trim().replace(/^@/, "")
  return publicHandlePattern.test(normalized)
    ? { kind: "public_handle", value: normalized }
    : null
}

export const privateSpaceJoinReference = (token: string): SpaceJoinReference | null =>
  inviteTokenPattern.test(token)
    ? { kind: "invite_token", value: token }
    : null

export const spaceJoinDeepLink = (reference: SpaceJoinReference): string =>
  reference.kind === "public_handle"
    ? `in://join/public/${encodeURIComponent(reference.value)}`
    : `in://join/invite/${encodeURIComponent(reference.value)}`

export const resolveSpaceJoinName = async (
  reference: SpaceJoinReference,
  options: {
    fetch?: SpaceJoinFetch
    apiBaseUrl?: string
  } = {},
): Promise<string | null> => {
  const fetchImpl = options.fetch ?? fetch
  const apiBaseUrl = (options.apiBaseUrl ?? getApiBaseUrl()).replace(/\/+$/, "")
  try {
    const response = await fetchImpl(`${apiBaseUrl}/space-join/resolve`, {
      method: "POST",
      headers: {
        "accept": "application/json",
        "content-type": "application/json",
      },
      body: JSON.stringify(reference),
      cache: "no-store",
      signal: AbortSignal.timeout(3_000),
    })
    if (!response.ok) return null
    const body: unknown = await response.json()
    if (typeof body !== "object" || body === null || !("name" in body)) return null
    const name = (body as { name?: unknown }).name
    return typeof name === "string" && name.trim().length > 0 && name.length <= 256
      ? name
      : null
  } catch {
    return null
  }
}

const document = ({
  body,
  description,
  title,
}: {
  body: string
  description: string
  title: string
}): string => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow,noarchive,nosnippet">
<meta name="referrer" content="no-referrer">
<title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeHtml(description)}">
<meta property="og:type" content="website">
<meta property="og:title" content="${escapeHtml(title)}">
<meta property="og:description" content="${escapeHtml(description)}">
<meta name="twitter:card" content="summary">
<meta name="twitter:title" content="${escapeHtml(title)}">
<meta name="twitter:description" content="${escapeHtml(description)}">
<style>
:root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f7f7f5;color:#171717}
body{min-height:100vh;margin:0;display:grid;place-items:center;padding:24px;box-sizing:border-box}
main{text-align:center;max-width:560px}h1{font-size:clamp(28px,6vw,48px);letter-spacing:-.035em;line-height:1.08;margin:0 0 28px}
a{display:inline-block;background:#171717;color:#fff;text-decoration:none;font-weight:650;padding:13px 20px;border-radius:12px}
@media(prefers-color-scheme:dark){:root{background:#111;color:#f7f7f5}a{background:#f7f7f5;color:#171717}}
</style>
</head>
<body>${body}</body>
</html>`

const unavailableDocument = (): string => document({
  title: "Invite unavailable · Inline",
  description: "This Inline invite is invalid, expired, or unavailable.",
  body: "<main><h1>Invite unavailable</h1></main>",
})

export const spaceJoinPageResponse = async (
  reference: SpaceJoinReference | null,
  includeBody = true,
  options?: Parameters<typeof resolveSpaceJoinName>[1],
): Promise<Response> => {
  const name = reference ? await resolveSpaceJoinName(reference, options) : null
  if (!reference || !name) {
    return new Response(includeBody ? unavailableDocument() : null, {
      status: 404,
      headers: responseHeaders,
    })
  }

  const title = `Join ${name} on Inline`
  const description = `You’re invited to join ${name} on Inline.`
  const deepLink = spaceJoinDeepLink(reference)
  const body = `<main><h1>${escapeHtml(title)}</h1><a href="${escapeHtml(deepLink)}">Open Inline</a></main>`
  return new Response(includeBody ? document({ body, description, title }) : null, {
    headers: responseHeaders,
  })
}
