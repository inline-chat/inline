import { createHash } from "node:crypto"
import { mkdir, readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { makeCandidateHttpApplication } from "../../src/core/http/candidateApplication"
import { gridTranscriptionWorkerPaths } from "../../src/core/http/gridTranscription.effect"
import { HTTP_RPC_PATH } from "../../src/realtime/httpRpc"
import {
  startCoreHttpServer,
  type CoreHttpServerHandle,
} from "../../src/core/http/host"

const candidateManifestPath = resolve(
  import.meta.dir,
  "../../src/__tests__/contracts/fixtures/effect-route-manifest.json",
)
const write = process.argv.includes("--write")

interface Route {
  readonly method: string
  readonly path: string
}

const routeLines = (
  input: ReadonlyArray<Route>,
) =>
  input
    .map(
      ({ method, path }) =>
        `${method}\t${path}`,
    )
    .sort()

const serializeRoutes = (
  input: ReadonlyArray<Route>,
) => {
  const lines = routeLines(input)
  const routes = lines.map((line) => {
    const separator = line.indexOf("\t")
    return {
      method: line.slice(0, separator),
      path: line.slice(separator + 1),
    }
  })
  const sha256 = createHash("sha256")
    .update(`${lines.join("\n")}\n`)
    .digest("hex")
  const methodCounts = Object.fromEntries(
    [
      ...new Set(
        routes.map(({ method }) => method),
      ),
    ]
      .sort()
      .map((method) => [
        method,
        routes.filter(
          (route) =>
            route.method === method,
        ).length,
      ]),
  )
  return {
    count: routes.length,
    serialized: `${
      JSON.stringify(
        {
          version: 1,
          count: routes.length,
          methodCounts,
          sha256,
          routes,
        },
        null,
        2,
      )
    }\n`,
    sha256,
  }
}

const openApiMethods = new Set([
  "delete",
  "get",
  "head",
  "options",
  "patch",
  "post",
  "put",
  "trace",
])

const routesFromOpenApi = (
  document: unknown,
): ReadonlyArray<Route> => {
  if (
    document === null ||
    typeof document !== "object" ||
    !("paths" in document) ||
    document.paths === null ||
    typeof document.paths !== "object"
  ) {
    throw new Error(
      "Candidate OpenAPI document has no paths object.",
    )
  }

  const routes: Array<Route> = []
  for (
    const [path, value] of
    Object.entries(document.paths)
  ) {
    if (
      value === null ||
      typeof value !== "object"
    ) {
      continue
    }
    for (const method of Object.keys(value)) {
      if (openApiMethods.has(method)) {
        routes.push({
          method: method.toUpperCase(),
          path,
        })
      }
    }
  }
  return routes
}

const candidateRawRoutes: ReadonlyArray<Route> = [
  ...gridTranscriptionWorkerPaths.map((path) => ({ method: "POST", path })),
  { method: "POST", path: HTTP_RPC_PATH },
  { method: "GET", path: "//" },
  {
    method: "GET",
    path: "/bot-api-reference",
  },
  {
    method: "GET",
    path: "/bot-api-reference/json",
  },
  { method: "GET", path: "/health/" },
  { method: "GET", path: "/healthz/" },
  { method: "GET", path: "/livez/" },
  { method: "GET", path: "/readyz/" },
  {
    method: "GET",
    path: "/v1/reference",
  },
  {
    method: "GET",
    path: "/v1/reference/json",
  },
  { method: "WS", path: "/realtime" },
]

let coreHandle:
  | CoreHttpServerHandle
  | undefined

try {
  coreHandle =
    await startCoreHttpServer({
      application:
        makeCandidateHttpApplication({
          middleware: {
            isProduction: false,
          },
        }),
      port: 0,
    })
  const baseUrl =
    `http://${coreHandle.hostname}:${coreHandle.port}`
  for (
    const route of candidateRawRoutes
  ) {
    if (route.method !== "GET") {
      continue
    }
    const response =
      await fetch(
        `${baseUrl}${route.path}`,
      )
    if (response.status === 404) {
      throw new Error(
        `Candidate raw route is not executable: ${route.method}\t${route.path}`,
      )
    }
    await response.body?.cancel()
  }
  const documents =
    await Promise.all([
      fetch(
        `${baseUrl}/v1/reference/json`,
      ).then((response) =>
        response.json()
      ),
      fetch(
        `${baseUrl}/bot-api-reference/json`,
      ).then((response) =>
        response.json()
      ),
    ])
  const candidateRoutes = [
    ...documents.flatMap(
      routesFromOpenApi,
    ),
    ...candidateRawRoutes,
  ]
  const candidateManifest =
    serializeRoutes(
      Array.from(
        new Map(
          candidateRoutes.map(
            (route) => [
              `${route.method}\t${route.path}`,
              route,
            ],
          ),
        ).values(),
      ),
    )
  if (write) {
    await mkdir(
      dirname(candidateManifestPath),
      { recursive: true },
    )
    await Bun.write(
      candidateManifestPath,
      candidateManifest.serialized,
    )
    console.log(
      `Wrote ${candidateManifest.count} Effect routes to ${candidateManifestPath}`,
    )
  } else {
    const expectedCandidate = await readFile(
      candidateManifestPath,
      "utf8",
    )
    if (
      expectedCandidate !==
      candidateManifest.serialized
    ) {
      throw new Error(
        `Effect route manifest drift: run 'bun run contracts:routes:update' and review ${candidateManifestPath}`,
      )
    }
    console.log(
      `Effect served-contract manifest matches ${candidateManifest.count} routes (${candidateManifest.sha256}).`,
    )
  }
} finally {
  await coreHandle?.shutdown()
}

process.exit(0)
