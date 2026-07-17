import { Effect, Layer, Schema } from "effect"
import {
  HttpApiBuilder,
  HttpApiEndpoint,
  HttpApiGroup,
} from "effect/unstable/httpapi"
import {
  defineExecutableHttpApi,
  makeHttpApplication,
} from "../src/core/http/application"
import { startCoreHttpServer } from "../src/core/http/host"
import {
  defineOpenApiDocument,
  makeBotApiBase,
  makePlatformApiBase,
  PLATFORM_API_ID,
} from "../src/core/http/openApi"
import { assertValidOpenApiDocument } from "../src/core/http/openApiValidation"
import { defineHttpRouteGroup } from "../src/core/http/routeGroup"
import {
  HttpRequestContext,
} from "../src/core/http/requestContext"

const CHILD_ARGUMENT = "--child"
const START_TIMEOUT_MS = 15_000
const REQUEST_TIMEOUT_MS = 10_000
const SHUTDOWN_TIMEOUT_MS = 15_000
const MAX_CAPTURED_OUTPUT = 24_000
const PATH_TOKEN = "bot123:IN_FAKE_CORE_HTTP_SMOKE"
const QUERY_SECRET = "fake-core-query-secret"

type CapturedOutput = {
  stdout: string
  stderr: string
}

const ProbeResponse = Schema.Struct({
  clientIp: Schema.String,
  ok: Schema.Literal(true),
})

const ProbeGroup = HttpApiGroup.make("kernelProcessProbe").add(
  HttpApiEndpoint.get("getProbe", "/v1/probe", {
    success: ProbeResponse,
  }),
)

const makeSmokeApplication = (
  clientIpHeader?: "x-real-ip",
) => {
  const platformApi = makePlatformApiBase(
    "https://api.inline.chat",
  ).add(ProbeGroup)
  const botApi = makeBotApiBase("https://api.inline.chat")
  const handlers = HttpApiBuilder.group(
    platformApi,
    "kernelProcessProbe",
    (groupHandlers) =>
      groupHandlers.handle(
        "getProbe",
        () =>
          HttpRequestContext.use((context) =>
            Effect.succeed({
              clientIp: context.clientIp,
              ok: true as const,
            }),
          ),
      ),
  )
  const routeGroup = defineHttpRouteGroup({
    apiId: PLATFORM_API_ID,
    document: "platform",
    group: ProbeGroup,
    handlers,
  })

  return makeHttpApplication({
    platform: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: platformApi,
        jsonPath: "/v1/reference/json",
        swaggerPath: "/v1/reference",
      }),
      handlers: routeGroup.handlers,
    }),
    bot: defineExecutableHttpApi({
      ...defineOpenApiDocument({
        api: botApi,
        jsonPath: "/bot-api-reference/json",
        swaggerPath: "/bot-api-reference",
      }),
      handlers: Layer.empty,
    }),
    middleware: {
      clientIpHeader,
      isProduction: false,
      rateLimit: {
        max: 1,
        windowMillis: 60_000,
      },
    },
  })
}

const appendBounded = (current: string, chunk: string): string => {
  const next = current + chunk
  if (next.length <= MAX_CAPTURED_OUTPUT) {
    return next
  }
  return `[earlier output truncated]\n${next.slice(-MAX_CAPTURED_OUTPUT)}`
}

const redactSentinels = (value: string): string =>
  value
    .replaceAll(PATH_TOKEN, "<redacted-test-token>")
    .replaceAll(QUERY_SECRET, "<redacted-test-query>")

const withTimeout = async <A>(
  promise: Promise<A>,
  timeoutMs: number,
  label: string,
): Promise<A> => {
  let timeout: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error(`${label} timed out after ${timeoutMs}ms`)),
          timeoutMs,
        )
      }),
    ])
  } finally {
    if (timeout) {
      clearTimeout(timeout)
    }
  }
}

const fetchBounded = (
  url: string,
  headers: HeadersInit,
): Promise<Response> =>
  fetch(url, {
    headers,
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  })

const requestHeaders = (
  clientIp: string,
  extra: HeadersInit = {},
): Headers => {
  const headers = new Headers(extra)
  headers.set("x-real-ip", clientIp)
  return headers
}

const describeOutput = ({ stdout, stderr }: CapturedOutput): string =>
  [
    stdout
      ? `--- child stdout ---\n${redactSentinels(stdout.trimEnd())}`
      : "",
    stderr
      ? `--- child stderr ---\n${redactSentinels(stderr.trimEnd())}`
      : "",
  ]
    .filter(Boolean)
    .join("\n")

const runChild = async (): Promise<void> => {
  const configured = await startCoreHttpServer({
    application: makeSmokeApplication("x-real-ip"),
    installSignalHandlers: true,
    port: 0,
  })
  try {
    const unconfigured = await startCoreHttpServer({
      application: makeSmokeApplication(),
      installSignalHandlers: true,
      port: 0,
    })
    console.info(
      `CORE_HTTP_KERNEL_READY ${configured.port} ${unconfigured.port}`,
    )
  } catch (cause) {
    await configured.shutdown()
    throw cause
  }
}

const runParent = async (): Promise<void> => {
  let captured: CapturedOutput = {
    stdout: "",
    stderr: "",
  }
  let readyBuffer = ""
  let resolveReady:
    | ((ports: {
      readonly configured: number
      readonly unconfigured: number
    }) => void)
    | undefined
  const ready = new Promise<{
    readonly configured: number
    readonly unconfigured: number
  }>((resolve) => {
    resolveReady = resolve
  })

  const child = Bun.spawn({
    cmd: [
      process.execPath,
      "scripts/core-http-kernel-smoke.ts",
      CHILD_ARGUMENT,
    ],
    cwd: new URL("..", import.meta.url).pathname,
    env: {
      ...process.env,
      NODE_ENV: "test",
      SENTRY_DSN: "",
    },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })

  const readStdout = (async () => {
    const decoder = new TextDecoder()
    for await (const bytes of child.stdout) {
      const chunk = decoder.decode(bytes, { stream: true })
      captured.stdout = appendBounded(captured.stdout, chunk)
      readyBuffer = (readyBuffer + chunk).slice(-4_096)

      const marker = readyBuffer.match(
        /CORE_HTTP_KERNEL_READY ([0-9]+) ([0-9]+)/,
      )
      if (marker?.[1] && marker[2]) {
        const configured = Number(marker[1])
        const unconfigured = Number(marker[2])
        if (
          Number.isSafeInteger(configured) &&
          configured > 0 &&
          Number.isSafeInteger(unconfigured) &&
          unconfigured > 0
        ) {
          resolveReady?.({ configured, unconfigured })
          resolveReady = undefined
        }
      }
    }
    captured.stdout = appendBounded(captured.stdout, decoder.decode())
  })()

  const readStderr = (async () => {
    const decoder = new TextDecoder()
    for await (const bytes of child.stderr) {
      captured.stderr = appendBounded(
        captured.stderr,
        decoder.decode(bytes, { stream: true }),
      )
    }
    captured.stderr = appendBounded(captured.stderr, decoder.decode())
  })()

  let forced = false
  try {
    const ports = await withTimeout(
      Promise.race([
        ready,
        child.exited.then((exitCode) => {
          throw new Error(
            `Core HTTP kernel exited before readiness with code ${exitCode}.`,
          )
        }),
      ]),
      START_TIMEOUT_MS,
      "Core HTTP kernel startup",
    )
    const baseUrl =
      `http://127.0.0.1:${ports.configured}`
    const unconfiguredBaseUrl =
      `http://127.0.0.1:${ports.unconfigured}`

    const probeResponse = await fetchBounded(
      `${baseUrl}/v1/probe?query_secret=${QUERY_SECRET}`,
      requestHeaders("192.0.2.10"),
    )
    if (probeResponse.status !== 200) {
      throw new Error(
        `The composed /v1/probe route returned ${probeResponse.status}, expected 200.`,
      )
    }
    const probeBody = await probeResponse.json() as {
      readonly clientIp: string
    }
    if (probeBody.clientIp !== "192.0.2.10") {
      throw new Error(
        "The configured proxy address did not become the canonical request-context identity.",
      )
    }

    const secretPathResponse = await fetchBounded(
      `${baseUrl}/${PATH_TOKEN}/getMe?query_secret=${QUERY_SECRET}`,
      requestHeaders("192.0.2.11"),
    )
    if (secretPathResponse.status !== 404) {
      throw new Error(
        `The credential-path fallback returned ${secretPathResponse.status}, expected 404.`,
      )
    }

    const specResponse = await fetchBounded(
      `${baseUrl}/v1/reference/json`,
      requestHeaders("192.0.2.12"),
    )
    const spec: unknown = await specResponse.json()
    assertValidOpenApiDocument(spec, "process-host platform OpenAPI")
    const paths = (spec as {
      readonly paths: Record<string, unknown>
    }).paths
    if (paths["/v1/probe"] === undefined) {
      throw new Error(
        "The process-host OpenAPI document omitted the composed /v1/probe route.",
      )
    }

    const firstProxyResponse = await fetchBounded(
      `${baseUrl}/v1/probe`,
      requestHeaders("192.0.2.20", {
        "cf-connecting-ip": "198.51.100.20",
        "x-forwarded-for": "198.51.100.21",
      }),
    )
    const changedFallbackResponse = await fetchBounded(
      `${baseUrl}/v1/probe`,
      requestHeaders("192.0.2.20", {
        "cf-connecting-ip": "198.51.100.22",
        "x-forwarded-for": "198.51.100.23",
      }),
    )
    if (
      firstProxyResponse.status !== 200 ||
      changedFallbackResponse.status !== 420
    ) {
      throw new Error(
        "Changing untrusted forwarding headers bypassed the configured client-IP quota.",
      )
    }

    const firstInvalidResponse = await fetchBounded(
      `${baseUrl}/v1/probe`,
      requestHeaders("attacker-selected-a"),
    )
    const secondInvalidResponse = await fetchBounded(
      `${baseUrl}/v1/probe`,
      requestHeaders("attacker-selected-b"),
    )
    if (
      firstInvalidResponse.status !== 200 ||
      secondInvalidResponse.status !== 420
    ) {
      throw new Error(
        "Invalid configured client-IP values did not share the direct-peer quota.",
      )
    }
    const invalidBody = await firstInvalidResponse.json() as {
      readonly clientIp: string
    }
    if (
      invalidBody.clientIp !== "127.0.0.1" &&
      invalidBody.clientIp !== "::1"
    ) {
      throw new Error(
        "A malformed proxy address did not fall back to the direct peer.",
      )
    }

    const unconfiguredResponse = await fetchBounded(
      `${unconfiguredBaseUrl}/v1/probe`,
      requestHeaders("203.0.113.45"),
    )
    if (unconfiguredResponse.status !== 200) {
      throw new Error(
        `The unconfigured proxy-mode probe returned ${unconfiguredResponse.status}, expected 200.`,
      )
    }
    const unconfiguredBody =
      await unconfiguredResponse.json() as {
        readonly clientIp: string
      }
    if (
      unconfiguredBody.clientIp !== "127.0.0.1" &&
      unconfiguredBody.clientIp !== "::1"
    ) {
      throw new Error(
        "Unconfigured proxy mode trusted a forwarding header instead of the direct peer.",
      )
    }

    child.kill("SIGTERM")
    const exitCode = await withTimeout(
      child.exited,
      SHUTDOWN_TIMEOUT_MS,
      "Core HTTP kernel graceful shutdown",
    )
    await Promise.all([readStdout, readStderr])

    if (exitCode !== 0) {
      throw new Error(
        `Core HTTP kernel exited with code ${exitCode} after SIGTERM.`,
      )
    }
    if (
      captured.stdout.includes(PATH_TOKEN) ||
      captured.stderr.includes(PATH_TOKEN) ||
      captured.stdout.includes(QUERY_SECRET) ||
      captured.stderr.includes(QUERY_SECRET)
    ) {
      throw new Error(
        "The real Bun/Effect host emitted a credential or query sentinel.",
      )
    }

    console.info(
      "Core HTTP kernel smoke passed: composed routes/docs, secret-negative output, canonical proxy/direct-peer identity, and graceful shutdown.",
    )
  } catch (error) {
    if (child.exitCode === null) {
      forced = true
      child.kill("SIGKILL")
      await child.exited
    }
    await Promise.allSettled([readStdout, readStderr])

    const diagnostics = describeOutput(captured)
    const message = error instanceof Error ? error.message : String(error)
    throw new Error(
      `${message}${forced ? " The smoke harness force-stopped only its child process." : ""}${
        diagnostics ? `\n${diagnostics}` : ""
      }`,
    )
  }
}

if (process.argv.includes(CHILD_ARGUMENT)) {
  await runChild()
} else {
  await runParent()
}
