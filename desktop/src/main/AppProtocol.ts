import { net, protocol } from "electron"
import path from "node:path"
import { pathToFileURL } from "node:url"

export const INLINE_APP_SCHEME = "inline-app"
export const INLINE_APP_HOST = "app"
export const INLINE_APP_ORIGIN = `${INLINE_APP_SCHEME}://${INLINE_APP_HOST}`

const contentSecurityPolicy = [
  "default-src 'self'",
  "base-uri 'none'",
  "object-src 'none'",
  "frame-src 'none'",
  "frame-ancestors 'none'",
  "form-action 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "font-src 'self'",
  "img-src 'self' data: blob: https:",
  "media-src 'self' blob: https:",
  "connect-src 'self' https://api.inline.chat wss://api.inline.chat https://cdn.inline.chat https://dev-cdn.inline.chat https://*.r2.cloudflarestorage.com",
].join("; ")

export const registerInlineAppScheme = () => {
  protocol.registerSchemesAsPrivileged([
    {
      scheme: INLINE_APP_SCHEME,
      privileges: {
        standard: true,
        secure: true,
        supportFetchAPI: true,
        corsEnabled: true,
        stream: true,
      },
    },
  ])
}

export const registerInlineAppProtocol = (
  rendererRoot: string,
) => {
  const root = path.resolve(rendererRoot)
  const assetsRoot = path.join(root, "assets")
  const shellPath = path.join(root, "_shell.html")

  protocol.handle(INLINE_APP_SCHEME, async (request) => {
    const url = new URL(request.url)
    if (url.host !== INLINE_APP_HOST) {
      return new Response("Not found", { status: 404 })
    }

    const requestedPath = decodeURIComponent(url.pathname)
    let filePath = shellPath
    if (requestedPath.startsWith("/assets/")) {
      const relativeAssetPath = requestedPath.slice("/assets/".length)
      const candidate = path.resolve(assetsRoot, relativeAssetPath)
      if (!candidate.startsWith(`${assetsRoot}${path.sep}`)) {
        return new Response("Not found", { status: 404 })
      }
      filePath = candidate
    }

    const response = await net.fetch(pathToFileURL(filePath).toString(), {
      method: request.method,
      headers: request.headers,
    })
    const headers = new Headers(response.headers)
    if (filePath === shellPath) {
      headers.set("Content-Security-Policy", contentSecurityPolicy)
      headers.set("Cache-Control", "no-store")
    } else {
      headers.set("Cache-Control", "public, max-age=31536000, immutable")
    }
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    })
  })
}
