// Site-wide document CSP. Scripts run only from this origin or with the
// per-request nonce, and DOM script/HTML sinks require Trusted Types.
// Server routes that build their own HTML (join page, chat shortcut) keep
// their stricter policies; see `withDocumentContentSecurityPolicy`.

export const TRUSTED_TYPES_HIGHLIGHT_POLICY = "inline-highlight"

const NONCE_BYTES = 16

export function createCspNonce(): string {
  const bytes = new Uint8Array(NONCE_BYTES)
  crypto.getRandomValues(bytes)
  return btoa(String.fromCharCode(...bytes))
}

export function documentContentSecurityPolicy(nonce: string): string {
  return [
    "default-src 'self'",
    "base-uri 'none'",
    "object-src 'none'",
    "frame-ancestors 'self'",
    "img-src 'self' data: blob: https:",
    "font-src 'self' data:",
    "style-src 'self' 'unsafe-inline'",
    `script-src 'self' 'nonce-${nonce}'`,
    "frame-src https://www.youtube-nocookie.com",
    "connect-src 'self' https://api.inline.chat wss://api.inline.chat https://public-assets.inline.chat",
    "worker-src 'self' blob:",
    "manifest-src 'self'",
    "form-action 'self'",
    "require-trusted-types-for 'script'",
    `trusted-types default ${TRUSTED_TYPES_HIGHLIGHT_POLICY}`,
    "upgrade-insecure-requests",
  ].join("; ")
}

export function withDocumentContentSecurityPolicy(response: Response, nonce: string): Response {
  if (response.headers.has("content-security-policy")) return response
  try {
    response.headers.set("content-security-policy", documentContentSecurityPolicy(nonce))
    return response
  } catch {
    // Immutable headers (e.g. a proxied fetch response): copy once.
    const headers = new Headers(response.headers)
    headers.set("content-security-policy", documentContentSecurityPolicy(nonce))
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    })
  }
}
