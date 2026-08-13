const MAX_INT64 = 9_223_372_036_854_775_807n
const RESPONSE_HEADERS = {
  "cache-control": "private, no-store",
  "content-security-policy": "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "content-type": "text/html; charset=utf-8",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "x-robots-tag": "noindex, nofollow, noarchive, nosnippet",
} as const

export function chatShortcutDeepLink(chatId: string): string | null {
  if (chatId.length > 19 || !/^[1-9]\d*$/.test(chatId)) {
    return null
  }

  const id = BigInt(chatId)
  if (id > MAX_INT64) {
    return null
  }

  return `in://chat/${id}`
}

export function chatShortcutResponse(chatId: string, includeBody = true): Response {
  const deepLink = chatShortcutDeepLink(chatId)
  if (!deepLink) {
    return new Response(null, { status: 404, headers: RESPONSE_HEADERS })
  }

  const body = includeBody
    ? `<!doctype html><meta charset="utf-8"><meta name="robots" content="noindex,nofollow,noarchive,nosnippet"><meta name="referrer" content="no-referrer"><meta http-equiv="refresh" content="0;url=${deepLink}"><title>Open in Inline</title><a href="${deepLink}">Open in Inline</a>`
    : null

  return new Response(body, { headers: RESPONSE_HEADERS })
}
