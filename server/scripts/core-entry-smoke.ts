const START_TIMEOUT_MS = 15_000
const REQUEST_TIMEOUT_MS = 10_000
// The production graceful-shutdown manager has its own 25-second hard bound.
// Give it enough time to report/force its result before the isolated harness
// performs the final child-only kill.
const SHUTDOWN_TIMEOUT_MS = 30_000
const MAX_CAPTURED_OUTPUT = 24_000
const SMOKE_REQUEST_ID = "core-shadow-smoke"

type CapturedOutput = {
  stdout: string
  stderr: string
}

const appendBounded = (current: string, chunk: string): string => {
  const next = current + chunk
  if (next.length <= MAX_CAPTURED_OUTPUT) {
    return next
  }
  return `[earlier output truncated]\n${next.slice(-MAX_CAPTURED_OUTPUT)}`
}

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
        timeout = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs)
      }),
    ])
  } finally {
    if (timeout) {
      clearTimeout(timeout)
    }
  }
}

const fetchBounded = (url: string, headers?: HeadersInit): Promise<Response> =>
  fetch(url, {
    headers,
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  })

const exerciseRealtime = (url: string): Promise<void> =>
  withTimeout(
    new Promise<void>((resolve, reject) => {
      let opened = false
      const socket = new WebSocket(url)

      socket.addEventListener("open", () => {
        opened = true
        socket.close(1000, "core-shadow-smoke")
      })
      socket.addEventListener("close", () => {
        if (opened) {
          resolve()
        } else {
          reject(new Error("Realtime socket closed before opening."))
        }
      })
      socket.addEventListener("error", () => {
        reject(new Error("Realtime socket failed to connect."))
      })
    }),
    REQUEST_TIMEOUT_MS,
    "Realtime WebSocket probe",
  )

const describeOutput = ({ stdout, stderr }: CapturedOutput): string =>
  [
    stdout ? `--- child stdout ---\n${stdout.trimEnd()}` : "",
    stderr ? `--- child stderr ---\n${stderr.trimEnd()}` : "",
  ]
    .filter(Boolean)
    .join("\n")

const main = async (): Promise<void> => {
  let captured: CapturedOutput = {
    stdout: "",
    stderr: "",
  }
  let readyBuffer = ""
  let resolveReady:
    | ((ports: {
        readonly current: number
        readonly replacement: number
      }) => void)
    | undefined
  const ready = new Promise<{
    readonly current: number
    readonly replacement: number
  }>((resolve) => {
    resolveReady = resolve
  })

  const child = Bun.spawn({
    cmd: [
      process.execPath,
      "src/core/shadow.ts",
    ],
    cwd: new URL("..", import.meta.url).pathname,
    env: {
      ...process.env,
      NODE_ENV: "test",
      PORT: "0",
      SENTRY_DSN: "",
      ENABLE_DATABASE_HEALTH_MONITOR: "1",
      INLINE_API_RATE_LIMIT_MAX: "180",
      INLINE_CORE_HTTP_PORT: "0",
      INLINE_TRUSTED_CLIENT_IP_HEADER: "direct",
      LIVEKIT_API_KEY: "",
      LIVEKIT_API_SECRET: "",
      LIVEKIT_URL: "",
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
        /CORE_SHADOW_READY ([0-9]+) ([0-9]+)/,
      )
      if (marker?.[1] && marker[2]) {
        const current = Number(marker[1])
        const replacement = Number(marker[2])
        if (
          Number.isSafeInteger(current) &&
          current > 0 &&
          Number.isSafeInteger(replacement) &&
          replacement > 0
        ) {
          resolveReady?.({
            current,
            replacement,
          })
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
          throw new Error(`Core shadow exited before readiness with code ${exitCode}.`)
        }),
      ]),
      START_TIMEOUT_MS,
      "Core shadow startup",
    )
    const currentBaseUrl = `http://127.0.0.1:${ports.current}`
    const replacementBaseUrl =
      `http://127.0.0.1:${ports.replacement}`

    const rootResponse = await fetchBounded(`${currentBaseUrl}/`)
    const rootBody = await rootResponse.text()
    if (
      rootResponse.status !== 200 ||
      !rootBody.includes("inline server is running")
    ) {
      throw new Error(
        `The current full-server root returned ${rootResponse.status} without its uptime marker.`,
      )
    }

    const readinessResponse = await fetchBounded(
      `${currentBaseUrl}/readyz`,
    )
    const readiness = await readinessResponse.json() as {
      readonly checks?: {
        readonly database?: {
          readonly ok?: boolean
        }
        readonly lifecycle?: {
          readonly ok?: boolean
        }
      }
      readonly ok?: boolean
    }
    if (
      readinessResponse.status !== 200 ||
      readiness.ok !== true ||
      readiness.checks?.database?.ok !== true ||
      readiness.checks?.lifecycle?.ok !== true
    ) {
      throw new Error(
        `The current full-server readiness check returned ${readinessResponse.status}.`,
      )
    }

    const platformSpecResponse = await fetchBounded(
      `${replacementBaseUrl}/v1/reference/json`,
      {
        "x-request-id": SMOKE_REQUEST_ID,
      },
    )
    const platformSpec = await platformSpecResponse.json() as {
      readonly info?: {
        readonly title?: string
      }
      readonly openapi?: string
      readonly paths?: Record<string, unknown>
    }
    const requestId = platformSpecResponse.headers.get("x-request-id")

    if (platformSpecResponse.status !== 200) {
      throw new Error(
        `GET /v1/reference/json returned ${platformSpecResponse.status}, expected 200.`,
      )
    }
    if (
      platformSpec.openapi !== "3.1.0" ||
      platformSpec.info?.title !== "Inline HTTP API Docs" ||
      platformSpec.paths === undefined
    ) {
      throw new Error("GET /v1/reference/json did not return the Effect platform contract.")
    }
    if (requestId !== SMOKE_REQUEST_ID) {
      throw new Error(
        `GET /v1/reference/json returned x-request-id ${JSON.stringify(requestId)}, expected the supplied smoke ID.`,
      )
    }
    for (const path of [
      "/",
      "/health",
      "/v1/getMe",
      "/v1/sendMessage",
      "/v1/sendSmsCode",
      "/admin/me",
      "/oauth/token",
    ]) {
      if (platformSpec.paths[path] === undefined) {
        throw new Error(
          `The Effect platform contract omitted accepted route ${path}.`,
        )
      }
    }

    const [botDocsResponse, botSpecResponse] =
      await Promise.all([
        fetchBounded(
          `${replacementBaseUrl}/bot-api-reference`,
        ),
        fetchBounded(
          `${replacementBaseUrl}/bot-api-reference/json`,
        ),
      ])
    if (botDocsResponse.status !== 200) {
      throw new Error(
        `GET /bot-api-reference returned ${botDocsResponse.status}, expected 200.`,
      )
    }
    const botDocsBody = await botDocsResponse.text()
    if (!botDocsBody.includes("Inline Bot HTTP API Docs")) {
      throw new Error("GET /bot-api-reference did not return the Bot Swagger surface.")
    }
    const botSpec = await botSpecResponse.json() as {
      readonly paths?: Record<string, unknown>
    }
    if (
      botSpecResponse.status !== 200 ||
      botSpec.paths?.["/bot/sendMessage"] === undefined ||
      botSpec.paths?.["/bot{token}/sendMessage"] === undefined
    ) {
      throw new Error(
        "The Effect Bot contract omitted accepted header or path-token routes.",
      )
    }

    const [
      replacementRoot,
      replacementV1,
      replacementMessaging,
      replacementAdmin,
      replacementBot,
    ] = await Promise.all([
      fetchBounded(`${replacementBaseUrl}/`),
      fetchBounded(`${replacementBaseUrl}/v1/getMe`),
      fetchBounded(
        `${replacementBaseUrl}/v1/sendMessage`,
      ),
      fetchBounded(
        `${replacementBaseUrl}/admin/me`,
      ),
      fetchBounded(`${replacementBaseUrl}/bot/getMe`),
    ])
    if (
      replacementRoot.status !== 200 ||
      !(await replacementRoot.text()).includes(
        "inline server is running",
      )
    ) {
      throw new Error(
        `The Effect root returned ${replacementRoot.status} without its uptime marker.`,
      )
    }
    if (replacementV1.status !== 401) {
      throw new Error(
        `The Effect /v1/getMe auth boundary returned ${replacementV1.status}, expected 401.`,
      )
    }
    if (
      replacementMessaging.status !== 401
    ) {
      throw new Error(
        `The Effect /v1/sendMessage auth boundary returned ${replacementMessaging.status}, expected 401.`,
      )
    }
    if (replacementAdmin.status !== 401) {
      throw new Error(
        `The Effect /admin/me auth boundary returned ${replacementAdmin.status}, expected 401.`,
      )
    }
    if (replacementBot.status !== 401) {
      throw new Error(
        `The Effect /bot/getMe auth boundary returned ${replacementBot.status}, expected 401.`,
      )
    }
    if (replacementBot.headers.has("ratelimit-limit")) {
      throw new Error(
        "The Effect Bot route incorrectly inherited the legacy setup quota.",
      )
    }

    const fallbackResponse = await fetchBounded(
      `${replacementBaseUrl}/not-yet-migrated`,
    )
    if (fallbackResponse.status !== 404) {
      throw new Error(
        `GET /not-yet-migrated returned ${fallbackResponse.status}, expected 404.`,
      )
    }
    if (fallbackResponse.headers.get("x-content-type-options") !== "nosniff") {
      throw new Error("The Effect fallback response omitted global security headers.")
    }

    await exerciseRealtime(
      `ws://127.0.0.1:${ports.current}/realtime`,
    )

    child.kill("SIGTERM")
    const exitCode = await withTimeout(
      child.exited,
      SHUTDOWN_TIMEOUT_MS,
      "Core shadow graceful shutdown",
    )
    if (exitCode !== 0) {
      throw new Error(`Core shadow exited with code ${exitCode} after SIGTERM.`)
    }

    console.info(
      "Core shadow smoke passed: full current root/database/workers/realtime, replacement HTTP, and coordinated graceful shutdown.",
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

  await Promise.all([readStdout, readStderr])
}

await main()
