import { resolve, sep } from "node:path"

const rootDir = resolve(import.meta.dir, "dist")
const indexFile = resolve(rootDir, "index.html")
const port = Number(process.env.PORT ?? 5174)

const isWithinRoot = (candidate: string) => {
  const rootWithSep = rootDir.endsWith(sep) ? rootDir : `${rootDir}${sep}`
  return candidate === rootDir || candidate.startsWith(rootWithSep)
}

const server = Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url)
    const rawPath = decodeURIComponent(url.pathname)
    const safePath = resolve(rootDir, `.${rawPath === "/" ? "/index.html" : rawPath}`)

    if (isWithinRoot(safePath)) {
      const file = Bun.file(safePath)
      if (await file.exists()) {
        return new Response(file)
      }
    }

    return new Response(Bun.file(indexFile))
  },
})

console.log(`Inline Admin running on http://localhost:${server.port}`)
