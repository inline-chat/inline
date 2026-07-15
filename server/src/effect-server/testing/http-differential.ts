import { createHash } from "node:crypto"

export type InProcessHttpExecutor = (request: Request) => Response | Promise<Response>

export type HttpContractNormalization = {
  readonly ignoredHeaders?: ReadonlyArray<string>
  readonly volatileHeaders?: ReadonlyArray<string>
  readonly sensitiveHeaders?: ReadonlyArray<string>
  readonly sensitiveJsonKeys?: ReadonlyArray<string>
}

export type NormalizedHttpResponse = {
  readonly status: number
  readonly headers: ReadonlyArray<readonly [string, string]>
  readonly body: unknown
}

const defaultNormalization: Required<HttpContractNormalization> = {
  ignoredHeaders: ["date", "server-timing"],
  volatileHeaders: ["traceparent", "x-request-id"],
  sensitiveHeaders: ["authorization", "cookie", "set-cookie"],
  sensitiveJsonKeys: ["access_token", "authorization", "cookie", "password", "refresh_token", "secret", "token"],
}

const sha256 = (value: string): string => createHash("sha256").update(value).digest("hex")
const compareStrings = (left: string, right: string): number => (left < right ? -1 : left > right ? 1 : 0)

const canonicalize = (value: unknown, sensitiveKeys: ReadonlySet<string>): unknown => {
  if (Array.isArray(value)) {
    return value.map((item) => canonicalize(item, sensitiveKeys))
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => compareStrings(left, right))
        .map(([key, item]) => [
          key,
          sensitiveKeys.has(key.toLowerCase()) ? `<sha256:${sha256(JSON.stringify(item))}>` : canonicalize(item, sensitiveKeys),
        ]),
    )
  }

  return value
}

const normalizeOptions = (options: HttpContractNormalization): Required<HttpContractNormalization> => ({
  ignoredHeaders: options.ignoredHeaders ?? defaultNormalization.ignoredHeaders,
  volatileHeaders: options.volatileHeaders ?? defaultNormalization.volatileHeaders,
  sensitiveHeaders: options.sensitiveHeaders ?? defaultNormalization.sensitiveHeaders,
  sensitiveJsonKeys: options.sensitiveJsonKeys ?? defaultNormalization.sensitiveJsonKeys,
})

export const normalizeHttpResponse = async (
  response: Response,
  options: HttpContractNormalization = {},
): Promise<NormalizedHttpResponse> => {
  const normalized = normalizeOptions(options)
  const ignoredHeaders = new Set(normalized.ignoredHeaders.map((header) => header.toLowerCase()))
  const volatileHeaders = new Set(normalized.volatileHeaders.map((header) => header.toLowerCase()))
  const sensitiveHeaders = new Set(normalized.sensitiveHeaders.map((header) => header.toLowerCase()))
  const sensitiveJsonKeys = new Set(normalized.sensitiveJsonKeys.map((key) => key.toLowerCase()))
  const headers = [...response.headers.entries()]
    .map(([name, value]) => [name.toLowerCase(), value] as const)
    .filter(([name]) => !ignoredHeaders.has(name))
    .map(([name, value]) => {
      if (volatileHeaders.has(name)) return [name, "<volatile>"] as const
      if (sensitiveHeaders.has(name)) return [name, `<sha256:${sha256(value)}>`] as const
      return [name, value] as const
    })
    .sort(([leftName, leftValue], [rightName, rightValue]) =>
      compareStrings(leftName, rightName) || compareStrings(leftValue, rightValue),
    )

  const contentType = response.headers.get("content-type")?.toLowerCase() ?? ""
  const text = await response.text()
  let body: unknown = text

  if (text && contentType.includes("json")) {
    try {
      body = canonicalize(JSON.parse(text), sensitiveJsonKeys)
    } catch {
      body = text
    }
  }

  return { status: response.status, headers, body }
}

export const executeInProcess = (
  executor: InProcessHttpExecutor,
  input: string | URL | Request,
  init?: RequestInit,
): Promise<Response> => Promise.resolve(executor(input instanceof Request ? input.clone() : new Request(input, init)))

export const compareHttpExecutors = async (
  legacy: InProcessHttpExecutor,
  effect: InProcessHttpExecutor,
  request: Request,
  options: HttpContractNormalization = {},
): Promise<{ readonly legacy: NormalizedHttpResponse; readonly effect: NormalizedHttpResponse }> => {
  const [legacyResponse, effectResponse] = await Promise.all([
    executeInProcess(legacy, request),
    executeInProcess(effect, request),
  ])
  const [legacyNormalized, effectNormalized] = await Promise.all([
    normalizeHttpResponse(legacyResponse, options),
    normalizeHttpResponse(effectResponse, options),
  ])

  if (JSON.stringify(legacyNormalized) !== JSON.stringify(effectNormalized)) {
    const legacyHash = sha256(JSON.stringify(legacyNormalized))
    const effectHash = sha256(JSON.stringify(effectNormalized))
    throw new Error(`HTTP contract mismatch (legacy=${legacyHash}, effect=${effectHash})`)
  }

  return { legacy: legacyNormalized, effect: effectNormalized }
}
