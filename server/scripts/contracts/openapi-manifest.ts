import { createHash } from "node:crypto"
import { mkdir, readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { makeCandidateHttpApplication } from "../../src/core/http/candidateApplication"
import {
  startCoreHttpServer,
  type CoreHttpServerHandle,
} from "../../src/core/http/host"
import { assertValidOpenApiDocument } from "../../src/core/http/openApiValidation"

const write = process.argv.includes("--write")
const fixturesDirectory = resolve(import.meta.dir, "../../src/__tests__/contracts/fixtures")
const documents = [
  { name: "effect-v1-openapi", path: "/v1/reference/json" },
  { name: "effect-bot-openapi", path: "/bot-api-reference/json" },
] as const
const requestedDocumentNames = new Set(
  process.argv
    .filter((argument) => argument.startsWith("--only="))
    .map((argument) => argument.slice("--only=".length).trim())
    .filter((name) => name.length > 0),
)
const selectedDocuments = requestedDocumentNames.size === 0
  ? documents
  : documents.filter((document) => requestedDocumentNames.has(document.name))

if (requestedDocumentNames.size > 0 && selectedDocuments.length !== requestedDocumentNames.size) {
  const knownNames = new Set<string>(documents.map((document) => document.name))
  const unknownNames = [...requestedDocumentNames].filter((name) => !knownNames.has(name))
  throw new Error(`Unknown OpenAPI document: ${JSON.stringify(unknownNames)}`)
}

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
  for (const document of selectedDocuments) {
    const response = await fetch(`${await effectBaseUrl()}${document.path}`)
    if (!response.ok) {
      throw new Error(
        `OpenAPI capture failed for ${document.path}: HTTP ${response.status}`,
      )
    }

    const body: unknown = await response.json()
    assertValidOpenApiDocument(body, document.name)
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
