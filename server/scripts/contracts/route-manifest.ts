import { createHash } from "node:crypto"
import { mkdir, readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { app } from "../../src/index"

const manifestPath = resolve(import.meta.dir, "../../src/__tests__/contracts/fixtures/route-manifest.json")
const write = process.argv.includes("--write")

const lines = (app.routes as ReadonlyArray<{ readonly method: string; readonly path: string }>)
  .map(({ method, path }) => `${String(method)}\t${path}`)
  .sort()
const routes = lines.map((line) => {
  const separator = line.indexOf("\t")
  return { method: line.slice(0, separator), path: line.slice(separator + 1) }
})
const sha256 = createHash("sha256").update(`${lines.join("\n")}\n`).digest("hex")
const methodCounts = Object.fromEntries(
  [...new Set(routes.map(({ method }) => method))].sort().map((method) => [
    method,
    routes.filter((route) => route.method === method).length,
  ]),
)
const serialized = `${JSON.stringify({ version: 1, count: routes.length, methodCounts, sha256, routes }, null, 2)}\n`

if (write) {
  await mkdir(dirname(manifestPath), { recursive: true })
  await Bun.write(manifestPath, serialized)
  console.log(`Wrote ${routes.length} routes to ${manifestPath}`)
} else {
  const expected = await readFile(manifestPath, "utf8")
  if (expected !== serialized) {
    throw new Error(`Route manifest drift: run 'bun run contracts:routes:update' and review ${manifestPath}`)
  }
  console.log(`Route manifest matches ${routes.length} routes (${sha256})`)
}

process.exit(0)
