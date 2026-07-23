import { readFile } from "node:fs/promises"
import type { Plugin } from "vite"

const mediaCacheHarnessPath = "/__inline-harness/media-cache"
const messageListHarnessPath = "/__inline-harness/message-list"
const composeHarnessPath = "/__inline-harness/compose"

export const inlineBrowserHarnessPlugin = (): Plugin => ({
  name: "inline-browser-harnesses",
  apply: "serve",
  enforce: "pre",
  configureServer(server) {
    server.middlewares.use(async (request, response, next) => {
      const pathname = new URL(
        request.url ?? "/",
        "http://inline.local",
      ).pathname
      const fixture = pathname === mediaCacheHarnessPath
        ? "../fixtures/media-cache-harness.html"
        : pathname === messageListHarnessPath
          ? "../fixtures/message-list-harness.html"
          : pathname === composeHarnessPath
            ? "../fixtures/compose-harness.html"
          : undefined
      if (!fixture) {
        next()
        return
      }
      try {
        const source = await readFile(
          new URL(fixture, import.meta.url),
          "utf8",
        )
        const html = await server.transformIndexHtml(
          pathname,
          source,
        )
        response.statusCode = 200
        response.setHeader("Content-Type", "text/html; charset=utf-8")
        response.end(html)
      } catch (error) {
        next(error as Error)
      }
    })
  },
})
