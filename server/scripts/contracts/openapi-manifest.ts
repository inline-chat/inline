import { createHash } from "node:crypto"
import { mkdir, readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { app } from "../../src/index"

const write = process.argv.includes("--write")
const fixturesDirectory = resolve(import.meta.dir, "../../src/__tests__/contracts/fixtures")
const documents = [
  { name: "v1-openapi", path: "/v1/reference/json" },
  { name: "bot-openapi", path: "/bot-api-reference/json" },
] as const

const compareStrings = (left: string, right: string): number => (left < right ? -1 : left > right ? 1 : 0)

const canonicalize = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(canonicalize)
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => compareStrings(left, right))
        .map(([key, item]) => [key, canonicalize(item)]),
    )
  }
  return value
}

for (const document of documents) {
  const response = await app.handle(new Request(`http://inline.test${document.path}`))
  if (!response.ok) throw new Error(`OpenAPI capture failed for ${document.path}: HTTP ${response.status}`)

  const body = canonicalize(await response.json())
  const serialized = `${JSON.stringify(body)}\n`
  const fixturePath = resolve(fixturesDirectory, `${document.name}.json`)
  const sha256 = createHash("sha256").update(serialized).digest("hex")

  if (write) {
    await mkdir(dirname(fixturePath), { recursive: true })
    await Bun.write(fixturePath, serialized)
    console.log(`Wrote ${document.name} (${sha256}) to ${fixturePath}`)
  } else {
    const expected = await readFile(fixturePath, "utf8")
    if (expected !== serialized) {
      throw new Error(`OpenAPI drift for ${document.name}: run 'bun run contracts:openapi:update' and review ${fixturePath}`)
    }
    console.log(`${document.name} matches (${sha256})`)
  }
}

process.exit(0)
