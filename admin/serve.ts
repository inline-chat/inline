import { resolve, sep } from "node:path"

const rootDir = resolve(import.meta.dir, "dist")
const indexFile = resolve(rootDir, "index.html")
const port = Number(process.env.PORT ?? 5174)
const isProd = process.env.NODE_ENV === "production"
const apiBase = (
  process.env.ADMIN_API_BASE ?? (isProd ? "https://api.inline.chat" : "http://localhost:8000")
).replace(/\/$/, "")

const isWithinRoot = (candidate: string) => {
  const rootWithSep = rootDir.endsWith(sep) ? rootDir : `${rootDir}${sep}`
  return candidate === rootDir || candidate.startsWith(rootWithSep)
}

const apiOrigin = (() => {
  try {
    return new URL(apiBase).origin
  } catch {
    return null
  }
})()

const contentSecurityPolicy = [
  "default-src 'self'",
  "base-uri 'none'",
  "form-action 'self'",
  "frame-ancestors 'none'",
  "object-src 'none'",
  `img-src 'self' data:${apiOrigin ? ` ${apiOrigin}` : ""}`,
  "font-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "script-src 'self'",
  `connect-src 'self'${apiOrigin ? ` ${apiOrigin}` : ""}`,
].join("; ")

const applySecurityHeaders = (response: Response) => {
  response.headers.set("content-security-policy", contentSecurityPolicy)
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
      return applySecurityHeaders(new Response("Bad Request", { status: 400 }))
    }
    const safePath = resolve(rootDir, `.${rawPath === "/" ? "/index.html" : rawPath}`)

    if (isWithinRoot(safePath)) {
      const file = Bun.file(safePath)
      if (await file.exists()) {
        return applySecurityHeaders(new Response(file))
      }
    }

    return applySecurityHeaders(new Response(Bun.file(indexFile)))
  },
})

console.log(`Inline Admin running on http://localhost:${server.port}`)
