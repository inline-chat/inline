const productionContentSecurityPolicy = [
  "default-src 'self'",
  "base-uri 'self'",
  "object-src 'none'",
  "frame-src 'none'",
  "frame-ancestors 'none'",
  "form-action 'self'",
  // TanStack Start hydration and Inline's pre-paint appearance bootstrap are
  // inline today. Public exposure requires a nonce-based policy.
  "script-src 'self' 'unsafe-inline'",
  // React and overlay geometry still use bounded style attributes.
  "style-src 'self' 'unsafe-inline'",
  "font-src 'self' data:",
  "img-src 'self' blob: data: https:",
  "media-src 'self' blob: https:",
  "worker-src 'self' blob:",
  "connect-src 'self' https://api.inline.chat wss://api.inline.chat https://cdn.inline.chat https://*.r2.cloudflarestorage.com",
  "manifest-src 'self'",
  "upgrade-insecure-requests",
].join("; ")

const sharedHeaders: Readonly<Record<string, string>> = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Resource-Policy": "same-origin",
  "Origin-Agent-Cluster": "?1",
  "Permissions-Policy":
    "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
}

export const withInlineWebSecurityHeaders = (
  response: Response,
  options: { production: boolean },
) => {
  const headers = new Headers(response.headers)
  for (const [name, value] of Object.entries(sharedHeaders)) {
    headers.set(name, value)
  }
  if (options.production) {
    headers.set(
      "Strict-Transport-Security",
      "max-age=31536000; includeSubDomains",
    )
    if (response.headers.get("content-type")?.includes("text/html")) {
      headers.set(
        "Content-Security-Policy",
        productionContentSecurityPolicy,
      )
    }
  }
  return new Response(response.body, {
    headers,
    status: response.status,
    statusText: response.statusText,
  })
}

export { productionContentSecurityPolicy }
