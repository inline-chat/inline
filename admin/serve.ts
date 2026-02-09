import { resolve, sep } from "node:path"

const rootDir = resolve(import.meta.dir, "dist")
const indexFile = resolve(rootDir, "index.html")
const port = Number(process.env.PORT ?? 5174)
const envApiBase = process.env.ADMIN_API_BASE?.replace(/\/$/, "") ?? null
const defaultProdApiBase = "https://api.inline.chat"
const defaultDevApiBase = "http://localhost:8000"

const isWithinRoot = (candidate: string) => {
  const rootWithSep = rootDir.endsWith(sep) ? rootDir : `${rootDir}${sep}`
  return candidate === rootDir || candidate.startsWith(rootWithSep)
}

const apiOriginFromBase = (apiBase: string | null) => {
  if (!apiBase) return null
  try {
    return new URL(apiBase).origin
  } catch {
    return null
  }
}

const isLocalHostHeader = (host: string) => {
  const normalized = host.trim().toLowerCase()
  return (
    normalized === "localhost" ||
    normalized.startsWith("localhost:") ||
    normalized === "127.0.0.1" ||
    normalized.startsWith("127.0.0.1:") ||
    normalized === "[::1]" ||
    normalized.startsWith("[::1]:")
  )
}

const wsOriginFromHttpOrigin = (origin: string) => {
  if (origin.startsWith("https://")) return origin.replace(/^https:/, "wss:")
  if (origin.startsWith("http://")) return origin.replace(/^http:/, "ws:")
  return null
}

const contentSecurityPolicyForRequest = (request: Request) => {
  const host = request.headers.get("host") ?? ""
  const apiBase = envApiBase ?? (isLocalHostHeader(host) ? defaultDevApiBase : defaultProdApiBase)
  const apiOrigin = apiOriginFromBase(apiBase)
  const wsOrigin = apiOrigin ? wsOriginFromHttpOrigin(apiOrigin) : null

  return [
    "default-src 'self'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    `img-src 'self' data:${apiOrigin ? ` ${apiOrigin}` : ""}`,
    "font-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self'",
    `connect-src 'self'${apiOrigin ? ` ${apiOrigin}` : ""}${wsOrigin ? ` ${wsOrigin}` : ""}`,
  ].join("; ")
}

const applySecurityHeaders = (request: Request, response: Response) => {
  response.headers.set("content-security-policy", contentSecurityPolicyForRequest(request))
  response.headers.set("x-content-type-options", "nosniff")
  // Needed so the API origin allowlist can validate admin-originated requests for <img> loads
  // (browsers often omit the Origin header for images, so we rely on Referer).
  response.headers.set("referrer-policy", "strict-origin-when-cross-origin")
  response.headers.set("permissions-policy", "geolocation=(), microphone=(), camera=()")
  return response
}

const server = Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url)
    let rawPath: string
    try {
      rawPath = decodeURIComponent(url.pathname)
    } catch {
      return applySecurityHeaders(request, new Response("Bad Request", { status: 400 }))
    }
    const safePath = resolve(rootDir, `.${rawPath === "/" ? "/index.html" : rawPath}`)

    if (isWithinRoot(safePath)) {
      const file = Bun.file(safePath)
      if (await file.exists()) {
        return applySecurityHeaders(request, new Response(file))
      }
    }

    return applySecurityHeaders(request, new Response(Bun.file(indexFile)))
  },
})

console.log(`Inline Admin running on http://localhost:${server.port}`)
