import { createHash } from "node:crypto"
import { mkdir, readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { app } from "../../src/legacyServer"
import { makeCandidateHttpApplication } from "../../src/core/http/candidateApplication"
import {
  startCoreHttpServer,
  type CoreHttpServerHandle,
} from "../../src/core/http/host"
import { assertValidOpenApiDocument } from "../../src/core/http/openApiValidation"

const write = process.argv.includes("--write")
const fixturesDirectory = resolve(import.meta.dir, "../../src/__tests__/contracts/fixtures")
const documents = [
  { name: "v1-openapi", path: "/v1/reference/json", source: "legacy" },
  { name: "bot-openapi", path: "/bot-api-reference/json", source: "legacy" },
  { name: "effect-v1-openapi", path: "/v1/reference/json", source: "effect" },
  { name: "effect-bot-openapi", path: "/bot-api-reference/json", source: "effect" },
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

let coreHandle: CoreHttpServerHandle | undefined
const effectBaseUrl = async (): Promise<string> => {
  if (coreHandle === undefined) {
    coreHandle = await startCoreHttpServer({
      application: makeCandidateHttpApplication({
        middleware: {
          isProduction: false,
        },
      }),
      port: 0,
    })
  }
  return `http://${coreHandle.hostname}:${coreHandle.port}`
}

try {
  for (const document of documents) {
    const response = document.source === "legacy"
      ? await app.handle(
          new Request(`http://inline.test${document.path}`),
        )
      : await fetch(`${await effectBaseUrl()}${document.path}`)
    if (!response.ok) {
      throw new Error(
        `${document.source} OpenAPI capture failed for ${document.path}: HTTP ${response.status}`,
      )
    }

    const body: unknown = await response.json()
    if (document.source === "effect") {
      assertValidOpenApiDocument(body, document.name)
    }
    const serialized = `${JSON.stringify(canonicalize(body))}\n`
    const fixturePath = resolve(
      fixturesDirectory,
      `${document.name}.json`,
    )
    const sha256 = createHash("sha256").update(serialized).digest("hex")

    if (write) {
      await mkdir(dirname(fixturePath), { recursive: true })
      await Bun.write(fixturePath, serialized)
      console.log(`Wrote ${document.name} (${sha256}) to ${fixturePath}`)
    } else {
      const expected = await readFile(fixturePath, "utf8")
      if (expected !== serialized) {
        throw new Error(
          `OpenAPI drift for ${document.name}: run 'bun run contracts:openapi:update' and review ${fixturePath}`,
        )
      }
      console.log(`${document.name} matches (${sha256})`)
    }
  }
} finally {
  await coreHandle?.shutdown()
}

process.exit(0)
