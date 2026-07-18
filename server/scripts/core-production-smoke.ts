const START_TIMEOUT_MILLIS = 20_000
const REQUEST_TIMEOUT_MILLIS = 10_000
const SHUTDOWN_TIMEOUT_MILLIS = 25_000
const MAX_OUTPUT_LENGTH = 24_000

type CapturedOutput = {
  stderr: string
  stdout: string
}

const appendBounded = (
  current: string,
  chunk: string,
): string => {
  const next = current + chunk
  return next.length <= MAX_OUTPUT_LENGTH
    ? next
    : `[earlier output truncated]\n${next.slice(-MAX_OUTPUT_LENGTH)}`
}

const withTimeout = async <Value>(
  promise: Promise<Value>,
  timeoutMillis: number,
  label: string,
): Promise<Value> => {
  let timeout:
    | ReturnType<typeof setTimeout>
    | undefined

  try {
    return await Promise.race([
      promise,
      new Promise<never>(
        (_resolve, reject) => {
          timeout = setTimeout(
            () =>
              reject(
                new Error(
                  `${label} timed out after ${timeoutMillis}ms.`,
                ),
              ),
            timeoutMillis,
          )
        },
      ),
    ])
  } finally {
    if (timeout !== undefined) {
      clearTimeout(timeout)
    }
  }
}

const fetchBounded = (
  url: string,
): Promise<Response> =>
  fetch(url, {
    signal: AbortSignal.timeout(
      REQUEST_TIMEOUT_MILLIS,
    ),
  })

const exerciseRealtime = (
  url: string,
): Promise<void> =>
  withTimeout(
    new Promise<void>((resolve, reject) => {
      let opened = false
      const socket = new WebSocket(url)

      socket.addEventListener(
        "open",
        () => {
          opened = true
          socket.close(
            1000,
            "core-production-smoke",
          )
        },
      )
      socket.addEventListener(
        "close",
        () => {
          if (opened) {
            resolve()
          } else {
            reject(
              new Error(
                "Candidate realtime closed before opening.",
              ),
            )
          }
        },
      )
      socket.addEventListener(
        "error",
        () => {
          reject(
            new Error(
              "Candidate realtime failed to connect.",
            ),
          )
        },
      )
    }),
    REQUEST_TIMEOUT_MILLIS,
    "Candidate realtime probe",
  )

const main = async (): Promise<void> => {
  let captured: CapturedOutput = {
    stderr: "",
    stdout: "",
  }
  let readyBuffer = ""
  let resolveReady:
    | ((port: number) => void)
    | undefined
  const ready = new Promise<number>(
    (resolve) => {
      resolveReady = resolve
    },
  )
  const child = Bun.spawn({
    cmd: [
      process.execPath,
      "src/core/index.ts",
    ],
    cwd: new URL(
      "..",
      import.meta.url,
    ).pathname,
    env: {
      ...process.env,
      ENABLE_DATABASE_HEALTH_MONITOR:
        "0",
      INLINE_API_RATE_LIMIT_MAX: "180",
      INLINE_TRUSTED_CLIENT_IP_HEADER:
        "",
      LIVEKIT_API_KEY: "",
      LIVEKIT_API_SECRET: "",
      LIVEKIT_URL: "",
      NODE_ENV: "test",
      PORT: "0",
      SENTRY_DSN: "",
    },
    stdin: "ignore",
    stderr: "pipe",
    stdout: "pipe",
  })

  const readStdout = (async () => {
    const decoder = new TextDecoder()
    for await (
      const bytes of child.stdout
    ) {
      const chunk = decoder.decode(
        bytes,
        { stream: true },
      )
      captured.stdout = appendBounded(
        captured.stdout,
        chunk,
      )
      readyBuffer =
        (readyBuffer + chunk).slice(-4_096)
      const marker = readyBuffer.match(
        /CORE_CANDIDATE_READY ([0-9]+)/,
      )
      const port = Number(marker?.[1])
      if (
        Number.isSafeInteger(port) &&
        port > 0
      ) {
        resolveReady?.(port)
        resolveReady = undefined
      }
    }
    captured.stdout = appendBounded(
      captured.stdout,
      decoder.decode(),
    )
  })()
  const readStderr = (async () => {
    const decoder = new TextDecoder()
    for await (
      const bytes of child.stderr
    ) {
      captured.stderr = appendBounded(
        captured.stderr,
        decoder.decode(
          bytes,
          { stream: true },
        ),
      )
    }
    captured.stderr = appendBounded(
      captured.stderr,
      decoder.decode(),
    )
  })()

  let forced = false
  try {
    const port = await withTimeout(
      Promise.race([
        ready,
        child.exited.then((code) => {
          throw new Error(
            `Candidate exited before readiness with code ${code}.`,
          )
        }),
      ]),
      START_TIMEOUT_MILLIS,
      "Candidate startup",
    )
    const baseUrl =
      `http://127.0.0.1:${port}`
    const root = await fetchBounded(
      `${baseUrl}/`,
    )
    if (
      root.status !== 200 ||
      !(await root.text()).includes(
        "inline server is running",
      )
    ) {
      throw new Error(
        `Candidate root returned ${root.status}.`,
      )
    }

    const platformSpecResponse =
      await fetchBounded(
        `${baseUrl}/v1/reference/json`,
      )
    const platformSpec =
      await platformSpecResponse.json() as {
        readonly paths?:
          | Record<string, unknown>
          | undefined
      }
    for (
      const path of [
        "/oauth/token",
        "/v1/getMe",
        "/v1/sendMessage",
        "/admin/me",
      ]
    ) {
      if (
        platformSpec.paths?.[path] ===
          undefined
      ) {
        throw new Error(
          `Candidate platform OpenAPI omitted ${path}.`,
        )
      }
    }

    const botSpecResponse =
      await fetchBounded(
        `${baseUrl}/bot-api-reference/json`,
      )
    const botSpec =
      await botSpecResponse.json() as {
        readonly paths?:
          | Record<string, unknown>
          | undefined
      }
    if (
      botSpec.paths?.[
        "/bot/sendMessage"
      ] === undefined
    ) {
      throw new Error(
        "Candidate Bot OpenAPI omitted sendMessage.",
      )
    }

    const [v1, admin, fallback] =
      await Promise.all([
        fetchBounded(
          `${baseUrl}/v1/getMe`,
        ),
        fetchBounded(
          `${baseUrl}/admin/me`,
        ),
        fetchBounded(
          `${baseUrl}/not-a-route`,
        ),
      ])
    if (
      v1.status !== 401 ||
      admin.status !== 401 ||
      fallback.status !== 404
    ) {
      throw new Error(
        `Candidate boundaries returned v1=${v1.status}, admin=${admin.status}, fallback=${fallback.status}.`,
      )
    }

    await exerciseRealtime(
      `ws://127.0.0.1:${port}/realtime`,
    )

    child.kill("SIGTERM")
    const exitCode = await withTimeout(
      child.exited,
      SHUTDOWN_TIMEOUT_MILLIS,
      "Candidate shutdown",
    )
    if (exitCode !== 0) {
      throw new Error(
        `Candidate exited with code ${exitCode}.`,
      )
    }

    console.info(
      "Core production smoke passed: complete HTTP/OpenAPI, raw realtime, process runtime, and graceful shutdown.",
    )
  } catch (error) {
    if (child.exitCode === null) {
      forced = true
      child.kill("SIGKILL")
      await child.exited
    }
    await Promise.allSettled([
      readStdout,
      readStderr,
    ])
    const output = [
      captured.stdout &&
        `--- child stdout ---\n${captured.stdout.trimEnd()}`,
      captured.stderr &&
        `--- child stderr ---\n${captured.stderr.trimEnd()}`,
    ].filter(Boolean).join("\n")

    throw new Error(
      `${error instanceof Error ? error.message : String(error)}${
        forced
          ? " The harness force-stopped only its child."
          : ""
      }${output ? `\n${output}` : ""}`,
    )
  }

  await Promise.all([
    readStdout,
    readStderr,
  ])
}

await main()
