import { lookup as nodeLookup } from "node:dns/promises"
import { request as httpRequest, type IncomingMessage } from "node:http"
import { request as httpsRequest } from "node:https"
import { isIP } from "node:net"
import { isBlockedIp } from "@inline-chat/url-preview"
import sharp from "sharp"

const supportedContentTypes = ["image/webp", "image/png", "image/jpeg", "image/gif"] as const
const allowedContentTypes = new Set<string>(supportedContentTypes)
const genericContentTypes = new Set(["application/octet-stream", "binary/octet-stream"])
export const remoteBlockImageAcceptHeader = supportedContentTypes.join(",")
const maxBytes = 20 * 1024 * 1024
const idleTimeoutMs = 15_000
const totalTimeoutMs = 20_000
const maxRedirects = 3
const maxDnsAnswers = 32
const maxCandidateAttempts = 2
const maxFramePixels = 60_000_000
const maxAnimatedPixels = 120_000_000

export type LookupAddress = { address: string; family: number }
export type Lookup = (hostname: string) => Promise<LookupAddress[]>
type PublicCandidate = { address: string; family: 4 | 6 }

export type RemoteBlockImageDiagnostic = {
  cause: string
  hostname?: string
  transportErrorCode?: string
  redirectHop?: number
  answerCount?: number
  publicAnswerCount?: number
  filteredAnswerCount?: number
}

export class RemoteBlockImageError extends Error {
  constructor(
    public readonly code: string,
    public readonly permanent: boolean,
    public readonly diagnostic: RemoteBlockImageDiagnostic = { cause: code },
  ) {
    super(code)
    this.name = "RemoteBlockImageError"
  }
}

export type DownloadedBlockImage = {
  bytes: Uint8Array
  contentType: string
}

export type ResolvedPublicImageUrl = {
  url: URL
  address: string
  family: 4 | 6
  candidates: PublicCandidate[]
  diagnostic: RemoteBlockImageDiagnostic
}

export type RemoteImageRequest = (
  target: ResolvedPublicImageUrl & PublicCandidate,
  signal: AbortSignal,
) => Promise<IncomingMessage>

export type DownloadBlockImageOptions = {
  lookup?: Lookup
  request?: RemoteImageRequest
  signal?: AbortSignal
  totalTimeoutMs?: number
}

export async function downloadBlockImage(
  rawUrl: string,
  options: DownloadBlockImageOptions = {},
): Promise<DownloadedBlockImage> {
  const controller = new AbortController()
  let currentUrl = rawUrl
  let lastDiagnostic: RemoteBlockImageDiagnostic = { cause: "total_timeout" }
  const timeout = setTimeout(() => {
    controller.abort(new RemoteBlockImageError("total_timeout", false, {
      ...lastDiagnostic,
      cause: "total_timeout",
    }))
  }, Math.max(1, options.totalTimeoutMs ?? totalTimeoutMs))
  const abortFromCaller = () => controller.abort(options.signal?.reason)
  if (options.signal?.aborted) abortFromCaller()
  else options.signal?.addEventListener("abort", abortFromCaller, { once: true })

  try {
    for (let redirects = 0; redirects <= maxRedirects; redirects += 1) {
      throwIfAborted(controller.signal, lastDiagnostic)
      lastDiagnostic = diagnosticForRawUrl(currentUrl, redirects)
      const target = await resolvePublicImageUrl(
        currentUrl,
        options.lookup ?? defaultLookup,
        redirects,
        controller.signal,
      )
      lastDiagnostic = target.diagnostic
      const response = await requestCandidates(target, options.request ?? requestPinned, controller.signal)
      if (isRedirect(response.statusCode)) {
        const location = response.headers.location
        response.destroy()
        if (!location) {
          throw new RemoteBlockImageError("redirect_without_location", true, {
            ...target.diagnostic,
            cause: "redirect_without_location",
          })
        }

        let redirected: URL
        try {
          redirected = new URL(location, target.url)
        } catch {
          throw new RemoteBlockImageError("invalid_redirect", true, {
            ...target.diagnostic,
            cause: "invalid_redirect",
          })
        }
        if (target.url.protocol === "https:" && redirected.protocol === "http:") {
          throw new RemoteBlockImageError("invalid_redirect", true, {
            ...target.diagnostic,
            cause: "redirect_downgrade",
          })
        }
        currentUrl = redirected.toString()
        continue
      }

      if (!response.statusCode || response.statusCode < 200 || response.statusCode >= 300) {
        response.destroy()
        const status = response.statusCode
        const permanent = status !== undefined && status >= 400 && status < 500 && status !== 408 && status !== 429
        throw new RemoteBlockImageError("http_status", permanent, {
          ...target.diagnostic,
          cause: status === 408 || status === 429 ? "http_retryable_status" : "http_status",
        })
      }

      const declaredContentType = response.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase()
      const contentType = normalizedContentType(declaredContentType)
      if (declaredContentType && !contentType && !genericContentTypes.has(declaredContentType)) {
        response.destroy()
        throw new RemoteBlockImageError("unsupported_content_type", true, {
          ...target.diagnostic,
          cause: "unsupported_content_type",
        })
      }

      const bytes = await abortable(
        readBounded(response, controller.signal),
        controller.signal,
        () => response.destroy(),
      )
      const decodedContentType = await abortable(
        validateDecodeBudget(bytes, contentType, target.diagnostic),
        controller.signal,
      )
      return { bytes, contentType: decodedContentType }
    }

    throw new RemoteBlockImageError("too_many_redirects", true, {
      ...lastDiagnostic,
      cause: "too_many_redirects",
    })
  } catch (error) {
    if (controller.signal.aborted) throw abortError(controller.signal, lastDiagnostic)
    if (error instanceof RemoteBlockImageError) {
      throw new RemoteBlockImageError(error.code, error.permanent, {
        ...lastDiagnostic,
        ...error.diagnostic,
      })
    }
    throw new RemoteBlockImageError("network_error", false, {
      ...lastDiagnostic,
      cause: "network_error",
    })
  } finally {
    clearTimeout(timeout)
    options.signal?.removeEventListener("abort", abortFromCaller)
  }
}

export async function resolvePublicImageUrl(
  rawUrl: string,
  lookup: Lookup = defaultLookup,
  redirectHop = 0,
  signal?: AbortSignal,
): Promise<ResolvedPublicImageUrl> {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    throw new RemoteBlockImageError("invalid_url", true, { cause: "malformed_url", redirectHop })
  }

  const hostname = normalizedHostname(url)
  const diagnosticHostname = telemetryHostname(hostname)
  const diagnostic = (cause: string): RemoteBlockImageDiagnostic => ({
    cause,
    hostname: diagnosticHostname,
    redirectHop,
  })
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new RemoteBlockImageError("invalid_url", true, diagnostic("unsupported_scheme"))
  }
  if (!hostname) {
    throw new RemoteBlockImageError("invalid_url", true, diagnostic("missing_hostname"))
  }
  if (url.username || url.password) {
    throw new RemoteBlockImageError("invalid_url", true, diagnostic("credentials_present"))
  }
  if (!isAllowedPort(url)) {
    throw new RemoteBlockImageError("invalid_url", true, diagnostic("disallowed_port"))
  }
  if (isLocalHostname(hostname)) {
    throw new RemoteBlockImageError("blocked_address", true, diagnostic("local_hostname"))
  }
  url.hash = ""

  const literalFamily = isIP(hostname)
  let addresses: LookupAddress[]
  if (literalFamily) {
    addresses = [{ address: hostname, family: literalFamily }]
  } else {
    try {
      addresses = await abortable(lookup(hostname), signal)
    } catch {
      if (signal?.aborted) throw abortError(signal, diagnostic("dns_aborted"))
      throw new RemoteBlockImageError("dns_failed", false, diagnostic("dns_lookup_failed"))
    }
  }
  if (addresses.length === 0) {
    throw new RemoteBlockImageError("dns_failed", false, diagnostic("dns_empty"))
  }

  const candidates: PublicCandidate[] = []
  const seen = new Set<string>()
  const consideredAddresses = addresses.slice(0, maxDnsAnswers)
  for (const answer of consideredAddresses) {
    const address = answer.address.toLowerCase().split("%", 1)[0] ?? answer.address.toLowerCase()
    const family = isIP(address)
    if ((family !== 4 && family !== 6) || isBlockedIp(address)) continue
    const key = `${family}:${address}`
    if (seen.has(key)) continue
    seen.add(key)
    candidates.push({ address, family })
  }

  const resolvedDiagnostic: RemoteBlockImageDiagnostic = {
    ...diagnostic(candidates.length === consideredAddresses.length ? "public_candidates" : "non_public_candidates_filtered"),
    answerCount: consideredAddresses.length,
    publicAnswerCount: candidates.length,
    filteredAnswerCount: Math.max(0, consideredAddresses.length - candidates.length),
  }
  if (candidates.length === 0) {
    throw new RemoteBlockImageError("blocked_address", true, {
      ...resolvedDiagnostic,
      cause: literalFamily ? "literal_non_public" : "dns_no_public_candidate",
    })
  }

  const selected = candidates[0]!
  return {
    url,
    address: selected.address,
    family: selected.family,
    candidates,
    diagnostic: resolvedDiagnostic,
  }
}

async function defaultLookup(hostname: string): Promise<LookupAddress[]> {
  return nodeLookup(hostname, { all: true, verbatim: true })
}

async function requestCandidates(
  target: ResolvedPublicImageUrl,
  request: RemoteImageRequest,
  signal: AbortSignal,
): Promise<IncomingMessage> {
  const first = target.candidates[0]
  const alternateFamily = first
    ? target.candidates.find((candidate) => candidate.family !== first.family)
    : undefined
  const attempts = [first, alternateFamily ?? target.candidates[1]].filter(
    (candidate): candidate is PublicCandidate => candidate !== undefined,
  ).slice(0, maxCandidateAttempts)
  let lastTransportErrorCode: string | undefined
  for (const candidate of attempts) {
    throwIfAborted(signal, target.diagnostic)
    try {
      return await request({ ...target, ...candidate }, signal)
    } catch (error) {
      if (signal.aborted) throw abortError(signal, target.diagnostic)
      if (error instanceof RemoteBlockImageError && error.permanent) throw error
      lastTransportErrorCode = safeTransportErrorCode(error)
    }
  }
  throw new RemoteBlockImageError("network_error", false, {
    ...target.diagnostic,
    cause: "public_candidates_unreachable",
    transportErrorCode: lastTransportErrorCode,
  })
}

function requestPinned(
  target: ResolvedPublicImageUrl & PublicCandidate,
  signal: AbortSignal,
): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    const request = (target.url.protocol === "https:" ? httpsRequest : httpRequest)(target.url, {
      method: "GET",
      headers: {
        Accept: remoteBlockImageAcceptHeader,
        "User-Agent": "InlineRichContent/1.0",
      },
      servername: isIP(normalizedHostname(target.url)) === 0 ? normalizedHostname(target.url) : undefined,
      // Bun/Node requests DNS with `all: true`. That callback contract expects
      // an array, while the legacy single-address contract expects separate
      // address/family arguments. Honor both without allowing a second lookup,
      // so the request stays pinned to the validated candidate.
      lookup: ((_hostname: string, options: { all?: boolean }, callback: (...args: unknown[]) => void) => {
        if (options.all) {
          callback(null, [{ address: target.address, family: target.family }])
        } else {
          callback(null, target.address, target.family)
        }
      }) as never,
    }, resolve)
    const abortRequest = () => request.destroy(abortError(signal, target.diagnostic))
    if (signal.aborted) abortRequest()
    else signal.addEventListener("abort", abortRequest, { once: true })
    request.setTimeout(idleTimeoutMs, () => request.destroy(new RemoteBlockImageError("timeout", false, {
      ...target.diagnostic,
      cause: "socket_idle_timeout",
    })))
    request.once("close", () => signal.removeEventListener("abort", abortRequest))
    request.on("error", reject)
    request.end()
  })
}

async function readBounded(response: IncomingMessage, signal: AbortSignal): Promise<Uint8Array> {
  const declaredLength = Number(response.headers["content-length"] ?? 0)
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    response.destroy()
    throw new RemoteBlockImageError("response_too_large", true, { cause: "declared_response_too_large" })
  }

  const chunks: Buffer[] = []
  let total = 0
  for await (const chunk of response) {
    throwIfAborted(signal, { cause: "body_aborted" })
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    total += bytes.byteLength
    if (total > maxBytes) {
      response.destroy()
      throw new RemoteBlockImageError("response_too_large", true, { cause: "streamed_response_too_large" })
    }
    chunks.push(bytes)
  }
  if (total === 0) throw new RemoteBlockImageError("empty_response", true, { cause: "empty_response" })
  return Buffer.concat(chunks, total)
}

function isRedirect(status: number | undefined): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308
}

async function validateDecodeBudget(
  bytes: Uint8Array,
  declaredContentType: string | undefined,
  diagnostic: RemoteBlockImageDiagnostic,
): Promise<string> {
  try {
    const metadata = await sharp(bytes, { failOn: "error", limitInputPixels: maxFramePixels }).metadata()
    const width = metadata.width ?? 0
    const frameHeight = metadata.pageHeight ?? metadata.height ?? 0
    const pages = Math.max(1, metadata.pages ?? 1)
    const framePixels = width * frameHeight
    if (width <= 0 || frameHeight <= 0 || framePixels > maxFramePixels || framePixels * pages > maxAnimatedPixels) {
      throw new RemoteBlockImageError("decode_budget_exceeded", true, {
        ...diagnostic,
        cause: "decode_pixel_budget",
      })
    }

    const actualContentType = contentTypeForSharpFormat(metadata.format)
    if (!actualContentType || (declaredContentType && actualContentType !== declaredContentType)) {
      throw new RemoteBlockImageError("invalid_image", true, {
        ...diagnostic,
        cause: "content_type_mismatch",
      })
    }
    return actualContentType
  } catch (error) {
    if (error instanceof RemoteBlockImageError) throw error
    throw new RemoteBlockImageError("invalid_image", true, {
      ...diagnostic,
      cause: "image_decode_failed",
    })
  }
}

function normalizedContentType(contentType: string | undefined): string | undefined {
  if (contentType === "image/jpg") return "image/jpeg"
  return contentType && allowedContentTypes.has(contentType) ? contentType : undefined
}

function contentTypeForSharpFormat(format: string | undefined): string | undefined {
  switch (format) {
    case "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return undefined
  }
}

function normalizedHostname(url: URL): string {
  return url.hostname.replace(/^\[|\]$/g, "").toLowerCase().replace(/\.$/, "")
}

function diagnosticForRawUrl(rawUrl: string, redirectHop: number): RemoteBlockImageDiagnostic {
  try {
    return {
      cause: "resolving_target",
      hostname: telemetryHostname(normalizedHostname(new URL(rawUrl))),
      redirectHop,
    }
  } catch {
    return { cause: "malformed_url", redirectHop }
  }
}

function telemetryHostname(hostname: string): string | undefined {
  if (!hostname) return undefined
  const family = isIP(hostname)
  if (family === 4) return "ip_literal_v4"
  if (family === 6) return "ip_literal_v6"
  return hostname.slice(0, 253)
}

function safeTransportErrorCode(error: unknown): string | undefined {
  if (typeof error !== "object" || error === null || !("code" in error)) return undefined
  const code = String(error.code)
  return /^[A-Z0-9_]{1,48}$/.test(code) ? code : undefined
}

function isLocalHostname(hostname: string): boolean {
  return hostname === "localhost" || hostname.endsWith(".localhost") || hostname.endsWith(".local") ||
    hostname.endsWith(".internal") || hostname.endsWith(".home.arpa")
}

function isAllowedPort(url: URL): boolean {
  if (!url.port) return true
  return (url.protocol === "http:" && url.port === "80") || (url.protocol === "https:" && url.port === "443")
}

function abortError(signal: AbortSignal, diagnostic: RemoteBlockImageDiagnostic): RemoteBlockImageError {
  return signal.reason instanceof RemoteBlockImageError
    ? signal.reason
    : new RemoteBlockImageError("canceled", false, { ...diagnostic, cause: "aborted" })
}

function throwIfAborted(signal: AbortSignal, diagnostic: RemoteBlockImageDiagnostic): void {
  if (signal.aborted) throw abortError(signal, diagnostic)
}

async function abortable<T>(operation: Promise<T>, signal?: AbortSignal, onAbort?: () => void): Promise<T> {
  if (!signal) return operation
  throwIfAborted(signal, { cause: "aborted" })
  let abortListener: (() => void) | undefined
  const aborted = new Promise<never>((_resolve, reject) => {
    abortListener = () => {
      onAbort?.()
      reject(abortError(signal, { cause: "aborted" }))
    }
    signal.addEventListener("abort", abortListener, { once: true })
  })
  try {
    return await Promise.race([operation, aborted])
  } finally {
    if (abortListener) signal.removeEventListener("abort", abortListener)
  }
}
