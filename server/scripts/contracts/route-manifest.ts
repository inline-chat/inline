import { createHash } from "node:crypto"
import { mkdir, readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { app } from "../../src/legacyServer"
import { makeCandidateHttpApplication } from "../../src/core/http/candidateApplication"
import {
  startCoreHttpServer,
  type CoreHttpServerHandle,
} from "../../src/core/http/host"

const manifestPath = resolve(import.meta.dir, "../../src/__tests__/contracts/fixtures/route-manifest.json")
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

const legacyRoutes =
  (app.routes as ReadonlyArray<Route>)
  .map(({ method, path }) => `${String(method)}\t${path}`)
  .map((line) => {
    const separator =
      line.indexOf("\t")
    return {
      method: line.slice(0, separator),
      path: line.slice(separator + 1),
    }
  })
const legacyManifest =
  serializeRoutes(legacyRoutes)

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

const normalizeLegacyPath = (
  path: string,
): ReadonlyArray<string> => {
  const optional =
    path.match(/:([A-Za-z0-9_]+)\?/)
  if (optional?.[1] !== undefined) {
    return [
      path.replace(
        `/:${optional[1]}?`,
        "",
      ),
      path.replace(
        `:${optional[1]}?`,
        `{${optional[1]}}`,
      ),
    ]
  }
  return [
    path.replace(
      /:([A-Za-z0-9_]+)/g,
      "{$1}",
    ),
  ]
}

const comparableLegacyRoutes =
  legacyRoutes.flatMap((route) =>
    route.method === "ALL" ||
      route.method === "OPTIONS"
      ? []
      : normalizeLegacyPath(
          route.path,
        ).map((path) => ({
          method: route.method,
          path,
        }))
  )

const intentionalCandidateOnly =
  new Set([
    "GET\t/",
    "GET\t/health",
    "GET\t/healthz",
  ])

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
  const candidateSet =
    new Set(
      routeLines(candidateRoutes),
    )
  const legacySet =
    new Set(
      routeLines(
        comparableLegacyRoutes,
      ),
    )
  const missing =
    [...legacySet].filter(
      (route) =>
        !candidateSet.has(route),
    )
  const unexpected =
    [...candidateSet].filter(
      (route) =>
        !legacySet.has(route) &&
        !intentionalCandidateOnly.has(
          route,
        ),
    )
  if (
    missing.length > 0 ||
    unexpected.length > 0
  ) {
    throw new Error(
      [
        "Candidate served-contract route parity failed.",
        missing.length > 0
          ? `Missing:\n${missing.join("\n")}`
          : "",
        unexpected.length > 0
          ? `Unexpected:\n${unexpected.join("\n")}`
          : "",
      ]
        .filter(Boolean)
        .join("\n"),
    )
  }

  if (write) {
    await mkdir(
      dirname(manifestPath),
      { recursive: true },
    )
    await Promise.all([
      Bun.write(
        manifestPath,
        legacyManifest.serialized,
      ),
      Bun.write(
        candidateManifestPath,
        candidateManifest.serialized,
      ),
    ])
    console.log(
      `Wrote ${legacyManifest.count} legacy routes to ${manifestPath}`,
    )
    console.log(
      `Wrote ${candidateManifest.count} Effect routes to ${candidateManifestPath}`,
    )
  } else {
    const [expectedLegacy, expectedCandidate] =
      await Promise.all([
        readFile(
          manifestPath,
          "utf8",
        ),
        readFile(
          candidateManifestPath,
          "utf8",
        ),
      ])
    if (
      expectedLegacy !==
      legacyManifest.serialized
    ) {
      throw new Error(
        `Legacy route manifest drift: run 'bun run contracts:routes:update' and review ${manifestPath}`,
      )
    }
    if (
      expectedCandidate !==
      candidateManifest.serialized
    ) {
      throw new Error(
        `Effect route manifest drift: run 'bun run contracts:routes:update' and review ${candidateManifestPath}`,
      )
    }
    console.log(
      `Legacy route manifest matches ${legacyManifest.count} routes (${legacyManifest.sha256})`,
    )
    console.log(
      `Effect served-contract manifest matches ${candidateManifest.count} routes (${candidateManifest.sha256}); contract coverage matches the legacy GET/POST/WS surface.`,
    )
  }
} finally {
  await coreHandle?.shutdown()
}

process.exit(0)
